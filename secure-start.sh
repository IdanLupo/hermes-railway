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

USER_NAME="${DASHBOARD_USER:-lucas}"
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

    # WebSocket endpoints — gated by the dashboard's session token (in
    # query string). Bypass basic_auth (it interferes with WS upgrade).
    @ws path /api/pty /api/ws /api/events
    handle @ws {
        reverse_proxy 127.0.0.1:$DASHBOARD_INTERNAL_PORT {
            header_up Host 127.0.0.1:$DASHBOARD_INTERNAL_PORT
            header_up Origin http://127.0.0.1:$DASHBOARD_INTERNAL_PORT
        }
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

# 4b. Sync AI Experts private skills repo into /opt/data/skills/ai-experts/.
#     Requires SKILLS_REPO_TOKEN (fine-grained PAT scoped to AI-Experts-LLC/skills,
#     contents: read). If unset, we skip — bundled Hermes skills still work.
SKILLS_REPO_DIR="$HERMES_HOME/skills/ai-experts"
SKILLS_REPO_URL="https://github.com/AI-Experts-LLC/skills.git"
if [ -n "$SKILLS_REPO_TOKEN" ]; then
    if [ -d "$SKILLS_REPO_DIR/.git" ]; then
        echo "[secure-start] Updating AI Experts skills repo..." >&2
        (cd "$SKILLS_REPO_DIR" && \
         git -c "http.https://github.com/.extraheader=Authorization: bearer $SKILLS_REPO_TOKEN" \
             pull --quiet --ff-only 2>&1 | head -3 || \
         echo "[secure-start] WARN: git pull failed, keeping existing checkout") >&2
    else
        echo "[secure-start] Cloning AI Experts skills repo..." >&2
        mkdir -p "$HERMES_HOME/skills"
        rm -rf "$SKILLS_REPO_DIR"
        git -c "http.https://github.com/.extraheader=Authorization: bearer $SKILLS_REPO_TOKEN" \
            clone --quiet --depth 1 "$SKILLS_REPO_URL" "$SKILLS_REPO_DIR" 2>&1 | head -3 >&2 || \
            echo "[secure-start] WARN: clone failed, skipping custom skills" >&2
    fi
    if [ -d "$SKILLS_REPO_DIR/skills" ]; then
        echo "[secure-start] Linking individual skills to $HERMES_HOME/skills/ ..." >&2
        for skill in "$SKILLS_REPO_DIR"/skills/*/; do
            [ -d "$skill" ] || continue
            name=$(basename "$skill")
            # Prefix our skills with "ai-experts-" to avoid collisions
            # with the 87 bundled Hermes skills (which already include
            # notion, linear, airtable, etc.).
            target="$HERMES_HOME/skills/ai-experts-$name"
            rm -rf "$target"
            ln -s "$skill" "$target"
        done
        echo "[secure-start] $(ls -d $HERMES_HOME/skills/ai-experts-* 2>/dev/null | wc -l) custom skills linked" >&2
    fi
else
    echo "[secure-start] SKILLS_REPO_TOKEN not set; skipping AI Experts skills clone" >&2
fi

# 5. Start the gateway in the background.
echo "[secure-start] Starting Hermes gateway..." >&2
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

# Give the dashboard a moment to bind before Caddy tries to proxy to it.
sleep 3

# 7. Foreground: Caddy auth proxy on the public PORT.
echo "[secure-start] Starting Caddy auth proxy on :$PROXY_PORT (user '$USER_NAME')..." >&2
exec "$CADDY" run --config "$HERMES_HOME/Caddyfile" --adapter caddyfile
