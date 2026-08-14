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
# COMPOSE LAYOUT: the official "jumpserver-installer" tool deploys to a
# VERSIONED directory (/opt/jumpserver-installer-v<X.Y.Z>/ — this changes on
# every upgrade) with the project split across multiple compose files under
# compose/ (network.yml, core.yml, celery.yml, koko.yml, lion.yml, chen.yml,
# web.yml, redis.yml, postgres.yml). This script detects and passes ALL of
# them via multiple -f flags on every invocation — passing only one would
# make Compose think the other services aren't part of the project anymore.
#
# Usage:
#   sudo ./lion-audio-fix.sh                                  # install/apply the fix
#   sudo ./lion-audio-fix.sh --remove                         # stop and remove the sidecar (e.g. before upgrading)
#   sudo ./lion-audio-fix.sh --compose-files "/path/a.yml,/path/b.yml"   # override auto-detection
#
set -euo pipefail

MODE="apply"
COMPOSE_FILES_OVERRIDE=""

log()  { echo -e "\033[1;36m[lion-audio-fix]\033[0m $*"; }
warn() { echo -e "\033[1;33m[lion-audio-fix][warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[lion-audio-fix][error]\033[0m $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) MODE="remove"; shift ;;
    --compose-files) COMPOSE_FILES_OVERRIDE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this as root or with sudo."

# ---------------------------------------------------------------------------
# Detect every compose file the running project actually uses, straight from
# Docker's own compose label — comma-separated, could be one file or several.
# ---------------------------------------------------------------------------
detect_compose_files() {
  if [[ -n "$COMPOSE_FILES_OVERRIDE" ]]; then
    echo "$COMPOSE_FILES_OVERRIDE" | tr ',' '\n'
    return
  fi

  local label_files=""
  for probe_container in jms_core jms_nginx jms_lion jms_web; do
    label_files="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$probe_container" 2>/dev/null || true)"
    [[ -n "$label_files" && "$label_files" != "<no value>" ]] && break
  done

  if [[ -n "$label_files" && "$label_files" != "<no value>" ]]; then
    echo "$label_files" | tr ',' '\n'
    return
  fi

  # Fallback for the older single-file quick_start.sh layout.
  for candidate in "/opt/jumpserver/compose.yml" "/opt/jumpserver/docker-compose.yml" \
                   "/opt/jumpserver/compose.yaml" "/opt/jumpserver/docker-compose.yaml"; do
    [[ -f "$candidate" ]] && { echo "$candidate"; return; }
  done
}

mapfile -t COMPOSE_FILES < <(detect_compose_files)

if [[ ${#COMPOSE_FILES[@]} -eq 0 || -z "${COMPOSE_FILES[0]}" ]]; then
  die "Could not auto-detect any compose files. Find them yourself with:
    docker inspect --format '{{ index .Config.Labels \"com.docker.compose.project.config_files\" }}' jms_core
  then re-run with:
    sudo ./lion-audio-fix.sh --compose-files \"/path/a.yml,/path/b.yml,...\""
fi

for f in "${COMPOSE_FILES[@]}"; do
  [[ -f "$f" ]] || die "Detected compose file does not exist on disk: $f"
done

log "Using ${#COMPOSE_FILES[@]} compose file(s):"
for f in "${COMPOSE_FILES[@]}"; do log "  - $f"; done

# The installer directory is the parent of compose/ — e.g. the first file is
# .../jumpserver-installer-v4.10.15/compose/network.yml, so going up two
# levels gets the versioned installer root. This directory CHANGES on every
# upgrade, so it's re-detected fresh every time this script runs rather than
# assumed or cached anywhere.
INSTALLER_DIR="$(dirname "$(dirname "${COMPOSE_FILES[0]}")")"
FIX_DIR="${INSTALLER_DIR}/.accessrig/lion-audio-fix"
log "Installer directory: ${INSTALLER_DIR}"

# Build the repeated "-f file1 -f file2 ..." argument list once, used by
# every docker compose invocation below.
COMPOSE_ARGS=()
for f in "${COMPOSE_FILES[@]}"; do
  COMPOSE_ARGS+=(-f "$f")
done

if [[ "$MODE" == "remove" ]]; then
  if [[ ! -f "${FIX_DIR}/docker-compose.override.yml" ]]; then
    log "Nothing to remove — ${FIX_DIR}/docker-compose.override.yml doesn't exist. Fix was never applied on this box."
    exit 0
  fi
  log "Stopping and removing the accessrig-lion-audio-fix sidecar..."
  docker compose "${COMPOSE_ARGS[@]}" -f "${FIX_DIR}/docker-compose.override.yml" stop accessrig-lion-audio-fix || true
  docker compose "${COMPOSE_ARGS[@]}" -f "${FIX_DIR}/docker-compose.override.yml" rm -f accessrig-lion-audio-fix || true
  echo ""
  warn "MANUAL STEP: find and revert the port-80 mapping you changed when applying"
  warn "this fix (it was moved from 80:80 to 8081:80 in one of the files below —"
  warn "find exactly which one, rather than guess, with:"
  echo ""
  echo "  grep -l '8081:80' ${INSTALLER_DIR}/compose/*.yml"
  echo ""
  warn "change that 8081:80 back to 80:80, then bring everything back up WITHOUT"
  warn "the override file:"
  echo ""
  echo "  docker compose ${COMPOSE_ARGS[*]} up -d"
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
# Merge this into your main compose invocation (ALL of the original -f files
# are required, not just one — see the command printed below):
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
warn "MANUAL STEP (can't be automated safely without risking your existing port"
warn "mappings): find which compose file maps port 80 for the web/nginx"
warn "container, and change it from 80:80 to 8081:80:"
echo ""
echo "  grep -l '80:80' ${INSTALLER_DIR}/compose/*.yml"
echo ""
warn "Edit that file, then bring everything up together — note this needs ALL"
warn "of the original compose files plus the override, every time:"
echo ""
echo "  docker compose ${COMPOSE_ARGS[*]} -f ${FIX_DIR}/docker-compose.override.yml up -d"
echo ""
log "After that, retry the RDP connection that was showing a black screen."
