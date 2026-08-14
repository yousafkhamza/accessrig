#!/usr/bin/env bash
#
# lion-audio-fix.sh — by Yousaf Hamza
#
# Single purpose: strip the GUAC_AUDIO query parameter(s) from requests to
# Lion's /lion/ws/connect/ endpoint before they ever reach Lion's Guacamole
# protocol parser. This is what's causing:
#   "5.audio,1.1,31.audio/L16; instruction with bad Content: ..."
#   and the resulting black-screen RDP sessions.
#
# Root cause: Luna's client-side JS unconditionally appends
# GUAC_AUDIO=audio/L8 and GUAC_AUDIO=audio/L16 to every RDP connection
# request. There is no server-side toggle for this in JumpServer's platform
# settings — it's not configurable, so the only place left to intervene is
# the network path between browser and Lion.
#
# This is NOT the branding-proxy / org-name script — that's a separate,
# unrelated tool. This one only touches query args on one specific path and
# leaves everything else (headers, body, all other routes) completely alone.
#
# Usage:
#   sudo ./lion-audio-fix.sh              # install/apply the fix
#   sudo ./lion-audio-fix.sh --remove     # stop and remove the sidecar (e.g. before upgrading JumpServer)
#
set -euo pipefail

JMS_DIR="/opt/jumpserver"
FIX_DIR="${JMS_DIR}/.accessrig/lion-audio-fix"
MODE="apply"

log()  { echo -e "\033[1;36m[lion-audio-fix]\033[0m $*"; }
warn() { echo -e "\033[1;33m[lion-audio-fix][warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[lion-audio-fix][error]\033[0m $*" >&2; exit 1; }

[[ "${1:-}" == "--remove" ]] && MODE="remove"

[[ $EUID -eq 0 ]] || die "Run this as root or with sudo."

COMPOSE_FILE="${JMS_DIR}/compose.yml"
[[ -f "$COMPOSE_FILE" ]] || COMPOSE_FILE="${JMS_DIR}/docker-compose.yml"
[[ -f "$COMPOSE_FILE" ]] || die "Could not find compose.yml/docker-compose.yml under ${JMS_DIR}. Check the path and re-run manually."

if [[ "$MODE" == "remove" ]]; then
  if [[ ! -f "${FIX_DIR}/docker-compose.override.yml" ]]; then
    log "Nothing to remove — ${FIX_DIR}/docker-compose.override.yml doesn't exist. Fix was never applied on this box."
    exit 0
  fi
  log "Stopping and removing the accessrig-lion-audio-fix sidecar..."
  docker compose -f "$COMPOSE_FILE" -f "${FIX_DIR}/docker-compose.override.yml" stop accessrig-lion-audio-fix || true
  docker compose -f "$COMPOSE_FILE" -f "${FIX_DIR}/docker-compose.override.yml" rm -f accessrig-lion-audio-fix || true
  echo ""
  warn "MANUAL STEP: revert jms_nginx's port mapping in ${COMPOSE_FILE} back from"
  warn "8081:80 to 80:80 (the exact opposite of the change you made when applying"
  warn "this fix), then bring it back up WITHOUT the override file:"
  echo ""
  echo "  docker compose -f ${COMPOSE_FILE} up -d"
  echo ""
  log "Port 80 is free once that's done — safe to run an upgrade now."
  exit 0
fi

mkdir -p "$FIX_DIR"

# ---------------------------------------------------------------------------
# OpenResty (nginx + Lua) config — Lua is required here because plain nginx
# can't reliably strip a repeated query parameter (GUAC_AUDIO appears twice:
# audio/L8 and audio/L16). Only the /lion/ws/connect/ path is touched; every
# other path is a plain passthrough with no modification at all.
# ---------------------------------------------------------------------------
cat > "${FIX_DIR}/nginx.conf" <<'NGINXEOF'
server {
    listen 80;

    # Strip GUAC_AUDIO before it reaches Lion — this is the actual fix.
    location /lion/ws/connect/ {
        rewrite_by_lua_block {
            local args = ngx.req.get_uri_args()
            args["GUAC_AUDIO"] = nil
            ngx.req.set_uri_args(args)
        }
        proxy_pass http://jms_nginx:8081$uri?$args;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Everything else — untouched passthrough, including other websocket
    # paths (koko, etc.) which need the same upgrade headers to keep working.
    location / {
        proxy_pass http://jms_nginx:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINXEOF

cat > "${FIX_DIR}/docker-compose.override.yml" <<EOF
# Merge this into your main compose invocation:
#   docker compose -f ${COMPOSE_FILE} -f ${FIX_DIR}/docker-compose.override.yml up -d
services:
  accessrig-lion-audio-fix:
    image: openresty/openresty:alpine
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ${FIX_DIR}/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - default
EOF

log "Wrote ${FIX_DIR}/nginx.conf and docker-compose.override.yml"
echo ""
warn "MANUAL STEP (same as always with a fronting proxy — this can't be safely"
warn "automated without risking your existing port mappings): in ${COMPOSE_FILE},"
warn "change jms_nginx's port mapping from 80:80 to 8081:80, then run:"
echo ""
echo "  docker compose -f ${COMPOSE_FILE} -f ${FIX_DIR}/docker-compose.override.yml up -d"
echo ""
log "After that, retry the RDP connection that was showing a black screen."
log "If you also have the branding-proxy running from earlier, remove it first —"
log "you don't want two proxies both trying to bind port 80:"
echo "  docker compose -f ${COMPOSE_FILE} -f ${JMS_DIR}/.accessrig/branding-proxy/docker-compose.override.yml stop accessrig-branding-proxy"
echo "  docker compose -f ${COMPOSE_FILE} -f ${JMS_DIR}/.accessrig/branding-proxy/docker-compose.override.yml rm -f accessrig-branding-proxy"
