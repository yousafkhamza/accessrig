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
#       --domain "jumpserver.google.com" \
#       --org-name "google" \
#       --s3-bucket "jumpserver-recordings-prod" \
#       --s3-region "eu-central-1" \
#       --timezone "Asia/Dubai" \
#       --language "en"
#
# --domain matters more than it looks: it sets DOMAINS in JumpServer's shared
# config, which is what Django's CSRF Origin check trusts. Skip it and you
# will very likely hit "CSRF Failed: Origin checking failed" the first time
# you access JumpServer over HTTPS through a real domain — this happened for
# real and is why this flag exists.
#
# The GUAC_AUDIO / RDP-black-screen fix is OFF by default, including on a
# fresh install — it adds a sidecar container and moves jms_web's port,
# which isn't something a clean setup should carry unless you actually hit
# the bug. Add --apply-audio-fix if/when RDP sessions show a black screen:
#   curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --apply-audio-fix
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
#                             Also works as a "force upgrade/reinstall" to the
#                             SAME version you're already on — useful to re-run
#                             jmsctl.sh against an existing install.
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
JUMPSERVER_REPO="jumpserver/jumpserver"          # upstream GitHub repo (quick_start.sh releases)
INSTALLER_REPO="jumpserver/installer"            # separate repo: the jmsctl.sh-based installer tool
QUICKSTART_URL_BASE="https://github.com/jumpserver/jumpserver/releases/latest/download"
# Where to fetch sibling scripts (branding-proxy.sh) from when this file is run
# via `curl | bash` — in that mode $0 has no real path, so a local relative
# lookup won't find them. Override with ACCESSRIG_BASE_URL=... if you fork this.
ACCESSRIG_BASE_URL="${ACCESSRIG_BASE_URL:-https://yousafkhamza.github.io/accessrig}"

ORG_NAME=""
DOMAIN=""
S3_BUCKET=""
S3_REGION=""
TIMEZONE="Asia/Dubai"
LANGUAGE_CODE="en"
INTERACTIVE=false
FORCE_VERSION=""     # pin to a specific tag instead of "latest"
LIST_VERSIONS=false
SHOW_CURRENT_VERSION=false
CONFIRM_DOWNGRADE=false
ENABLE_BRANDING_PROXY=false   # opt-in — cosmetic only, most setups don't need it
ENABLE_AUDIO_FIX=false        # opt-in — extra sidecar/port-move, only needed if you actually hit the RDP black-screen bug
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
    --domain)       DOMAIN="$2"; shift 2 ;;
    --s3-bucket)    S3_BUCKET="$2"; shift 2 ;;
    --s3-region)    S3_REGION="$2"; shift 2 ;;
    --timezone)     TIMEZONE="$2"; shift 2 ;;
    --language)     LANGUAGE_CODE="$2"; shift 2 ;;
    --version)      FORCE_VERSION="$2"; shift 2 ;;
    --list-versions) LIST_VERSIONS=true; shift ;;
    --current-version) SHOW_CURRENT_VERSION=true; shift ;;
    --confirm-downgrade) CONFIRM_DOWNGRADE=true; shift ;;
    --enable-branding-proxy) ENABLE_BRANDING_PROXY=true; shift ;;
    --no-branding-proxy) ENABLE_BRANDING_PROXY=false; shift ;;
    --apply-audio-fix) ENABLE_AUDIO_FIX=true; shift ;;
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
if docker inspect jms_core >/dev/null 2>&1; then
  MODE="update"
elif [[ -f "${ACCESSRIG_HOME}/compose.yml" || -f "${ACCESSRIG_HOME}/docker-compose.yml" ]]; then
  # Legacy quick_start.sh layout: no running container yet is still possible
  # right after a stop, but a real compose file on disk is real evidence.
  MODE="update"
fi
if [[ "$LIST_VERSIONS" != true && "$SHOW_CURRENT_VERSION" != true ]]; then
  log "Mode: $MODE"
fi

# ---------------------------------------------------------------------------
# Step 1 — interactive prompts (only if flags weren't passed and it's a fresh install)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "install" && "$LIST_VERSIONS" != true && "$SHOW_CURRENT_VERSION" != true ]]; then
  if [[ -z "$DOMAIN" && "$INTERACTIVE" == true ]]; then
    read -rp "Domain name JumpServer will be reached at (e.g. jumpserver.google.com): " DOMAIN
  fi
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
  if [[ -z "$DOMAIN" ]]; then
    warn "No --domain given (and not running --interactive, so nothing was prompted)."
    warn "Without it, DOMAINS won't be set in JumpServer's config, which is very likely to"
    warn "cause 'CSRF: Origin checking failed' once you access it over HTTPS through a real"
    warn "domain — that's exactly what happened on log-server-eu. Strongly recommend"
    warn "re-running with --domain yourdomain.example, or --interactive to be asked."
  fi
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
  a="${a%-ce}";  b="${b%-ce}"
  a="${a%-ee}";  b="${b%-ee}"
  [[ "$a" == "$b" ]] && return 1
  local lowest
  lowest="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  [[ "$lowest" == "$a" ]]
}

# ---------------------------------------------------------------------------
# Layout detection — JumpServer has shipped two different deployment models:
#   "jumpserver-installer": a VERSIONED directory (/opt/jumpserver-installer-
#     v<X.Y.Z>/ — changes every upgrade), project split across multiple
#     compose files under compose/, managed by that directory's own
#     jmsctl.sh. This is what modern installs actually use.
#   "legacy": the older quick_start.sh model — single /opt/jumpserver
#     directory, one compose file.
# Detected fresh every time via Docker's own compose label — never assumed,
# never cached, since the versioned directory changes on every upgrade.
# ---------------------------------------------------------------------------
LAYOUT=""
REAL_INSTALLER_DIR=""
REAL_ENV_FILE=""
REAL_COMPOSE_ARGS=()
REAL_PROJECT_NAME=""
COMPOSE_FILES=()
CURRENT_VERSION_FROM_DOCKER=""

detect_real_layout() {
  LAYOUT=""
  REAL_INSTALLER_DIR=""
  REAL_ENV_FILE=""
  REAL_COMPOSE_ARGS=()
  COMPOSE_FILES=()
  REAL_PROJECT_NAME=""

  local label_files="" label_project=""
  for probe_container in jms_core jms_web jms_lion; do
    label_files="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$probe_container" 2>/dev/null || true)"
    if [[ -n "$label_files" && "$label_files" != "<no value>" ]]; then
      label_project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$probe_container" 2>/dev/null || true)"
      break
    fi
  done

  if [[ -n "$label_files" && "$label_files" != "<no value>" ]]; then
    mapfile -t _compose_files < <(echo "$label_files" | tr ',' '\n')
    local all_exist=true
    for f in "${_compose_files[@]}"; do
      [[ -f "$f" ]] || { all_exist=false; break; }
    done
    if [[ "$all_exist" == true && ${#_compose_files[@]} -gt 0 ]]; then
      REAL_INSTALLER_DIR="$(dirname "$(dirname "${_compose_files[0]}")")"
      REAL_ENV_FILE="${REAL_INSTALLER_DIR}/.env"
      if [[ -f "$REAL_ENV_FILE" ]]; then
        LAYOUT="jumpserver-installer"
        COMPOSE_FILES=("${_compose_files[@]}")
        # The real Compose project name — critical to get right. Without
        # explicitly passing -p, Compose infers a project name from the
        # basename of the directory holding the FIRST -f file (here,
        # literally "compose/"), which is NOT the project name the live
        # deployment actually uses. Getting this wrong makes every command
        # operate in a different, wrong project namespace — attempting to
        # create a rival network instead of joining the real one, and
        # potentially creating parallel containers instead of updating the
        # real ones. Confirmed this the hard way against a live box.
        if [[ -n "$label_project" && "$label_project" != "<no value>" ]]; then
          REAL_PROJECT_NAME="$label_project"
        fi
        REAL_COMPOSE_ARGS=(--env-file "$REAL_ENV_FILE")
        [[ -n "$REAL_PROJECT_NAME" ]] && REAL_COMPOSE_ARGS+=(-p "$REAL_PROJECT_NAME")
        for f in "${_compose_files[@]}"; do
          REAL_COMPOSE_ARGS+=(-f "$f")
        done
      fi
    fi
  fi

  if [[ -z "$LAYOUT" ]]; then
    if [[ -f "${ACCESSRIG_HOME}/compose.yml" || -f "${ACCESSRIG_HOME}/docker-compose.yml" ]]; then
      LAYOUT="legacy"
    fi
  fi

  # Authoritative current version, straight from the running image tag —
  # more reliable than any marker file, which can drift out of sync (as
  # happened tonight).
  CURRENT_VERSION_FROM_DOCKER="$(docker inspect --format '{{.Config.Image}}' jms_core 2>/dev/null | awk -F: '{print $NF}' || echo "")"
}

# ---------------------------------------------------------------------------
# The GUAC_AUDIO / RDP-black-screen fix, folded in from the standalone
# lion-audio-fix.sh — applied automatically after install/update, and
# idempotent (safe to run every time; skips if already applied). Only runs
# on the jumpserver-installer layout, where the real container names
# (jms_web, jms_lion) and the .env HTTP_PORT mechanism this depends on were
# actually confirmed against a live deployment.
# ---------------------------------------------------------------------------
apply_lion_audio_fix() {
  [[ "$LAYOUT" == "jumpserver-installer" ]] || return 0

  if [[ -z "$REAL_PROJECT_NAME" ]]; then
    warn "Could not determine the real Compose project name for this deployment"
    warn "(the com.docker.compose.project label wasn't found on jms_core). Skipping"
    warn "the GUAC_AUDIO fix rather than guessing — running compose commands with the"
    warn "wrong project name can create a rival network or duplicate containers."
    warn "Check manually with: docker inspect --format '{{ index .Config.Labels \"com.docker.compose.project\" }}' jms_core"
    return 0
  fi

  local fix_dir="${REAL_INSTALLER_DIR}/.accessrig/lion-audio-fix"
  local sidecar_name sidecar_status
  sidecar_name="$(docker ps -a --filter "name=accessrig-lion-audio-fix" --format '{{.Names}}' | head -n1)"
  sidecar_status=""
  [[ -n "$sidecar_name" ]] && sidecar_status="$(docker inspect --format '{{.State.Status}}' "$sidecar_name" 2>/dev/null || echo "")"

  if [[ -f "${fix_dir}/docker-compose.override.yml" && "$sidecar_status" == "running" ]]; then
    log "GUAC_AUDIO fix sidecar is running and healthy for this installer directory — nothing to do."
    return 0
  fi
  if [[ -n "$sidecar_status" && "$sidecar_status" != "running" ]]; then
    warn "The sidecar container (${sidecar_name}) exists but its status is '${sidecar_status}'"
    warn "(not 'running' — possibly crash-looping). Removing it and reapplying cleanly."
    docker rm -f "$sidecar_name" >/dev/null 2>&1 || true
  elif [[ -f "${fix_dir}/docker-compose.override.yml" ]]; then
    warn "Found a fix config file here already, but the sidecar isn't actually running"
    warn "(likely left over from an earlier attempt, e.g. carried across by jmsctl.sh's"
    warn "upgrade migration) — reapplying properly rather than trusting the stale file."
  fi

  log "Applying the GUAC_AUDIO / RDP black-screen fix (audio strip proxy)..."
  mkdir -p "$fix_dir"

  cat > "${fix_dir}/nginx.conf" <<'NGINXEOF'
# Preserve whatever X-Forwarded-Proto the real front door (load balancer /
# TLS terminator) already set, rather than overwriting it with $scheme —
# this sidecar only ever sees plain HTTP internally, so $scheme here is
# always "http" even when the original request was HTTPS. Overwriting it
# unconditionally broke Django's CSRF Origin check (it started believing
# every request was HTTP, causing "does not match any trusted origins").
map $http_x_forwarded_proto $accessrig_forwarded_proto {
    default $http_x_forwarded_proto;
    ''      $scheme;
}

server {
    listen 80;
    # Required because the location below uses variables in proxy_pass
    # ($uri?$args, needed to strip GUAC_AUDIO) — that forces nginx into
    # runtime DNS resolution instead of resolving once at config load, and
    # runtime resolution needs an explicit resolver. 127.0.0.11 is Docker's
    # own embedded DNS server, always present on any container network.
    # Confirmed as the exact cause of "502 / no resolver defined to resolve
    # jms_lion" against a live box.
    resolver 127.0.0.11 valid=30s;
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
        proxy_set_header X-Forwarded-Proto $accessrig_forwarded_proto;
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
        proxy_set_header X-Forwarded-Proto $accessrig_forwarded_proto;
    }
}
NGINXEOF

  # Discover the REAL Docker network the live containers are actually on —
  # referencing the generic "default" alias creates a NEW, separate network
  # under an explicit project name instead of joining the real one, which
  # breaks DNS resolution for jms_web/jms_lion from inside the sidecar
  # (confirmed against a live box: "host not found in upstream jms_web").
  local real_network
  real_network="$(docker inspect jms_web --format '{{range $net, $v := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -n1)"
  if [[ -z "$real_network" ]]; then
    warn "Could not determine the real Docker network jms_web is on — skipping the fix"
    warn "rather than guessing, since the sidecar would just fail to resolve jms_web/jms_lion"
    warn "the same way it just did. Check manually with:"
    warn "  docker inspect jms_web --format '{{json .NetworkSettings.Networks}}'"
    return 0
  fi
  log "Real network: ${real_network} — sidecar will join this one explicitly."

  cat > "${fix_dir}/docker-compose.override.yml" <<EOF
services:
  accessrig-lion-audio-fix:
    image: openresty/openresty:alpine
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ${fix_dir}/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - accessrig_real_net

networks:
  accessrig_real_net:
    external: true
    name: ${real_network}
EOF

  local current_http_port
  current_http_port="$(grep '^HTTP_PORT=' "$REAL_ENV_FILE" | cut -d= -f2 || echo 80)"
  current_http_port="${current_http_port:-80}"
  local alt_port=18080

  # Pick up any OTHER env-like files in the installer directory too — some
  # jumpserver-installer deployments split variables across a second file
  # (commonly named static.env) beyond just .env. docker compose accepts
  # multiple --env-file flags and merges them, so include whatever's there
  # rather than assume .env is the only one — this is also what was causing
  # the "CONFIG_DIR/VERSION/CONFIG_SAFE_FILE not set" warnings.
  local compose_args=()
  local ef
  for ef in "${REAL_INSTALLER_DIR}/.env" "${REAL_INSTALLER_DIR}"/*.env; do
    [[ -f "$ef" ]] && compose_args+=(--env-file "$ef")
  done
  # Critical: pin the project name to what the live deployment actually uses.
  # Without this, Compose infers it from the "compose/" directory basename
  # instead, and every command below operates in a different, wrong project —
  # attempting to create a rival network instead of joining the real one.
  # This was the actual cause of "Pool overlaps with other one on this
  # address space" seen on a live box.
  [[ -n "$REAL_PROJECT_NAME" ]] && compose_args+=(-p "$REAL_PROJECT_NAME")
  for f in "${COMPOSE_FILES[@]}"; do
    compose_args+=(-f "$f")
  done

  # Don't trust .env's declared port — check what jms_web is ACTUALLY bound
  # to right now. A stale/interrupted earlier attempt can leave .env saying
  # one thing while the running container still says another.
  local real_web_port
  real_web_port="$(docker port jms_web 80/tcp 2>/dev/null | head -n1 | awk -F: '{print $NF}')"

  if [[ "$real_web_port" == "$alt_port" ]]; then
    log "jms_web is genuinely already running on ${alt_port} — nothing to recreate."
  else
    if [[ "$current_http_port" != "$alt_port" ]]; then
      log "Moving jms_web off host port 80: HTTP_PORT ${current_http_port} -> ${alt_port}"
      sed -i.accessrig-bak --follow-symlinks "s/^HTTP_PORT=.*/HTTP_PORT=${alt_port}/" "$REAL_ENV_FILE"
    else
      warn "HTTP_PORT in .env already says ${alt_port}, but jms_web is still really on ${real_web_port:-80}"
      warn "(a previous attempt updated the file but never actually recreated the container) —"
      warn "recreating it now to match."
    fi

    # Target the actual web service specifically rather than every service,
    # to minimize what gets touched — discovered by name pattern rather than
    # assumed, since the container name (jms_web) isn't necessarily the same
    # as the compose service key underneath.
    local web_service
    web_service="$(docker compose "${compose_args[@]}" config --services 2>/dev/null | grep -i 'web' | head -n1)"
    if [[ -z "$web_service" ]]; then
      warn "Could not discover the web service name from compose config — recreating everything"
      warn "instead of just the web service. Compose only recreates what actually changed, so"
      warn "already-healthy containers should be left alone regardless."
      docker compose "${compose_args[@]}" up -d
    else
      log "Recreating '${web_service}' service on its new port..."
      docker compose "${compose_args[@]}" up -d "$web_service"
    fi
  fi

  log "Starting the audio-fix sidecar on port 80..."
  docker compose "${compose_args[@]}" -f "${fix_dir}/docker-compose.override.yml" up -d accessrig-lion-audio-fix

  log "GUAC_AUDIO fix applied. RDP connections should no longer black-screen."
}

# ---------------------------------------------------------------------------
# DOMAINS — this is what fixes "CSRF Failed: Origin checking failed", the
# real bug hit on log-server-eu. JumpServer's shared config.txt (symlinked
# as .env into each versioned installer directory) has a DOMAINS variable
# specifically for this — Django's CSRF Origin check trusts whatever's
# listed there. Confirmed from JumpServer's own quick-start documentation.
# Idempotent: only edits + restarts if the value is actually different.
# ---------------------------------------------------------------------------
configure_domain() {
  [[ -n "$DOMAIN" ]] || return 0
  [[ "$LAYOUT" == "jumpserver-installer" ]] || return 0
  [[ -f "$REAL_ENV_FILE" ]] || return 0

  local current_domains
  current_domains="$(grep '^DOMAINS=' "$REAL_ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "")"
  if [[ "$current_domains" == "$DOMAIN" ]]; then
    log "DOMAINS already set to ${DOMAIN} — nothing to do."
    return 0
  fi

  log "Setting DOMAINS=${DOMAIN} (fixes CSRF Origin checking for this domain)..."
  if grep -q '^DOMAINS=' "$REAL_ENV_FILE" 2>/dev/null; then
    sed -i.accessrig-bak --follow-symlinks "s|^DOMAINS=.*|DOMAINS=${DOMAIN}|" "$REAL_ENV_FILE"
  else
    echo "DOMAINS=${DOMAIN}" >> "$REAL_ENV_FILE"
  fi

  restart_jumpserver "DOMAINS change"
}

# ---------------------------------------------------------------------------
# Timezone + language — same shared config file, same idempotent pattern.
# ---------------------------------------------------------------------------
configure_locale() {
  [[ "$LAYOUT" == "jumpserver-installer" ]] || return 0
  [[ -f "$REAL_ENV_FILE" ]] || return 0

  local changed=false
  local current_tz current_lang
  current_tz="$(grep '^TIME_ZONE=' "$REAL_ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "")"
  current_lang="$(grep '^LANGUAGE_CODE=' "$REAL_ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "")"

  if [[ -n "$TIMEZONE" && "$current_tz" != "$TIMEZONE" ]]; then
    log "Setting TIME_ZONE=${TIMEZONE}..."
    if grep -q '^TIME_ZONE=' "$REAL_ENV_FILE" 2>/dev/null; then
      sed -i.accessrig-bak --follow-symlinks "s|^TIME_ZONE=.*|TIME_ZONE=${TIMEZONE}|" "$REAL_ENV_FILE"
    else
      echo "TIME_ZONE=${TIMEZONE}" >> "$REAL_ENV_FILE"
    fi
    changed=true
  fi

  if [[ -n "$LANGUAGE_CODE" && "$current_lang" != "$LANGUAGE_CODE" ]]; then
    log "Setting LANGUAGE_CODE=${LANGUAGE_CODE}..."
    if grep -q '^LANGUAGE_CODE=' "$REAL_ENV_FILE" 2>/dev/null; then
      sed -i.accessrig-bak --follow-symlinks "s|^LANGUAGE_CODE=.*|LANGUAGE_CODE=${LANGUAGE_CODE}|" "$REAL_ENV_FILE"
    else
      echo "LANGUAGE_CODE=${LANGUAGE_CODE}" >> "$REAL_ENV_FILE"
    fi
    changed=true
  fi

  [[ "$changed" == true ]] && restart_jumpserver "timezone/language change"
}

# Shared restart helper — uses jmsctl.sh itself rather than raw docker
# compose, since jmsctl.sh's own commands are confirmed (against a live box,
# earlier tonight) to correctly export variables that our own direct compose
# calls sometimes couldn't resolve (CONFIG_DIR/CONFIG_FILE/etc.).
restart_jumpserver() {
  local reason="${1:-config change}"
  if [[ -f "${REAL_INSTALLER_DIR}/jmsctl.sh" ]]; then
    log "Restarting JumpServer to apply the ${reason} (via jmsctl.sh restart)..."
    ( cd "$REAL_INSTALLER_DIR" && chmod +x ./jmsctl.sh && ./jmsctl.sh restart ) \
      || warn "jmsctl.sh restart failed — apply the ${reason} manually: cd ${REAL_INSTALLER_DIR} && ./jmsctl.sh restart"
  else
    warn "No jmsctl.sh found — restart JumpServer manually to apply the ${reason}."
  fi
}

# ---------------------------------------------------------------------------
# Fresh install flow
# ---------------------------------------------------------------------------
do_install() {
  ensure_git
  ensure_docker
  ensure_jq

  local target_tag="${FORCE_VERSION:-$(latest_upstream_tag)}"
  log "Installing JumpServer ${target_tag} (jumpserver-installer layout)"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Would download jumpserver-installer-${target_tag}.tar.gz, extract to /opt,"
    log "[dry-run] run jmsctl.sh install && jmsctl.sh start, then set DOMAINS/locale/audio-fix."
    return
  fi

  local tarball="jumpserver-installer-${target_tag}.tar.gz"
  local download_url="https://github.com/${INSTALLER_REPO}/releases/download/${target_tag}/${tarball}"
  log "Downloading ${download_url}"
  ( cd /opt && curl -fsSL -O "$download_url" )

  local new_dir="/opt/jumpserver-installer-${target_tag}"
  log "Extracting to ${new_dir}"
  ( cd /opt && tar -zxf "$tarball" )
  [[ -d "$new_dir" ]] || die "Expected ${new_dir} to exist after extracting ${tarball} but it doesn't — check the tarball's actual top-level directory name."

  log "Running jmsctl.sh install..."
  log "NOTE: this may show a (y/n) confirmation prompt — auto-confirming with 'y' for unattended runs."
  log "Re-run with --interactive if you'd rather answer it yourself. This is the first time"
  log "AccessRig has driven a truly fresh jmsctl.sh install (upgrade was verified earlier"
  log "tonight against a live box; a from-scratch install hasn't been separately confirmed"
  log "the same way) — worth watching this run rather than assuming it's silent-safe."
  (
    cd "$new_dir"
    chmod +x ./jmsctl.sh
    if [[ "$INTERACTIVE" == true ]]; then
      ./jmsctl.sh install
    else
      printf 'y\n' | ./jmsctl.sh install
    fi
  ) || die "jmsctl.sh install failed — check the output above. Nothing else was touched."

  log "Starting services..."
  ( cd "$new_dir" && ./jmsctl.sh start ) || die "jmsctl.sh start failed — check container status with: docker ps"

  log "Install complete. Applying domain/locale config and the GUAC_AUDIO fix..."

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

  # Re-detect now that containers actually exist, then apply everything else.
  detect_real_layout
  configure_domain
  configure_locale
  if [[ "$ENABLE_AUDIO_FIX" == true ]]; then
    apply_lion_audio_fix
  else
    log "Skipping the GUAC_AUDIO/RDP-black-screen fix (opt-in, off by default for a clean"
    log "fresh setup — it adds a sidecar container and moves jms_web's port). If RDP"
    log "sessions show a black screen later, re-run with --apply-audio-fix."
  fi

  log "Install complete."
  if [[ -n "$DOMAIN" ]]; then
    log "UI: https://${DOMAIN}  (assuming TLS termination is set up in front of this box)"
  else
    log "UI: http://$(curl -s ifconfig.me 2>/dev/null || echo '<ec2-ip>')"
    warn "No --domain was set — if you access this over HTTPS through a real domain later,"
    warn "re-run with --domain to avoid the CSRF Origin-checking error."
  fi
}

# ---------------------------------------------------------------------------
# Update flow — branches on the REAL detected layout rather than assuming.
# jumpserver-installer layout uses the tool's own jmsctl.sh upgrade/start
# (which does its own DB backup natively — verified from JumpServer's own
# docs, no need to duplicate it). Legacy layout keeps the original
# quick_start.sh-based flow. Either way, the GUAC_AUDIO fix is applied
# automatically at the end — including when there's nothing to upgrade, so
# boxes that installed via AccessRig before this fix existed get it just by
# re-running this script.
# ---------------------------------------------------------------------------
do_update() {
  ensure_jq
  detect_real_layout

  if [[ "$LAYOUT" == "jumpserver-installer" ]]; then
    do_update_jumpserver_installer
  elif [[ "$LAYOUT" == "legacy" ]]; then
    do_update_legacy
  else
    die "Could not detect a JumpServer deployment on this box (checked for jumpserver-installer and legacy quick_start.sh layouts). If containers are running under different names, this detection needs adjusting."
  fi

  # Re-detect: an installer-layout upgrade just moved to a NEW versioned
  # directory, so REAL_INSTALLER_DIR from before the upgrade is stale.
  # configure_locale is intentionally NOT called here — it would silently
  # reapply the default timezone/language on every update run even if you'd
  # since changed it via the UI, since those flags default to non-empty
  # values. configure_domain is safe here since it only acts when --domain
  # is explicitly passed on this specific run.
  detect_real_layout
  configure_domain
  if [[ "$ENABLE_AUDIO_FIX" == true ]]; then
    apply_lion_audio_fix
  fi
}

do_update_jumpserver_installer() {
  local installed target_tag
  installed="${CURRENT_VERSION_FROM_DOCKER:-unknown}"
  target_tag="${FORCE_VERSION:-$(latest_upstream_tag)}"

  if [[ "$installed" != "unknown" ]] && ! version_lt "$installed" "$target_tag" && ! version_lt "$target_tag" "$installed"; then
    log "Already on ${installed}. Nothing to upgrade — checking the GUAC_AUDIO fix is applied and stopping there."
    return
  fi

  if version_lt "$target_tag" "$installed"; then
    warn "Target version ${target_tag} is OLDER than the currently installed ${installed} — this is a DOWNGRADE."
    warn "jmsctl.sh takes its own DB backup before migrating, so this is recoverable, but downgrading"
    warn "a stateful, DB-backed app isn't automatically safe the way upgrading normally is."
    if [[ "$CONFIRM_DOWNGRADE" != true ]]; then
      die "Re-run with --confirm-downgrade added to proceed anyway, once you've read the warning above."
    fi
    warn "Proceeding with downgrade (--confirm-downgrade was passed)."
  fi

  local verb="Upgrading"
  version_lt "$target_tag" "$installed" && verb="Downgrading"
  log "${verb} JumpServer ${installed} -> ${target_tag} (jumpserver-installer layout)"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Would download jumpserver-installer-${target_tag}.tar.gz, extract to /opt, run jmsctl.sh upgrade && jmsctl.sh start"
    return
  fi

  local tarball="jumpserver-installer-${target_tag}.tar.gz"
  local download_url="https://github.com/${INSTALLER_REPO}/releases/download/${target_tag}/${tarball}"
  log "Downloading ${download_url}"
  ( cd /opt && curl -fsSL -O "$download_url" )

  local new_dir="/opt/jumpserver-installer-${target_tag}"
  log "Extracting to ${new_dir}"
  ( cd /opt && tar -zxf "$tarball" )
  [[ -d "$new_dir" ]] || die "Expected ${new_dir} to exist after extracting ${tarball} but it doesn't — check the tarball's actual top-level directory name."

  log "Running jmsctl.sh upgrade (this includes jmsctl's own DB backup to /data/jumpserver/db_backup/)..."
  log "NOTE: this may show a (y/n) confirmation prompt — auto-confirming with 'y' for unattended runs."
  log "Re-run with --interactive if you'd rather answer it yourself."
  (
    cd "$new_dir"
    chmod +x ./jmsctl.sh
    if [[ "$INTERACTIVE" == true ]]; then
      ./jmsctl.sh upgrade
    else
      printf 'y\n' | ./jmsctl.sh upgrade
    fi
  ) || die "jmsctl.sh upgrade failed. Your previous version's directory and data are untouched — check the output above."

  log "Starting services on the new version..."
  ( cd "$new_dir" && ./jmsctl.sh start ) || die "jmsctl.sh start failed after upgrade — check container status with: docker ps"

  log "Upgrade complete: now on ${target_tag}."
}

# ---------------------------------------------------------------------------
# Legacy (older quick_start.sh, single /opt/jumpserver directory) update path
# — kept for boxes that genuinely still use this layout.
# ---------------------------------------------------------------------------
do_update_legacy() {
  local installed target_tag
  installed=$(jq -r '.installed_version // empty' "$ACCESSRIG_MARKER" 2>/dev/null || echo "")
  installed="${installed:-$CURRENT_VERSION_FROM_DOCKER}"
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
  log "${verb} JumpServer ${installed} -> ${target_tag} (legacy layout)"

  local backup_file="${BACKUP_DIR}/pre-upgrade-${installed}-to-${target_tag}-$(date +%s).tar.gz"
  log "Backing up ${ACCESSRIG_HOME} (excluding backups/ itself) to ${backup_file}"
  tar --exclude="opt/jumpserver/backups" -czf "$backup_file" -C / opt/jumpserver

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
if [[ "$SHOW_CURRENT_VERSION" == true ]]; then
  detect_real_layout
  if [[ -n "$CURRENT_VERSION_FROM_DOCKER" ]]; then
    echo "$CURRENT_VERSION_FROM_DOCKER"
  else
    echo "Not installed (or jms_core isn't running) on this box." >&2
    exit 1
  fi
  exit 0
fi

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
