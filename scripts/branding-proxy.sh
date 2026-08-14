#!/usr/bin/env bash
#
# branding-proxy.sh <ORG_NAME>
#
# HONEST NOTE FIRST: logo/title white-labeling ("Appearance" settings) is an
# Enterprise-only feature in current JumpServer — Community edition has no
# supported UI or API for it. This script is a workaround, not an official
# feature, and it is OFF by default risk-wise in that it never touches the
# JumpServer containers themselves.
#
# What it does: drops a tiny nginx sidecar in front of the existing
# JumpServer nginx container that text-substitutes "JumpServer" -> your org
# name in outgoing HTML/JS using nginx's sub_filter. Because it only rewrites
# the HTTP response body on the way out, it survives JumpServer upgrades
# (you're not patching anything inside their images).
#
# It moves the JumpServer web port from 80 -> 8081 internally and puts this
# proxy on 80 instead. Review docker-compose.yml under /opt/jumpserver before
# running this on a box that already has custom port mappings.
#
set -euo pipefail
ORG_NAME="${1:?usage: branding-proxy.sh <org-name>}"
JMS_DIR="/opt/jumpserver"
PROXY_DIR="${JMS_DIR}/.accessrig/branding-proxy"

echo "[branding-proxy] Target org name: ${ORG_NAME}"
echo "[branding-proxy] This is best-effort cosmetic branding, not an official JumpServer feature."
echo "[branding-proxy] Skipping if compose file layout looks unfamiliar — check manually."

COMPOSE_FILE="${JMS_DIR}/compose.yml"
[[ -f "$COMPOSE_FILE" ]] || COMPOSE_FILE="${JMS_DIR}/docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[branding-proxy] Could not find compose.yml/docker-compose.yml under ${JMS_DIR}."
  echo "[branding-proxy] Skipping branding proxy — install still succeeded, this is cosmetic only."
  exit 0
fi

mkdir -p "$PROXY_DIR"

cat > "${PROXY_DIR}/nginx.conf" <<EOF
server {
    listen 80;
    location / {
        proxy_pass http://jms_nginx:8081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        sub_filter 'JumpServer' '${ORG_NAME}';
        sub_filter 'jumpserver' '${ORG_NAME}';
        sub_filter_once off;
        sub_filter_types text/html application/javascript;
    }
}
EOF

cat > "${PROXY_DIR}/docker-compose.override.yml" <<EOF
# Merge this into your main compose invocation:
#   docker compose -f ${COMPOSE_FILE} -f ${PROXY_DIR}/docker-compose.override.yml up -d
services:
  accessrig-branding-proxy:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ${PROXY_DIR}/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - default
EOF

echo "[branding-proxy] Wrote ${PROXY_DIR}/nginx.conf and docker-compose.override.yml"
echo "[branding-proxy] MANUAL STEP: change jms_nginx's port mapping from 80:80 to 8081:80"
echo "[branding-proxy] in ${COMPOSE_FILE}, then run:"
echo "  docker compose -f ${COMPOSE_FILE} -f ${PROXY_DIR}/docker-compose.override.yml up -d"
echo "[branding-proxy] Verify http://<ec2-ip> shows '${ORG_NAME}' in the browser tab before relying on it."
