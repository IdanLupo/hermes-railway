# Deploy and Host Hermes Agent on Railway

Hermes Agent is a self-hosted AI agent from NousResearch with a native web dashboard for chat, sessions, and analytics. This template wraps the official image with a Caddy HTTP basic-auth reverse proxy, persistent storage, and inbound webhook routing, so the agent runs privately and securely on your own infrastructure.

## About Hosting Hermes Agent

Hosting runs the official `nousresearch/hermes-agent` Docker image on a single Railway service. A startup script boots the Hermes gateway and dashboard on internal loopback ports, then fronts them with a Caddy reverse proxy on the public `$PORT` that enforces bcrypt HTTP basic auth — so the dashboard is never exposed without credentials. All state (config, sessions, OAuth tokens, skills, cron, and the cached Caddy binary) persists to a Railway volume mounted at `/opt/data`. Inbound `/webhooks/*` traffic bypasses basic auth so external services can POST events, gated instead by long random path tokens and optional HMAC signature verification.

## Common Use Cases

- Running a private, authenticated AI agent dashboard for a team without exposing it publicly
- Receiving inbound webhooks (GitHub, Stripe, Svix-style providers, etc.) to trigger autonomous agent actions
- Loading a private organization skills library alongside the skills bundled in the Hermes image

## Dependencies for Hermes Agent Hosting

- The upstream `nousresearch/hermes-agent` Docker image
- A Railway persistent volume mounted at `/opt/data`
- Caddy (auto-downloaded to the volume on first boot for the auth proxy)

### Deployment Dependencies

- Hermes Agent: https://github.com/NousResearch/hermes-agent
- Caddy: https://caddyserver.com/
- Docker image: https://hub.docker.com/r/nousresearch/hermes-agent

### Implementation Details

Environment variables:

| Var | Default | Notes |
|---|---|---|
| `DASHBOARD_USER` | `admin` | HTTP basic-auth username |
| `DASHBOARD_PASSWORD` | *(auto-generated)* | If unset, a 24-char random password is generated and printed to logs |
| `PORT` | `9119` | Public port (Railway sets this automatically) |
| `HERMES_HOME` | `/opt/data` | Volume mount path |
| `SKILLS_REPO_URL` | *(optional)* | HTTPS GitHub URL of a private skills repo to clone at boot |
| `SKILLS_REPO_TOKEN` | *(optional)* | GitHub PAT (`contents: read`) used to clone `SKILLS_REPO_URL` |

Deploy steps:

1. Fork/push this repo and create a Railway service from it.
2. Attach a volume mounted at `/opt/data`.
3. Set `DASHBOARD_USER` and `DASHBOARD_PASSWORD` (optionally `SKILLS_REPO_URL` + `SKILLS_REPO_TOKEN`).
4. Deploy. First boot downloads Caddy (~40 MB) to the volume and caches it for future restarts.

Recommended skills (all ship with the image — no install required):

- **Software development:** `claude-code`, `codex`, `opencode`, `codebase-inspection`, `systematic-debugging`, `test-driven-development`, `github-pr-workflow`, `github-code-review`
- **Productivity & knowledge:** `notion`, `linear`, `obsidian`, `airtable`, `google-workspace`, `arxiv`, `ocr-and-documents`, `plan`
- **Creative & media:** `powerpoint`, `manim-video`, `p5js`, `comfyui`, `youtube-content`, `humanizer`
- **Personal & comms:** `imessage`, `apple-notes`, `apple-reminders`, `findmy`, `spotify`, `maps`
- **Agent infrastructure:** `hermes-agent-skill-authoring`, `webhook-subscriptions`

Optional MCP integrations (public services, bring your own API key): [Composio](https://composio.dev) (1000+ apps), [Replicate](https://replicate.com) (image/video/audio), [AgentMail](https://agentmail.to) (agent email inboxes), [Granola](https://granola.ai) (meeting notes). Add them under `mcp_servers` in `$HERMES_HOME/config.yaml`.

## Why Deploy Hermes Agent on Railway?

<!-- Recommended: Keep this section as shown below -->
Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying Hermes Agent on Railway, you are one step closer to supporting a complete full-stack application with minimal burden. Host your servers, databases, AI agents, and more on Railway.
<!-- End recommended section -->
