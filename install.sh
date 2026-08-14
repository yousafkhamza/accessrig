#!/usr/bin/env bash
#
# AccessRig — a curl|bash installer/updater wrapper around JumpServer (Community, Docker).
# By Yousaf Hamza (github.com/yousafkhamza)
# Repo:   https://github.com/yousafkhamza/accessrig
#
# JumpServer is built and owned by Fit2Cloud / the JumpServer open-source project
# (https://github.com/jumpserver/jumpserver). AccessRig does not modify JumpServer
# itself — it just makes install, day-2 config, and safe upgrades one command on a
# fresh EC2 box. Dependencies (git, Docker Engine, compose plugin) are checked and
# installed automatically if missing — nothing is assumed to be on the box already.
#
# Usage (fresh box):
#   curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- \
#       --org-name "Google" \
#       --s3-bucket "jumpserver-recordings-prod" \
#       --s3-region "eu-central-1" \
#       --timezone "Asia/Dubai" \
#       --language "en"
#
# Re-running the exact same command on a box that already has AccessRig/JumpServer
# installed switches automatically into UPDATE mode: it checks the running version
# against the latest upstream LTS release, backs up /opt/jumpserver, and upgrades
# in place. No prompts are shown in that mode unless you pass --interactive.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / flags
# ---------------------------------------------------------------------------
ACCESSRIG_HOME="/opt/jumpserver"
ACCESSRIG_STATE_DIR="${ACCESSRIG_HOME}/.accessrig"
ACCESSRIG_MARKER="${ACCESSRIG_STATE_DIR}/install.json"
BACKUP_DIR="${ACCESSRIG_HOME}/backups"
JUMPSERVER_REPO="jumpserver/jumpserver"          # upstream GitHub repo
QUICKSTART_URL_BASE="https://github.com/jumpserver/jumpserver/releases/latest/download"

ORG_NAME=""
S3_BUCKET=""
S3_REGION=""
TIMEZONE="Asia/Dubai"
LANGUAGE_CODE="en"
INTERACTIVE=false
FORCE_VERSION=""     # pin to a specific tag instead of "latest"
ENABLE_BRANDING_PROXY=true
DRY_RUN=false

log()  { echo -e "\033[1;36m[accessrig]\033[0m $*"; }
warn() { echo -e "\033[1;33m[accessrig][warn]\033[0m $*"; }
err()  { echo -e "\033[1;31m[accessrig][error]\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run this as root or with sudo."
  fi
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-name)     ORG_NAME="$2"; shift 2 ;;
    --s3-bucket)    S3_BUCKET="$2"; shift 2 ;;
    --s3-region)    S3_REGION="$2"; shift 2 ;;
    --timezone)     TIMEZONE="$2"; shift 2 ;;
    --language)     LANGUAGE_CODE="$2"; shift 2 ;;
    --version)      FORCE_VERSION="$2"; shift 2 ;;
    --no-branding-proxy) ENABLE_BRANDING_PROXY=false; shift ;;
    --interactive)  INTERACTIVE=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

require_root

# ---------------------------------------------------------------------------
# Step 0 — decide install vs update BEFORE asking anything
# ---------------------------------------------------------------------------
MODE="install"
if [[ -f "$ACCESSRIG_MARKER" ]]; then
  MODE="update"
fi
log "Mode: $MODE"

# ---------------------------------------------------------------------------
# Step 1 — interactive prompts (only if flags weren't passed and it's a fresh install)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "install" ]]; then
  if [[ -z "$ORG_NAME" && "$INTERACTIVE" == true ]]; then
    read -rp "Organization name (shown on dashboard): " ORG_NAME
  fi
  if [[ -z "$S3_BUCKET" && "$INTERACTIVE" == true ]]; then
    read -rp "S3 bucket for session recordings (blank to skip): " S3_BUCKET
  fi
  if [[ -n "$S3_BUCKET" && -z "$S3_REGION" && "$INTERACTIVE" == true ]]; then
    read -rp "S3 region [eu-central-1]: " S3_REGION
    S3_REGION="${S3_REGION:-eu-central-1}"
  fi
  ORG_NAME="${ORG_NAME:-Org}"
fi

# ---------------------------------------------------------------------------
# Helpers: idempotent dependency checks
# ---------------------------------------------------------------------------
ensure_git() {
  if command -v git >/dev/null 2>&1; then
    log "git already present ($(git --version))"
    return
  fi
  log "Installing git..."
  apt-get update -y
  apt-get install -y git
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker + compose plugin already present ($(docker --version))"
    return
  fi

  log "Installing Docker Engine + compose plugin..."
  apt-get remove -y docker docker-engine docker.io containerd runc || true
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  if id "ubuntu" >/dev/null 2>&1; then
    usermod -aG docker ubuntu || true
  fi
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 || { apt-get update -y && apt-get install -y jq; }
}

# ---------------------------------------------------------------------------
# Version discovery (uses api.github.com — no auth needed for public releases)
# ---------------------------------------------------------------------------
latest_upstream_tag() {
  curl -fsSL "https://api.github.com/repos/${JUMPSERVER_REPO}/releases/latest" | jq -r '.tag_name'
}

current_installed_tag() {
  # JumpServer's core image is tagged with the version; read it from the running container.
  docker inspect --format '{{.Config.Image}}' jms_core 2>/dev/null | awk -F: '{print $NF}' || echo ""
}

# ---------------------------------------------------------------------------
# Fresh install flow
# ---------------------------------------------------------------------------
do_install() {
  ensure_git
  ensure_docker
  ensure_jq

  mkdir -p "$ACCESSRIG_HOME" "$ACCESSRIG_STATE_DIR" "$BACKUP_DIR"

  local target_tag="${FORCE_VERSION:-$(latest_upstream_tag)}"
  log "Installing JumpServer ${target_tag}"

  # Pre-seed language + timezone before first boot so the whole stack (core,
  # koko, lion, celery) comes up already in the right locale — this is the
  # config JumpServer reads on container init, and it persists because
  # /opt/jumpserver is a bind mount, not a container-internal path.
  mkdir -p "${ACCESSRIG_HOME}/config"
  cat > "${ACCESSRIG_HOME}/config/config.yml" <<EOF
LANGUAGE_CODE: ${LANGUAGE_CODE}
USE_I18N: true
TIME_ZONE: ${TIMEZONE}
EOF

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Would download quick_start.sh (tag ${target_tag}) and run it."
  else
    curl -fsSL "https://github.com/jumpserver/jumpserver/releases/download/${target_tag}/quick_start.sh" \
      -o /tmp/quick_start.sh
    chmod +x /tmp/quick_start.sh
    ( cd "${ACCESSRIG_HOME}" && /tmp/quick_start.sh )
  fi

  # Write the install marker — this is what flips future runs into update mode.
  cat > "$ACCESSRIG_MARKER" <<EOF
{
  "installed_version": "${target_tag}",
  "org_name": "${ORG_NAME}",
  "timezone": "${TIMEZONE}",
  "language": "${LANGUAGE_CODE}",
  "s3_bucket": "${S3_BUCKET}",
  "s3_region": "${S3_REGION}",
  "installed_at": "$(date -u +%FT%TZ)"
}
EOF

  if [[ -n "$S3_BUCKET" ]]; then
    warn "S3 recording storage still needs the one-time UI step — JumpServer Community"
    warn "doesn't expose a stable public API for object-storage backends across versions,"
    warn "so scripting it is more likely to break silently than save you time. Go to:"
    warn "  Settings -> Storage -> Object Storage -> S3"
    warn "  bucket: ${S3_BUCKET}   region: ${S3_REGION}"
    warn "and attach the IAM policy in docs/s3-policy.json to the EC2 instance role."
  fi

  if [[ "$ENABLE_BRANDING_PROXY" == true && -n "$ORG_NAME" ]]; then
    bash "$(dirname "$0")/scripts/branding-proxy.sh" "$ORG_NAME"
  fi

  log "Install complete. UI: http://$(curl -s ifconfig.me 2>/dev/null || echo '<ec2-ip>')"
  log "Org name, timezone, S3 target are all recorded in ${ACCESSRIG_MARKER} for next time."
}

# ---------------------------------------------------------------------------
# Update flow — zero data loss: everything JumpServer needs lives under
# /opt/jumpserver (docker volumes + this bind mount), so upgrading only means
# swapping images, never touching that directory's data files.
# ---------------------------------------------------------------------------
do_update() {
  ensure_jq
  local installed target_tag
  installed=$(jq -r '.installed_version' "$ACCESSRIG_MARKER")
  target_tag="${FORCE_VERSION:-$(latest_upstream_tag)}"

  if [[ "$installed" == "$target_tag" ]]; then
    log "Already on ${installed}. Nothing to do. (pass --version to force a reinstall of the same tag)"
    return
  fi

  log "Upgrading JumpServer ${installed} -> ${target_tag}"

  local backup_file="${BACKUP_DIR}/pre-upgrade-${installed}-to-${target_tag}-$(date +%s).tar.gz"
  log "Backing up ${ACCESSRIG_HOME} (excluding backups/ itself) to ${backup_file}"
  tar --exclude="${BACKUP_DIR}" -czf "$backup_file" -C / opt/jumpserver

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Would run quick_start.sh for ${target_tag} against existing /opt/jumpserver"
    return
  fi

  curl -fsSL "https://github.com/jumpserver/jumpserver/releases/download/${target_tag}/quick_start.sh" \
    -o /tmp/quick_start.sh
  chmod +x /tmp/quick_start.sh

  if ! ( cd "${ACCESSRIG_HOME}" && /tmp/quick_start.sh ); then
    err "Upgrade failed. Data files were not touched (they're separate from images)."
    err "Container state can be restored from: ${backup_file}"
    exit 1
  fi

  jq --arg v "$target_tag" '.installed_version=$v | .updated_at=(now|todate)' \
    "$ACCESSRIG_MARKER" > "${ACCESSRIG_MARKER}.tmp" && mv "${ACCESSRIG_MARKER}.tmp" "$ACCESSRIG_MARKER"

  log "Upgrade complete: now on ${target_tag}. Backup kept at ${backup_file}."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "$MODE" == "install" ]]; then
  do_install
else
  do_update
fi
