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
# Version management:
#   --list-versions          List recent upstream releases (marks which one, if
#                             any, is currently installed on this box), then exit.
#   --version <tag>           Pin install/update to a specific tag instead of
#                             always grabbing "latest" (e.g. --version v4.10.17).
#   --confirm-downgrade       Required in addition to --version when the target
#                             tag is OLDER than what's currently installed — a
#                             backup is still taken either way, but downgrading
#                             a stateful, DB-backed app isn't automatically safe
#                             the way upgrading normally is, so it's opt-in.
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
# Where to fetch sibling scripts (branding-proxy.sh) from when this file is run
# via `curl | bash` — in that mode $0 has no real path, so a local relative
# lookup won't find them. Override with ACCESSRIG_BASE_URL=... if you fork this.
ACCESSRIG_BASE_URL="${ACCESSRIG_BASE_URL:-https://yousafkhamza.github.io/accessrig}"

ORG_NAME=""
S3_BUCKET=""
S3_REGION=""
TIMEZONE="Asia/Dubai"
LANGUAGE_CODE="en"
INTERACTIVE=false
FORCE_VERSION=""     # pin to a specific tag instead of "latest"
LIST_VERSIONS=false
CONFIRM_DOWNGRADE=false
ENABLE_BRANDING_PROXY=false   # opt-in — cosmetic only, most setups don't need it
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
# OS detection — Debian/Ubuntu (apt) vs. RHEL-family (dnf/yum), which covers
# Amazon Linux 2023, RHEL, CentOS, Rocky, Alma. Detected once, used everywhere.
# Defined before any call site, since this script also runs via `curl | bash`
# (streamed execution — a call before its definition would fail there).
# ---------------------------------------------------------------------------
OS_ID=""
OS_ID_LIKE=""
PKG_FAMILY=""   # "debian" | "rhel"
PKG_MGR=""      # "apt" | "dnf" | "yum"

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-}"
    OS_ID_LIKE="${ID_LIKE:-}"
  fi

  if [[ "$OS_ID" =~ ^(ubuntu|debian)$ ]] || [[ "$OS_ID_LIKE" == *debian* ]]; then
    PKG_FAMILY="debian"
    PKG_MGR="apt"
  elif [[ "$OS_ID" =~ ^(amzn|rhel|centos|rocky|almalinux|fedora)$ ]] || [[ "$OS_ID_LIKE" == *fedora* || "$OS_ID_LIKE" == *"rhel"* ]]; then
    PKG_FAMILY="rhel"
    PKG_MGR="dnf"
    command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"
  else
    die "Unrecognized OS ($OS_ID). This script supports Debian/Ubuntu (apt) and RHEL-family / Amazon Linux (dnf/yum) only."
  fi
  log "Detected OS: ${OS_ID:-unknown} -> package family: ${PKG_FAMILY} (${PKG_MGR})"
}

pkg_install() {
  case "$PKG_MGR" in
    apt) apt-get update -y && apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
  esac
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
    --list-versions) LIST_VERSIONS=true; shift ;;
    --confirm-downgrade) CONFIRM_DOWNGRADE=true; shift ;;
    --enable-branding-proxy) ENABLE_BRANDING_PROXY=true; shift ;;
    --no-branding-proxy) ENABLE_BRANDING_PROXY=false; shift ;;
    --interactive)  INTERACTIVE=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

require_root
detect_os

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
  pkg_install git
}

ensure_docker_debian() {
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
}

ensure_docker_amzn() {
  # Amazon Linux 2023 ships Docker directly in its own repos — the upstream
  # Docker CE repo doesn't officially support AL2023, so we use dnf's build
  # and add the Compose plugin separately (AL2023 doesn't package it).
  dnf install -y docker
  systemctl enable docker
  systemctl start docker

  local compose_dir="/usr/libexec/docker/cli-plugins"
  mkdir -p "$compose_dir"
  if [[ ! -x "${compose_dir}/docker-compose" ]]; then
    local arch; arch="$(uname -m)"
    [[ "$arch" == "aarch64" ]] && arch="aarch64" || arch="x86_64"
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
      -o "${compose_dir}/docker-compose"
    chmod +x "${compose_dir}/docker-compose"
  fi
}

ensure_docker_rhel() {
  # RHEL / CentOS / Rocky / Alma / Fedora — official Docker CE repo.
  local repo_family="rhel"
  [[ "$OS_ID" == "fedora" ]] && repo_family="fedora"

  pkg_install dnf-plugins-core yum-utils 2>/dev/null || true
  if command -v dnf >/dev/null 2>&1; then
    dnf config-manager --add-repo "https://download.docker.com/linux/${repo_family}/docker-ce.repo"
  else
    yum-config-manager --add-repo "https://download.docker.com/linux/${repo_family}/docker-ce.repo"
  fi
  pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker + compose plugin already present ($(docker --version))"
    return
  fi

  log "Installing Docker Engine + compose plugin (${PKG_FAMILY})..."
  case "$PKG_FAMILY" in
    debian)
      ensure_docker_debian
      ;;
    rhel)
      if [[ "$OS_ID" == "amzn" ]]; then
        ensure_docker_amzn
      else
        ensure_docker_rhel
      fi
      ;;
  esac

  systemctl enable docker
  systemctl start docker

  # Grant the box's default cloud-init user docker access, whichever it is.
  for candidate_user in ec2-user ubuntu admin centos rocky; do
    if id "$candidate_user" >/dev/null 2>&1; then
      usermod -aG docker "$candidate_user" || true
    fi
  done
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 || pkg_install jq
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

# List the last ~30 upstream releases, marking which (if any) is currently
# installed on this box, so you can deliberately pin to a specific stable
# tag instead of always trusting "latest" — some recent tags on any project
# can have regressions, and you may want to sit on a known-good version.
list_versions() {
  local installed=""
  if [[ -f "$ACCESSRIG_MARKER" ]]; then
    installed="$(jq -r '.installed_version // empty' "$ACCESSRIG_MARKER" 2>/dev/null || echo "")"
  fi

  log "Currently installed on this box: ${installed:-none — fresh box}"
  log "Fetching recent JumpServer releases from GitHub..."
  echo ""
  # NOTE column shows the release NAME (e.g. "v4.10.18-lts") when it differs
  # from the TAG (e.g. "v4.10.18") — GitHub keeps these as two separate
  # fields: tag_name is what --version actually pins to and what the
  # download URL uses, name is the human-readable title shown on the
  # releases page (usually the one with "-lts" in it). Use the TAG value
  # with --version, not the NAME.
  printf "%-16s %-20s %-14s %s\n" "TAG" "RELEASE NAME" "PUBLISHED" "NOTE"
  curl -fsSL "https://api.github.com/repos/${JUMPSERVER_REPO}/releases?per_page=30" \
    | jq -r '.[] | [.tag_name, (.name // .tag_name), (.published_at // "" | split("T")[0]), (.prerelease | tostring)] | @tsv' \
    | while IFS=$'\t' read -r tag rel_name published prerelease; do
        note=""
        [[ "$prerelease" == "true" ]] && note="pre-release"
        if [[ -n "$installed" && "$tag" == "$installed" ]]; then
          note="${note:+$note, }CURRENTLY INSTALLED"
        fi
        printf "%-16s %-20s %-14s %s\n" "$tag" "$rel_name" "$published" "$note"
      done
  echo ""
  log "Install/pin a specific one with: --version <tag>   — use the TAG column, e.g. --version v4.10.17"
}

# Compares two version tags (handles v-prefix and -lts suffix). Returns
# success (0) if $1 is strictly older than $2 — used to detect a downgrade
# and require explicit confirmation before proceeding, since a backup makes
# a downgrade RECOVERABLE but doesn't make it automatically safe: JumpServer's
# DB schema may already have migrated forward and isn't guaranteed to work
# against an older release's code.
version_lt() {
  local a="${1#v}" b="${2#v}"
  a="${a%-lts}"; b="${b%-lts}"
  [[ "$a" == "$b" ]] && return 1
  local lowest
  lowest="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  [[ "$lowest" == "$a" ]]
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
    local local_script="$(dirname "$0")/scripts/branding-proxy.sh"
    if [[ -f "$local_script" ]]; then
      bash "$local_script" "$ORG_NAME"
    else
      # We were run via curl | bash, so $0 has no usable path — fetch the sibling script instead.
      if curl -fsSL "${ACCESSRIG_BASE_URL}/scripts/branding-proxy.sh" -o /tmp/branding-proxy.sh; then
        bash /tmp/branding-proxy.sh "$ORG_NAME"
      else
        warn "Could not fetch branding-proxy.sh from ${ACCESSRIG_BASE_URL} — skipping cosmetic branding (install itself is unaffected)."
      fi
    fi
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

  if version_lt "$target_tag" "$installed"; then
    warn "Target version ${target_tag} is OLDER than the currently installed ${installed} — this is a DOWNGRADE."
    warn "A backup will still be taken first, so this is recoverable, but it is not automatically"
    warn "safe: JumpServer's database schema may have already migrated forward with ${installed}"
    warn "and isn't guaranteed to work correctly against ${target_tag}'s older code."
    if [[ "$CONFIRM_DOWNGRADE" != true ]]; then
      die "Re-run with --confirm-downgrade added to proceed anyway, once you've read the warning above."
    fi
    warn "Proceeding with downgrade (--confirm-downgrade was passed)."
  fi

  local verb="Upgrading"
  version_lt "$target_tag" "$installed" && verb="Downgrading"
  log "${verb} JumpServer ${installed} -> ${target_tag}"

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
if [[ "$LIST_VERSIONS" == true ]]; then
  ensure_jq
  list_versions
  exit 0
fi

if [[ "$MODE" == "install" ]]; then
  do_install
else
  do_update
fi
