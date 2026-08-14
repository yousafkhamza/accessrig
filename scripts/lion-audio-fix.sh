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
# REAL CONTAINER LAYOUT (jumpserver-installer, confirmed against a live box):
#   jms_web   — the actual reverse proxy/web container, published on the host
#               HTTP_PORT (default 80). There is NO container named
#               "jms_nginx" in this installer's layout.
#   jms_lion  — exposes port 8081 on the internal Docker network (not
#               published to the host). This is lion's own embedded server —
#               the thing that actually needs GUAC_AUDIO stripped before it
#               parses the Guacamole protocol.
#
# PORT HANDLING: jms_web's host port comes from HTTP_PORT in the installer's
# .env file (this is JumpServer's own officially-documented override
# mechanism for exactly this situation — see the comment already in that
# file). This script edits that one variable rather than touching compose
# YAML directly, which is a much narrower, safer, well-defined change.
#
# COMPOSE LAYOUT: the project is split across multiple files under
# compose/ (network.yml, core.yml, celery.yml, koko.yml, lion.yml, chen.yml,
# web.yml, redis.yml, postgres.yml). All of them are detected via Docker's
# own compose label and passed together on every invocation — passing only
# one would make Compose think the other services left the project.
#
# Usage:
#   sudo ./lion-audio-fix.sh                          # apply
#   sudo ./lion-audio-fix.sh --remove                 # remove (e.g. before upgrading)
#   sudo ./lion-audio-fix.sh --alt-port 18080          # port jms_web moves to (default 18080)
#   sudo ./lion-audio-fix.sh --compose-files "/a.yml,/b.yml"   # override auto-detection
#
set -euo pipefail

MODE="apply"
COMPOSE_FILES_OVERRIDE=""
ALT_PORT="18080"

log()  { echo -e "\033[1;36m[lion-audio-fix]\033[0m $*"; }
warn() { echo -e "\033[1;33m[lion-audio-fix][warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[lion-audio-fix][error]\033[0m $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) MODE="remove"; shift ;;
    --alt-port) ALT_PORT="$2"; shift 2 ;;
    --compose-files) COMPOSE_FILES_OVERRIDE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this as root or with sudo."
command -v docker >/dev/null 2>&1 || die "docker not found."

# ---------------------------------------------------------------------------
# Detect every compose file the running project actually uses.
# ---------------------------------------------------------------------------
detect_compose_files() {
  if [[ -n "$COMPOSE_FILES_OVERRIDE" ]]; then
    echo "$COMPOSE_FILES_OVERRIDE" | tr ',' '\n'
    return
  fi
  local label_files=""
  for probe_container in jms_core jms_web jms_lion; do
    label_files="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$probe_container" 2>/dev/null || true)"
    [[ -n "$label_files" && "$label_files" != "<no value>" ]] && break
  done
  if [[ -n "$label_files" && "$label_files" != "<no value>" ]]; then
    echo "$label_files" | tr ',' '\n'
    return
  fi
  for candidate in "/opt/jumpserver/compose.yml" "/opt/jumpserver/docker-compose.yml"; do
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

log "Using ${#COMPOSE_FILES[@]} compose file(s) under $(dirname "${COMPOSE_FILES[0]}")"

INSTALLER_DIR="$(dirname "$(dirname "${COMPOSE_FILES[0]}")")"
FIX_DIR="${INSTALLER_DIR}/.accessrig/lion-audio-fix"
ENV_FILE="${INSTALLER_DIR}/.env"
log "Installer directory: ${INSTALLER_DIR}"

[[ -f "$ENV_FILE" ]] || die "Expected .env at ${ENV_FILE} but it's not there. Pass --compose-files if your layout differs, or handle the HTTP_PORT move manually."

# --env-file matters here: docker compose only auto-loads .env from the
# CURRENT WORKING DIRECTORY by default, not from wherever the compose files
# live — since this script can be run from anywhere, that env context has to
# be passed explicitly or every variable in the compose files (HTTP_PORT
# included) silently comes through blank.
COMPOSE_ARGS=(--env-file "$ENV_FILE")
for f in "${COMPOSE_FILES[@]}"; do
  COMPOSE_ARGS+=(-f "$f")
done

# ---------------------------------------------------------------------------
# REMOVE
# ---------------------------------------------------------------------------
if [[ "$MODE" == "remove" ]]; then
  if [[ ! -f "${FIX_DIR}/docker-compose.override.yml" ]]; then
    log "Nothing to remove — fix was never applied on this box."
    exit 0
  fi
  log "Stopping and removing the accessrig-lion-audio-fix sidecar..."
  docker compose "${COMPOSE_ARGS[@]}" -f "${FIX_DIR}/docker-compose.override.yml" stop accessrig-lion-audio-fix || true
  docker compose "${COMPOSE_ARGS[@]}" -f "${FIX_DIR}/docker-compose.override.yml" rm -f accessrig-lion-audio-fix || true

  if grep -q "^HTTP_PORT=${ALT_PORT}$" "$ENV_FILE" 2>/dev/null; then
    log "Reverting HTTP_PORT in ${ENV_FILE} back to 80..."
    sed -i.accessrig-bak "s/^HTTP_PORT=.*/HTTP_PORT=80/" "$ENV_FILE"
    # No specific service name targeted — docker ps shows CONTAINER names
    # (jms_web), which aren't necessarily the same as the compose SERVICE key
    # underneath. A plain "up -d" recreates only what actually changed
    # (the web service, since HTTP_PORT moved) without needing to guess it.
    log "Recreating whatever changed (should just be the web service)..."
    docker compose "${COMPOSE_ARGS[@]}" up -d
  else
    warn "HTTP_PORT in ${ENV_FILE} doesn't match ${ALT_PORT} — leaving it as-is."
    warn "Check it manually if jms_web isn't reachable on port 80 after this."
  fi
  log "Done. Port 80 should be free and jms_web serving it directly again."
  exit 0
fi

# ---------------------------------------------------------------------------
# APPLY
# ---------------------------------------------------------------------------

CURRENT_HTTP_PORT="$(grep '^HTTP_PORT=' "$ENV_FILE" | cut -d= -f2 || echo 80)"
CURRENT_HTTP_PORT="${CURRENT_HTTP_PORT:-80}"

if [[ "$CURRENT_HTTP_PORT" == "$ALT_PORT" ]]; then
  die "ALT_PORT (${ALT_PORT}) is the same as the current HTTP_PORT — pick a different --alt-port."
fi

mkdir -p "$FIX_DIR"

# ---------------------------------------------------------------------------
# OpenResty (nginx + Lua) config. Only /lion/ws/connect/ is touched — proxied
# DIRECTLY to jms_lion:8081 (lion's own embedded server, reachable on the
# internal Docker network regardless of any host port mapping). Everything
# else goes to jms_web:80 — its CONTAINER port, which stays 80 internally no
# matter what HTTP_PORT the host side is remapped to.
# ---------------------------------------------------------------------------
cat > "${FIX_DIR}/nginx.conf" <<'NGINXEOF'
server {
    listen 80;

    location /lion/ws/connect/ {
        rewrite_by_lua_block {
            local args = ngx.req.get_uri_args()
            args["GUAC_AUDIO"] = nil
            ngx.req.set_uri_args(args)
        }
        proxy_pass http://jms_lion:8081$uri?$args;
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

    location / {
        proxy_pass http://jms_web:80;
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

log "Moving jms_web off host port 80: HTTP_PORT ${CURRENT_HTTP_PORT} -> ${ALT_PORT} in ${ENV_FILE}"
sed -i.accessrig-bak "s/^HTTP_PORT=.*/HTTP_PORT=${ALT_PORT}/" "$ENV_FILE"
log "Backed up original .env to ${ENV_FILE}.accessrig-bak"

log "Recreating whatever changed (should just be the web service, since HTTP_PORT moved)..."
docker compose "${COMPOSE_ARGS[@]}" up -d

log "Starting the audio-fix sidecar on port 80..."
docker compose "${COMPOSE_ARGS[@]}" -f "${FIX_DIR}/docker-compose.override.yml" up -d accessrig-lion-audio-fix

echo ""
log "Done. Retry the RDP connection that was showing a black screen."
log "To undo all of this later: sudo ./lion-audio-fix.sh --remove --alt-port ${ALT_PORT}"
