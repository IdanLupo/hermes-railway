# hermes-railway

Minimal Railway deploy template for [Hermes Agent](https://github.com/NousResearch/hermes-agent), with HTTP basic auth in front of the native dashboard.

## What it does

- `FROM nousresearch/hermes-agent:latest` (the official upstream image)
- Boots `hermes gateway` and `hermes dashboard` (the full native Hermes dashboard - Chat tab, sessions, analytics, all of it)
- Puts a [Caddy](https://caddyserver.com/) HTTP basic-auth reverse proxy in front so the dashboard is not publicly accessible without credentials
- All state persists to the Railway volume at `/opt/data`

## Env vars

| Var | Default | Notes |
|---|---|---|
| `DASHBOARD_USER` | `lucas` | HTTP basic-auth username |
| `DASHBOARD_PASSWORD` | *(auto-generated)* | If unset, a 24-char random password is generated and printed to logs |
| `PORT` | `9119` | Public port (Railway sets this automatically) |
| `HERMES_HOME` | `/opt/data` | Volume mount path |

## Deploy

1. Fork this repo or push it as your own.
2. On Railway, create a service from your GitHub fork.
3. Attach a volume mounted at `/opt/data`.
4. Set `DASHBOARD_USER` and `DASHBOARD_PASSWORD` env vars.
5. Deploy. On first boot the Caddy binary downloads to the volume (~40 MB) and caches there forever.

## Rollback

If anything goes sideways, swap the `CMD` in the Dockerfile back to `/opt/hermes/railway-start.sh` (the upstream default) and redeploy. Auth disappears, native behaviour returns.
