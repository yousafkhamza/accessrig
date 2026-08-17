#!/usr/bin/env bash
#
# AccessRig uninstaller — by Yousaf Hamza (github.com/yousafkhamza/accessrig)
#
# Usage:
#   curl -fsSL https://yousafkhamza.github.io/accessrig/uninstall.sh | sudo bash
#
# Rewritten to match the REAL jumpserver-installer layout (versioned
# /opt/jumpserver-installer-v<X.Y.Z>/ directories + persistent shared config
# at /opt/jumpserver/config/, real data at /data/jumpserver/) — the previous
# version of this script assumed the older single-directory quick_start.sh
# layout, which doesn't match how modern JumpServer actually deploys.
#
# Default behavior is CONSERVATIVE:
#   - Runs `jmsctl.sh down` from the current installer directory (the
#     officially documented full-stop command — stops everything, containers
#     included, but does not touch the database volume or shared config).
#   - Leaves /opt/jumpserver/config (shared config incl. SECRET_KEY,
#     BOOTSTRAP_TOKEN, DOMAINS) and /data/jumpserver (real DB/recordings data)
#     untouched on disk, and takes a fresh backup tarball before doing
#     anything destructive.
#   - Does NOT remove Docker/git/jq from the box — other things may depend on it.
#
# Flags:
#   --purge-data       Also delete /opt/jumpserver-installer-v*/ directories,
#                       /opt/jumpserver/config, AND /data/jumpserver (the real
#                       database/recordings data) — this is a genuinely full
#                       wipe, not just stopping containers. Takes a final
#                       backup to /root/accessrig-final-backup-<timestamp>.tar.gz
#                       first unless --no-backup is also passed. Requires
#                       typing "DELETE" to confirm unless --yes is also passed.
#   --remove-docker     Also uninstall Docker Engine + compose plugin from the box.
#   --no-backup         Skip the final backup before --purge-data.
#   --yes               Skip the interactive "type DELETE to confirm" prompt.
#   --dry-run           Print what would happen, change nothing.
#
set -euo pipefail

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
# Detect the current installer directory the same way install.sh does — via
# Docker's own compose label, not a guessed path (the versioned directory
# name changes on every upgrade).
# ---------------------------------------------------------------------------
INSTALLER_DIR=""
label_files="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' jms_core 2>/dev/null || true)"
if [[ -n "$label_files" && "$label_files" != "<no value>" ]]; then
  first_file="$(echo "$label_files" | cut -d',' -f1)"
  if [[ -f "$first_file" ]]; then
    INSTALLER_DIR="$(dirname "$(dirname "$first_file")")"
  fi
fi

if [[ -z "$INSTALLER_DIR" ]]; then
  # Fall back to the newest-looking versioned directory on disk, if any.
  INSTALLER_DIR="$(ls -d /opt/jumpserver-installer-v* 2>/dev/null | sort -V | tail -n1 || true)"
fi

if [[ -z "$INSTALLER_DIR" || ! -d "$INSTALLER_DIR" ]]; then
  warn "Could not find a jumpserver-installer directory — JumpServer may not be installed,"
  warn "or containers aren't currently running (label detection needs at least jms_core up)."
  warn "Skipping container teardown. If you know the path, stop it manually with:"
  warn "  cd /opt/jumpserver-installer-vX.Y.Z && ./jmsctl.sh down"
else
  log "Found installer directory: ${INSTALLER_DIR}"

  # ---------------------------------------------------------------------------
  # The real, officially documented full-stop command.
  # ---------------------------------------------------------------------------
  if [[ -f "${INSTALLER_DIR}/jmsctl.sh" ]]; then
    log "Running jmsctl.sh down (stops all containers, leaves data/config untouched)..."
    run "( cd '$INSTALLER_DIR' && chmod +x ./jmsctl.sh && ./jmsctl.sh down )"
  else
    warn "No jmsctl.sh found in ${INSTALLER_DIR} — stopping containers directly instead."
    run "docker ps -a --format '{{.Names}}' | grep '^jms_' | xargs -r docker rm -f"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — data handling. Real persistent data lives in TWO places:
#   /opt/jumpserver/config    — shared config (SECRET_KEY, BOOTSTRAP_TOKEN, DOMAINS)
#   /data/jumpserver          — the actual database/recordings/uploads data
# The versioned /opt/jumpserver-installer-v*/ directories themselves are
# closer to release bundles than data — safe to always remove those, they're
# just re-downloaded on next install.
# ---------------------------------------------------------------------------
if [[ "$PURGE_DATA" == true ]]; then
  if [[ "$SKIP_BACKUP" != true ]]; then
    backup_file="/root/accessrig-final-backup-$(date +%s).tar.gz"
    log "Taking a final backup before deleting anything: ${backup_file}"
    tar_targets=""
    [[ -d /opt/jumpserver/config ]] && tar_targets="$tar_targets opt/jumpserver/config"
    [[ -d /data/jumpserver ]] && tar_targets="$tar_targets data/jumpserver"
    if [[ -n "$tar_targets" ]]; then
      run "tar -czf '$backup_file' -C / $tar_targets"
      log "Backup saved. Keep this somewhere safe if you might ever need this data again."
    else
      warn "Neither /opt/jumpserver/config nor /data/jumpserver exist — nothing to back up."
    fi
  fi

  if [[ "$ASSUME_YES" != true && "$DRY_RUN" != true ]]; then
    warn "This will permanently delete:"
    warn "  /opt/jumpserver-installer-v*/  (all versioned installer directories)"
    warn "  /opt/jumpserver/config/        (shared config, secret keys, DOMAINS)"
    warn "  /data/jumpserver/              (the real database, recordings, uploads)"
    warn "Type DELETE to confirm, anything else cancels."
    read -rp "> " confirm
    [[ "$confirm" == "DELETE" ]] || die "Confirmation did not match. Nothing was deleted."
  fi

  log "Removing versioned installer directories..."
  run "rm -rf /opt/jumpserver-installer-v*"
  log "Removing shared config..."
  run "rm -rf /opt/jumpserver"
  log "Removing real data directory..."
  run "rm -rf /data/jumpserver"
else
  log "Data left in place: /opt/jumpserver/config and /data/jumpserver (pass --purge-data to remove)."
  log "Versioned installer directories under /opt/jumpserver-installer-v*/ also left as-is."
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
