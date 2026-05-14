# hermes-railway — minimal Railway deploy image for Hermes Agent
# with a Caddy HTTP basic-auth reverse proxy in front of the dashboard.
#
# Adapted from Shinyduo/hermes-agent (MIT) by adding auth.

FROM nousresearch/hermes-agent:latest

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

# Keep the official entrypoint (tini + privilege drop + dir bootstrap +
# skill sync), just swap the command it ultimately execs.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh"]
CMD ["/opt/hermes/secure-start.sh"]
