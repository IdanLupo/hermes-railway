# Worker profiles: internal-only by design

The deployment runs one public-facing agent (the **default** profile — Telegram,
Discord, webhook) plus six worker profiles used as kanban/delegation targets:

> builder · designer · operator · qa · researcher · strategist

The six workers are **internal agents**. They have no messaging channels and no
long-running gateway. The main agent delegates to them through the kanban board;
the dispatcher (embedded in the default gateway) spawns each worker as a one-shot
`hermes -p <assignee> chat -q "work kanban task …"` process that exits when the
task completes. No profile gateway needs to be running for any of this.

## How that's configured (set 2026-06-11, all via `hermes` CLI)

Per profile (`/opt/data/profiles/<name>/`):

```bash
hermes -p <name> config set platforms.telegram.enabled false
hermes -p <name> config set platforms.discord.enabled false
hermes -p <name> config set platforms.webhook.enabled false
hermes -p <name> config set TELEGRAM_BOT_TOKEN ""   # routed to the profile .env
hermes -p <name> config set DISCORD_BOT_TOKEN ""
hermes -p <name> config set kanban.dispatch_in_gateway false
hermes -p <name> config set kanban.max_spawn 3
```

Notes on why each piece matters:

- **Empty tokens in the profile `.env` are load-bearing.** `TELEGRAM_BOT_TOKEN` /
  `DISCORD_BOT_TOKEN` exist as container-level env vars (Railway variables), and
  the gateway force-enables a platform whenever a token is present in the
  environment — *overriding* `platforms.<name>.enabled` in config.yaml
  (`gateway/config.py:_apply_env_overrides`). The profile's `.env` loads with
  `override=True`, so the empty value masks the container env. Don't delete the
  empty lines.
- **`kanban.dispatch_in_gateway: false`** keeps a profile gateway, if ever
  started, from running a second board dispatcher. Only the default gateway
  dispatches (its root `/opt/data/config.yaml` has `kanban.max_spawn: 3` and
  `cron.max_parallel_jobs: 2` — set after the 2026-06-10 PID-exhaustion
  incident; Railway containers cap at 1000 PIDs and threads count).
- Profile gateway autostart follows the saved state in each profile's
  `gateway_state.json`: only `running` autostarts on container boot
  (`hermes_cli/container_boot.py`). All six are recorded `stopped`.

## Running a worker profile as a live gateway (on demand)

Rarely needed — kanban works without it — but safe now (boots channel-less,
"No messaging platforms enabled", cron-only):

```bash
railway ssh --service hermes-agent -- bash -c "'hermes -p builder gateway start'"
railway ssh --service hermes-agent -- bash -c "'hermes -p builder gateway stop'"
```

Stop state persists across container restarts. If a profile should ever get a
real public channel, give it its **own** bot token (`hermes -p <name> setup`) —
reusing the main agent's token trips Hermes' token-lock guard and the gateway
exits with "bot token already in use".
