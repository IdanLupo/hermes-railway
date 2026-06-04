# hermes-railway — minimal Railway deploy image for Hermes Agent
# with a Caddy HTTP basic-auth reverse proxy in front of the dashboard.
#
# Adapted from Shinyduo/hermes-agent (MIT) by adding auth.

# Pinned to nousresearch/hermes-agent:latest as published 2026-05-29 00:44 UTC
# (digest below). The 2026-05-28 build (sha256:35c8784e...) shipped a broken
# boot sequence (tools/skills_sync.py crashed on `import hermes_constants`),
# which took the service down. Pinning a digest forces a deterministic pull.
# To update later: re-pin to the new `latest` digest and verify a clean boot.
#   curl -s https://hub.docker.com/v2/repositories/nousresearch/hermes-agent/tags/latest | jq -r .digest
FROM nousresearch/hermes-agent@sha256:04101b5907d0e71042046201f6515df700360fe32191777ee96664d2f1eb358a

# secure-start.sh boots:
#   1) hermes gateway (background)
#   2) hermes dashboard on 127.0.0.1:9120 (background, no public binding)
#   3) Caddy on $PORT (foreground) with HTTP basic auth -> reverse_proxy
#
# Credentials come from env: DASHBOARD_USER, DASHBOARD_PASSWORD.
# If DASHBOARD_PASSWORD is unset, a random 24-char password is generated
# and printed to logs (visible in `railway logs`).
#
# Caddy binary is downloaded on first boot to /opt/data/bin/caddy and
# cached there for subsequent restarts (the volume persists).
COPY secure-start.sh /opt/hermes/secure-start.sh
RUN chmod +x /opt/hermes/secure-start.sh

# Default agent identity. secure-start.sh renders this into $HERMES_HOME/SOUL.md
# on boot (replacing the stock "# Hermes Agent Persona" default), unless the
# operator has customized it. Edit default-soul.md to change the seeded persona.
COPY default-soul.md /opt/hermes/default-soul.md

# Safety net for the skills_sync boot crash seen in the 2026-05-28 image:
# tools/skills_sync.py runs at boot but its sys.path[0] is tools/, so the
# module-level `from hermes_constants import ...` (hermes_constants.py lives at
# /opt/hermes) raises ModuleNotFoundError and crash-loops the container. A
# runtime PYTHONPATH doesn't survive the entrypoint's privilege drop, so patch
# at build time. Tolerant: no-op if the file is gone or upstream already fixed
# the import (so this Dockerfile keeps working once a fixed image is pinned).
RUN python3 -c "import os; p='/opt/hermes/tools/skills_sync.py'; (os.path.exists(p) and (lambda L: (lambda m: (L.insert(m[0], L[m[0]][:len(L[m[0]])-len(L[m[0]].lstrip())]+'import sys; sys.path.insert(0, '+chr(34)+'/opt/hermes'+chr(34)+')'), open(p,'w').write(chr(10).join(L)), print('PATCHED skills_sync at line', m[0])) if m else print('skills_sync: import already OK, no patch'))([k for k,l in enumerate(L) if 'from hermes_constants import' in l]))(open(p).read().split(chr(10)))) or print('skills_sync: file absent, no patch')"

# The 2026-05-xx images migrated to s6-overlay v3. The real entrypoint is
# /init + main-wrapper.sh, which runs cont-init hooks, repopulates the env
# (with-contenv), activates the venv, and drops to the `hermes` user before
# exec'ing the CMD. The old `docker/entrypoint.sh` is now a deprecated shim
# that runs a cont-init hook but NEVER execs the CMD — hardcoding it as the
# ENTRYPOINT silently kept Hermes from ever starting. So we keep the image's
# s6 entrypoint and just pass secure-start.sh as the CMD; main-wrapper sees an
# executable first arg and runs `s6-setuidgid hermes /opt/hermes/secure-start.sh`.
ENTRYPOINT [ "/init", "/opt/hermes/docker/main-wrapper.sh" ]
CMD [ "/opt/hermes/secure-start.sh" ]
