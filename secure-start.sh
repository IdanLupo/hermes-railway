#!/bin/bash
# secure-start.sh — boots Hermes gateway + dashboard behind a Caddy
# HTTP basic-auth reverse proxy. Caddy listens on $PORT (the public-
# facing one), dashboard moves to 127.0.0.1:9120 (no longer public).
#
# Credentials come from env (Railway): DASHBOARD_USER, DASHBOARD_PASSWORD.
# If unset, a random 24-char password is generated and printed in the
# logs (find it with `railway logs --service hermes-agent | grep -i
# 'dashboard credentials' -A 4`).
#
# Caddy binary is cached on the volume at /opt/data/bin/caddy, so cold
# starts after first deploy are fast.

set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
PROXY_PORT="${PORT:-9119}"
DASHBOARD_INTERNAL_PORT=9120

USER_NAME="${DASHBOARD_USER:-admin}"
PASSWORD_FILE="$HERMES_HOME/.dashboard-password"

# 1. Resolve the password (env var -> cached file -> generate).
if [ -n "$DASHBOARD_PASSWORD" ]; then
    printf '%s' "$DASHBOARD_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
fi
if [ ! -s "$PASSWORD_FILE" ]; then
    echo "[secure-start] DASHBOARD_PASSWORD not set; generating one." >&2
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    echo ""
    echo "============================================================"
    echo "  Dashboard credentials (SAVE THESE)"
    echo "    User:     $USER_NAME"
    echo "    Password: $(cat "$PASSWORD_FILE")"
    echo "============================================================"
    echo ""
fi
PASSWORD=$(cat "$PASSWORD_FILE")

# 2. Ensure Caddy is on the volume. Cached after first download.
CADDY="$HERMES_HOME/bin/caddy"
if [ ! -x "$CADDY" ]; then
    echo "[secure-start] Caddy not cached at $CADDY - downloading v2.8.4..." >&2
    mkdir -p "$HERMES_HOME/bin"
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_amd64.tar.gz" \
        | tar -xz -C "$HERMES_HOME/bin" caddy
    chmod +x "$CADDY"
fi

# 2b. File-access tooling, cached on the volume like Caddy. Both are OPTIONAL:
#     every step here is guarded so a download/launch failure can never abort
#     boot (the gateway is the critical path; file access is an add-on).
#       - filebrowser → web UI on /files (browse/upload/download/delete)
#       - rclone      → WebDAV on /dav (mountable in macOS Finder)
FILEBROWSER="$HERMES_HOME/bin/filebrowser"
RCLONE="$HERMES_HOME/bin/rclone"
if [ ! -x "$FILEBROWSER" ]; then
    echo "[secure-start] Downloading filebrowser..." >&2
    curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz" \
        | tar -xz -C "$HERMES_HOME/bin" filebrowser 2>/dev/null \
        && chmod +x "$FILEBROWSER" \
        || echo "[secure-start] WARN: filebrowser download failed; /files unavailable" >&2
fi
if [ ! -x "$RCLONE" ]; then
    echo "[secure-start] Downloading rclone..." >&2
    ( curl -fsSL "https://downloads.rclone.org/rclone-current-linux-amd64.zip" -o /tmp/rclone.zip \
        && python3 -m zipfile -e /tmp/rclone.zip /tmp/rclone-x \
        && cp "$(find /tmp/rclone-x -name rclone -type f | head -1)" "$RCLONE" \
        && chmod +x "$RCLONE" ) \
        || echo "[secure-start] WARN: rclone download failed; /dav unavailable" >&2
    rm -rf /tmp/rclone.zip /tmp/rclone-x 2>/dev/null || true
fi

# 3. Hash the password (bcrypt via Caddy's built-in hasher).
PASSWORD_HASH=$("$CADDY" hash-password --plaintext "$PASSWORD")

# 4. Write the Caddyfile.
cat > "$HERMES_HOME/Caddyfile" <<EOF
{
    auto_https off
    admin off
    log default {
        output stderr
        level INFO
    }
}

:$PROXY_PORT {
    log {
        output stderr
        level INFO
        format console
    }

    # Strip X-Forwarded-For globally. uvicorn (backing the Hermes dashboard)
    # trusts proxy headers from 127.0.0.1 and rewrites ws.client.host based
    # on X-Forwarded-For. The dashboard's _ws_client_is_allowed() then
    # rejects /api/pty because the rewritten client IP isn't loopback.
    request_header -X-Forwarded-For
    request_header -X-Forwarded-Host
    request_header -X-Real-Ip

    # Inbound webhooks (AgentMail message.received, etc).
    # Bypasses basic_auth so external services can POST without creds.
    # Hermes routes are gated by long-random path tokens — the URL is
    # the shared secret (Slack-style). Anything else returns 404 from
    # Hermes route-not-found.
    @webhooks path /webhooks/*
    handle @webhooks {
        reverse_proxy 127.0.0.1:8644 {
            flush_interval -1
        }
    }

    # WebSocket endpoints — gated by the dashboard's session token (in
    # query string). Bypass basic_auth (it interferes with WS upgrade).
    @ws path /api/pty /api/ws /api/events
    handle @ws {
        reverse_proxy 127.0.0.1:$DASHBOARD_INTERNAL_PORT {
            header_up Host 127.0.0.1:$DASHBOARD_INTERNAL_PORT
            header_up Origin http://127.0.0.1:$DASHBOARD_INTERNAL_PORT
        }
    }

    # File browser (web UI) on /files — basic-auth gated. filebrowser runs
    # with --baseURL /files so it owns the whole /files/* path; pass through
    # unchanged. Returns 502 if filebrowser didn't start (non-fatal add-on).
    @files path /files /files/*
    handle @files {
        basic_auth {
            $USER_NAME $PASSWORD_HASH
        }
        reverse_proxy 127.0.0.1:9121
    }

    # WebDAV on /dav (mount in macOS Finder) — basic-auth gated. rclone serves
    # with --baseurl /dav. WebDAV verbs (PROPFIND/MKCOL/MOVE/...) pass through
    # reverse_proxy by default.
    @dav path /dav /dav/*
    handle @dav {
        basic_auth {
            $USER_NAME $PASSWORD_HASH
        }
        reverse_proxy 127.0.0.1:9122
    }

    # Everything else — basic-auth gated.
    handle {
        basic_auth {
            $USER_NAME $PASSWORD_HASH
        }
        reverse_proxy 127.0.0.1:$DASHBOARD_INTERNAL_PORT {
            header_up Host 127.0.0.1:$DASHBOARD_INTERNAL_PORT
            header_up Origin http://127.0.0.1:$DASHBOARD_INTERNAL_PORT
        }
    }
}
EOF

# 4b. Optionally sync a private skills repo into $HERMES_HOME/skills/custom/.
#     Enable by setting BOTH:
#       SKILLS_REPO_URL   - https GitHub URL, e.g. https://github.com/you/skills.git
#       SKILLS_REPO_TOKEN - PAT with contents:read (fine-grained or classic)
#     The repo is expected to have a top-level skills/<name>/ layout; each
#     <name> is symlinked into the Hermes skills dir. If either var is unset
#     we skip — the skills bundled in the Hermes image still work.
SKILLS_REPO_DIR="$HERMES_HOME/skills/custom"
if [ -n "$SKILLS_REPO_URL" ] && [ -n "$SKILLS_REPO_TOKEN" ]; then
    # Build an authenticated URL (x-access-token form works for both classic
    # and fine-grained PATs). Strip any scheme the user included first.
    REPO_PATH="${SKILLS_REPO_URL#https://}"
    REPO_PATH="${REPO_PATH#http://}"
    AUTH_URL="https://x-access-token:${SKILLS_REPO_TOKEN}@${REPO_PATH}"
    CLEAN_URL="https://${REPO_PATH}"
    if [ -d "$SKILLS_REPO_DIR/.git" ]; then
        echo "[secure-start] Updating custom skills repo..." >&2
        (cd "$SKILLS_REPO_DIR" && \
         git remote set-url origin "$AUTH_URL" && \
         git pull --ff-only 2>&1 | head -5) >&2 || \
         echo "[secure-start] WARN: git pull failed, keeping existing checkout" >&2
    else
        echo "[secure-start] Cloning custom skills repo..." >&2
        mkdir -p "$HERMES_HOME/skills"
        rm -rf "$SKILLS_REPO_DIR"
        git clone --depth 1 "$AUTH_URL" "$SKILLS_REPO_DIR" 2>&1 | head -5 >&2 || \
            echo "[secure-start] WARN: clone failed, skipping custom skills" >&2
    fi
    # Strip token from remote URL so it isn't stored on disk in plain text.
    if [ -d "$SKILLS_REPO_DIR/.git" ]; then
        (cd "$SKILLS_REPO_DIR" && git remote set-url origin "$CLEAN_URL")
    fi
    if [ -d "$SKILLS_REPO_DIR/skills" ]; then
        echo "[secure-start] Linking custom skills into $HERMES_HOME/skills/ ..." >&2
        for skill in "$SKILLS_REPO_DIR"/skills/*/; do
            [ -d "$skill" ] || continue
            name=$(basename "$skill")
            # Prefix with "custom-" to avoid colliding with the skills
            # bundled in the Hermes image (notion, linear, airtable, etc.).
            target="$HERMES_HOME/skills/custom-$name"
            rm -rf "$target"
            ln -s "$skill" "$target"
        done
        echo "[secure-start] $(ls -d $HERMES_HOME/skills/custom-* 2>/dev/null | wc -l) custom skills linked" >&2
    fi
else
    echo "[secure-start] SKILLS_REPO_URL/SKILLS_REPO_TOKEN not set; skipping custom skills clone" >&2
fi

# 4c. Seed a default agent identity (SOUL.md) on FIRST BOOT ONLY.
#     Hermes reads $HERMES_HOME/SOUL.md as the agent's system identity. We
#     write it only if absent, so once you edit it (or the agent does), your
#     version is never clobbered on redeploy. Delete the file to regenerate
#     this default. The share-link section is wired to the /files + /dav
#     services this script starts in step 6b, so the agent can hand out
#     download links out of the box.
SOUL_FILE="$HERMES_HOME/SOUL.md"
PUBLIC_HOST="${RAILWAY_PUBLIC_DOMAIN:-your-app.up.railway.app}"
if [ ! -f "$SOUL_FILE" ]; then
    echo "[secure-start] Seeding default SOUL.md (none present)..." >&2
    cat > "$SOUL_FILE" <<SOULEOF
# SOUL.md

You're Hermes, a chief of staff and executive operator for the person you work
for. Get it done.

## Core Truths

**Be direct.** No preamble, no "Great question!", no filler. Answer first,
explain only if asked.

**Be executive.** Think like a chief of staff. Anticipate needs, handle the
details, surface only what matters. Your operator shouldn't have to manage you;
you manage things for them.

**Be resourceful before asking.** Figure it out. Read the file. Check the
context. Search for it. Come back with answers, not questions. If you genuinely
need a decision, ask one focused question, not five.

**Be a little witty.** Sharp, not corporate. A well-placed quip lands better
than a wall of caveats.

**Earn trust through competence.** You've been given access to real accounts and
data. Be careful with external actions. Be bold with internal ones.

## Boundaries

- Private things stay private. Period.
- When in doubt, ask before acting externally (emails, posts, scheduling,
  payments).
- Never send half-baked replies to messaging surfaces.
- You're not your operator's voice in group chats. Participate; do not
  impersonate.

## Formatting Rules

- Avoid emdashes. Use commas, periods, semicolons, or rewrite. It reads more
  human.
- Short. One main idea per message. Memorable at a glance.
- Plain text first. Markdown when it helps. Tables rarely.

## Vibe

Direct. Efficient. Witty when it fits. An exec assistant who actually has
opinions and gets things done without being asked twice.

## Continuity

Each session you wake up fresh. These files are your memory. Read SOUL.md, then
USER.md and MEMORY.md if they exist. Update them when you learn something worth
keeping. If you change SOUL.md, mention it to your operator; it is your identity.

If USER.md says the operator is still unknown, ask their name early in the
conversation and save it to USER.md. Do not guess who you are talking to.

## Workspace & Files

Your writable workspace is \`$HERMES_HOME\` (it is /opt/data). The application
install at /opt/hermes is READ-ONLY: never write there, it fails with permission
denied. When you create a file and no path is given, write it under
\`$HERMES_HOME\` (or a subfolder you make there) - not the current directory
blindly, and never /opt/hermes.

## Sharing Files & Artifacts

This deployment serves exactly one folder to the web: \`$HERMES_HOME/share\`.
A file is only reachable in the web file browser if it lives under that folder.
Everything else on the volume (secrets, config, your working files) is
deliberately NOT reachable.

So to hand someone a file: write it (or copy it) into \`$HERMES_HOME/share/\`,
then point them to the file browser:

  https://$PUBLIC_HOST/files/

Log in with the dashboard credentials (expected), and the file is listed there
to preview or download. A file at \`$HERMES_HOME/share/report.pdf\` shows up in
that browser as \`report.pdf\`. Files written anywhere else on the volume will
NOT appear - move them under share/ first.

Big files belong here, not in email. Anything awkward to attach (tens or
hundreds of MB), copy it under share and send the /files link instead of
attaching.

NEVER put secrets, tokens, .env files, credentials, or private backups under the
share folder. It is web-exposed (behind your login). Keep private material
elsewhere on the volume.
SOULEOF
else
    echo "[secure-start] SOUL.md already present; leaving it untouched." >&2
fi

# 4d. Seed a USER.md stub on first boot only, so the agent has a place to
#     record who it works for (and knows to ask). Never clobbered once written.
USER_FILE="$HERMES_HOME/USER.md"
if [ ! -f "$USER_FILE" ]; then
    echo "[secure-start] Seeding default USER.md (none present)..." >&2
    cat > "$USER_FILE" <<'USEREOF'
# USER.md

Operator: (unknown so far)

On your first conversation, ask who you are working for - their name and how they
want to be addressed - and replace the line above. Add anything else worth
remembering here over time: role, company, timezone, preferences, recurring
goals. This file is your memory of the person; keep it current.
USEREOF
fi

# 4e. Run the agent from the WRITABLE volume, not the read-only app install.
#     Hermes' terminal cwd defaults to "." (config.yaml: terminal.cwd), which
#     resolves to the process launch directory. The image launches from
#     /opt/hermes, which is read-only - so the agent's first file write there
#     fails with "permission denied". cd into $HERMES_HOME so "." is writable.
cd "$HERMES_HOME" || true

# 5. Start the gateway in the background.
echo "[secure-start] Starting Hermes gateway (cwd $(pwd))..." >&2
hermes gateway run &

# 6. Start the dashboard. We bind to 0.0.0.0 + --insecure so the dashboard's
#    _ws_client_is_allowed() loopback check is bypassed for /api/pty (the
#    embedded chat WebSocket). With Caddy in front basic-auth-gating all
#    public traffic and Railway only routing PORT (9119) externally, port
#    9120 is NEVER reachable from outside the container — the --insecure
#    flag is misleading; in this context it's still safe.
#    --tui exposes the in-browser Chat tab (embedded `hermes --tui` via PTY).
echo "[secure-start] Starting Hermes dashboard on 0.0.0.0:$DASHBOARD_INTERNAL_PORT (container-internal)..." >&2
hermes dashboard --host 0.0.0.0 --port "$DASHBOARD_INTERNAL_PORT" --no-open --tui --insecure &

# 6b. Start file-access services (optional add-ons; Caddy basic-auth gates
#     them, so filebrowser runs --noauth and rclone runs without auth). Both
#     bind loopback only and are guarded so a failure never blocks the gateway.
#
#     SECURITY: both are rooted at $HERMES_HOME/share, NOT the volume root.
#     The volume root holds secrets (.env, auth.json, .dashboard-password,
#     config.yaml, OAuth tokens, skills, cron). Serving only ./share means
#     those credentials are never reachable (read OR write) over /files or
#     /dav — an allow-list, so a future secret dropped elsewhere stays private.
#     Configure your agent (e.g. via its system prompt) to put anything
#     shareable under ./share.
SHARE_DIR="$HERMES_HOME/share"
mkdir -p "$SHARE_DIR" 2>/dev/null || true
if [ -x "$FILEBROWSER" ]; then
    echo "[secure-start] Starting filebrowser on 127.0.0.1:9121 (/files, root $SHARE_DIR)..." >&2
    "$FILEBROWSER" -r "$SHARE_DIR" -a 127.0.0.1 -p 9121 -b /files \
        -d "$HERMES_HOME/.filebrowser.db" --noauth >/tmp/filebrowser.log 2>&1 &
fi
if [ -x "$RCLONE" ]; then
    echo "[secure-start] Starting rclone WebDAV on 127.0.0.1:9122 (/dav, root $SHARE_DIR)..." >&2
    "$RCLONE" serve webdav "$SHARE_DIR" --addr 127.0.0.1:9122 --baseurl /dav \
        >/tmp/rclone.log 2>&1 &
fi

# Give the dashboard a moment to bind before Caddy tries to proxy to it.
sleep 3

# 7. Foreground: Caddy auth proxy on the public PORT.
echo "[secure-start] Starting Caddy auth proxy on :$PROXY_PORT (user '$USER_NAME')..." >&2
exec "$CADDY" run --config "$HERMES_HOME/Caddyfile" --adapter caddyfile
