#!/usr/bin/env bash
#
# AccessRig uninstaller — by Yousaf Hamza (github.com/yousafkhamza/accessrig)
#
# Usage:
#   curl -fsSL https://yousafkhamza.github.io/accessrig/uninstall.sh | sudo bash
#
# Default behavior is CONSERVATIVE:
#   - Stops and removes the JumpServer containers + branding proxy sidecar.
#   - Leaves /opt/jumpserver (your DB, redis data, config, recordings cache)
#     untouched on disk, and takes a fresh backup tarball before doing anything
#     destructive.
#   - Does NOT remove Docker/git/jq from the box — other things may depend on them.
#
# Flags:
#   --purge-data       Also delete /opt/jumpserver from disk (after a final backup
#                       to /root/accessrig-final-backup-<timestamp>.tar.gz unless
#                       --no-backup is also passed). Requires typing "DELETE" to
#                       confirm unless --yes is passed too.
#   --remove-docker     Also uninstall Docker Engine + compose plugin from the box.
#   --no-backup         Skip the final backup before --purge-data. Only takes effect
#                       together with --purge-data.
#   --yes               Skip the interactive "type DELETE to confirm" prompt.
#   --dry-run           Print what would happen, change nothing.
#
set -euo pipefail

ACCESSRIG_HOME="/opt/jumpserver"
ACCESSRIG_STATE_DIR="${ACCESSRIG_HOME}/.accessrig"
ACCESSRIG_MARKER="${ACCESSRIG_STATE_DIR}/install.json"
BRANDING_PROXY_DIR="${ACCESSRIG_STATE_DIR}/branding-proxy"

PURGE_DATA=false
REMOVE_DOCKER=false
SKIP_BACKUP=false
ASSUME_YES=false
DRY_RUN=false

log()  { echo -e "\033[1;36m[accessrig]\033[0m $*"; }
warn() { echo -e "\033[1;33m[accessrig][warn]\033[0m $*"; }
err()  { echo -e "\033[1;31m[accessrig][error]\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run this as root or with sudo."
}

detect_os() {
  local os_id="" os_id_like=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"; os_id_like="${ID_LIKE:-}"
  fi
  if [[ "$os_id" =~ ^(ubuntu|debian)$ ]] || [[ "$os_id_like" == *debian* ]]; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    PKG_MGR=""
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data)    PURGE_DATA=true; shift ;;
    --remove-docker) REMOVE_DOCKER=true; shift ;;
    --no-backup)     SKIP_BACKUP=true; shift ;;
    --yes)           ASSUME_YES=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

require_root
detect_os

run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] $*"
  else
    eval "$@"
  fi
}

# ---------------------------------------------------------------------------
# Step 1 — stop and remove containers (JumpServer stack + AccessRig branding proxy)
# ---------------------------------------------------------------------------
if [[ -d "$ACCESSRIG_HOME" ]]; then
  COMPOSE_FILE="${ACCESSRIG_HOME}/compose.yml"
  [[ -f "$COMPOSE_FILE" ]] || COMPOSE_FILE="${ACCESSRIG_HOME}/docker-compose.yml"

  if [[ -f "$COMPOSE_FILE" ]] && command -v docker >/dev/null 2>&1; then
    log "Stopping JumpServer containers..."
    if [[ -f "${BRANDING_PROXY_DIR}/docker-compose.override.yml" ]]; then
      run "docker compose -f '$COMPOSE_FILE' -f '${BRANDING_PROXY_DIR}/docker-compose.override.yml' down"
    else
      run "docker compose -f '$COMPOSE_FILE' down"
    fi
  else
    warn "No compose file found under ${ACCESSRIG_HOME} — skipping container teardown."
  fi
else
  warn "${ACCESSRIG_HOME} doesn't exist — JumpServer/AccessRig doesn't look installed on this box."
fi

# ---------------------------------------------------------------------------
# Step 2 — data handling
# ---------------------------------------------------------------------------
if [[ "$PURGE_DATA" == true ]]; then
  if [[ "$SKIP_BACKUP" != true && -d "$ACCESSRIG_HOME" ]]; then
    backup_file="/root/accessrig-final-backup-$(date +%s).tar.gz"
    log "Taking a final backup before deleting anything: ${backup_file}"
    run "tar -czf '$backup_file' -C / opt/jumpserver"
    log "Backup saved. Keep this somewhere safe if you might ever need this data again."
  fi

  if [[ "$ASSUME_YES" != true && "$DRY_RUN" != true ]]; then
    warn "This will permanently delete ${ACCESSRIG_HOME}, including the database, session"
    warn "recordings cache, and all config. Type DELETE to confirm, anything else cancels."
    read -rp "> " confirm
    [[ "$confirm" == "DELETE" ]] || die "Confirmation did not match. Nothing was deleted."
  fi

  log "Removing ${ACCESSRIG_HOME}..."
  run "rm -rf '$ACCESSRIG_HOME'"
else
  log "Data left in place at ${ACCESSRIG_HOME} (pass --purge-data to remove it)."
fi

# ---------------------------------------------------------------------------
# Step 3 — optionally remove Docker itself
# ---------------------------------------------------------------------------
if [[ "$REMOVE_DOCKER" == true ]]; then
  log "Removing Docker Engine + compose plugin (${PKG_MGR:-unknown package manager})..."
  case "$PKG_MGR" in
    apt) run "apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker docker-engine docker.io" ;;
    dnf) run "dnf remove -y docker docker-ce docker-ce-cli containerd.io docker-compose-plugin" ;;
    yum) run "yum remove -y docker docker-ce docker-ce-cli containerd.io docker-compose-plugin" ;;
    *) warn "Unrecognized package manager — remove Docker manually if you want it gone." ;;
  esac
else
  log "Docker Engine left installed (pass --remove-docker to also uninstall it)."
fi

log "Uninstall complete."
[[ "$PURGE_DATA" != true ]] && log "Re-run the installer any time to bring JumpServer back up on the same data."
