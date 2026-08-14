# AccessRig

By **Yousaf Hamza** ([github.com/yousafkhamza](https://github.com/yousafkhamza)) — repo: [github.com/yousafkhamza/accessrig](https://github.com/yousafkhamza/accessrig)

A one-command installer/updater for [JumpServer](https://github.com/jumpserver/jumpserver) on a fresh Ubuntu EC2 box — dependency checks (git, Docker Engine, compose plugin), S3 recording setup guidance, org-name branding, timezone/locale, and safe in-place upgrades that never touch your data.

**All credit for JumpServer itself goes to [Fit2Cloud](https://fit2cloud.com) and the [JumpServer open-source project](https://github.com/jumpserver/jumpserver)** — an open-source Bastion Host / Privileged Access Management (PAM) platform. AccessRig is just a thin, opinionated deployment wrapper around it; it doesn't fork or modify JumpServer's code.

## Why this exists

The official quick-start is great but leaves a few things manual every time: Docker Engine + compose-plugin setup on a fresh box, forcing English UI, timezone, S3 recording storage, and — critically — there's no single blessed way to safely re-run it later as an *upgrade* without a checklist. AccessRig wraps all of that into one idempotent script.

## Install (fresh EC2 box)

```bash
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- \
  --org-name "Google" \
  --s3-bucket "jumpserver-recordings-prod" \
  --s3-region "eu-central-1" \
  --timezone "Asia/Dubai" \
  --language "en"
```

Re-running the **same command** later automatically detects the existing install (via `/opt/jumpserver/.accessrig/install.json`) and switches to update mode instead — see below.

## Update (in place, layout-aware, GUAC_AUDIO fix applied automatically)

```bash
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash
```

**This section was rewritten from scratch after finding out the hard way that `install.sh`'s original update flow (based on `quick_start.sh`) doesn't match how modern JumpServer actually deploys.** The real layout, confirmed against a live box:

- A **versioned** installer directory — `/opt/jumpserver-installer-v<X.Y.Z>/` — that changes on every upgrade, containing 9 separate compose files under `compose/`, an `.env` file, and its own `jmsctl.sh` management script.
- Real upgrades go through **`jmsctl.sh upgrade` && `jmsctl.sh start`**, which does its own database backup natively to `/data/jumpserver/db_backup/` — this is the tool's own correct mechanism, confirmed from JumpServer's own documentation, not something AccessRig needs to duplicate.

`install.sh` now detects this automatically (same Docker-label technique used everywhere else in this repo) and branches:

- **`jumpserver-installer` layout** (what you're almost certainly on): downloads the new version from `jumpserver/installer`'s releases, extracts it to a fresh versioned directory, runs `jmsctl.sh upgrade` then `jmsctl.sh start`. Any `(y/n)` confirmation prompt is auto-answered `y` for unattended runs (pass `--interactive` to answer it yourself instead).
- **Older `quick_start.sh` single-directory layout**: keeps the original tar-backup-then-`quick_start.sh` flow, for anyone genuinely still on that model. The backup step also had a real bug fixed here — the `--exclude` pattern was an absolute path being matched against tar's relative internal paths under `-C`, so it never actually excluded the backups directory, causing "file changed as we read it" and endlessly growing backup files. Fixed to match correctly (verified with a real `tar` run, not just eyeballed).

**The GUAC_AUDIO / RDP black-screen fix is now applied automatically** — after every install, after every upgrade, and even when there's *nothing* to upgrade. That last case matters most if you installed via AccessRig before this fix existed: just re-run the same command with no flags, and it'll detect the fix isn't applied yet and apply it, without needing to separately remember `lion-audio-fix.sh` exists. It's idempotent either way — safe to run repeatedly, skips instantly once applied.

The standalone `scripts/lion-audio-fix.sh` still exists for ad-hoc use (e.g. `--remove` before some other maintenance), but you shouldn't need to reach for it manually anymore as part of a normal install/upgrade.

All of this — layout detection, the `jmsctl.sh` flow, the pipefail bug in auto-confirming the prompt (`yes | cmd` fails under `set -o pipefail` once the reader stops early; switched to `printf 'y\n' | cmd`), and the automatic audio-fix application including the "already on latest" case — was tested end-to-end against a simulated environment built from real command output before shipping, not just read over and assumed correct.

## Choosing a specific version instead of always "latest"

```bash
# See what's available, and what's currently installed on this box
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --list-versions

# Pin install/update to a specific tag
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --version v4.10.17
```

`--list-versions` fetches the last ~30 upstream releases straight from GitHub, marks pre-releases, and clearly flags whichever one is currently installed on this box — so you can deliberately sit on a known-good tag instead of blindly trusting "latest" (which can occasionally regress on any project).

**Downgrading is protected, not blocked.** If the tag you pass to `--version` is *older* than what's currently installed, AccessRig detects that and refuses to proceed unless you also pass `--confirm-downgrade`:

```bash
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --version v4.10.15 --confirm-downgrade
```

Why the extra step: a backup is taken either way (same as any update), so a downgrade is always *recoverable* — but it isn't automatically *safe* the way an upgrade normally is. JumpServer's database schema may have already migrated forward under the newer version, and there's no guarantee older application code works correctly against a newer schema. The confirmation flag exists so a downgrade only ever happens because you meant it to, not because a script silently picked an older tag for you.

## Uninstall

```bash
# Safe default: stops containers, leaves /opt/jumpserver (your data) untouched
curl -fsSL https://yousafkhamza.github.io/accessrig/uninstall.sh | sudo bash

# Fully remove everything, including data — takes a final backup to
# /root/accessrig-final-backup-<timestamp>.tar.gz first, then asks you to
# type DELETE to confirm
curl -fsSL https://yousafkhamza.github.io/accessrig/uninstall.sh | sudo bash -s -- --purge-data

# Also uninstall Docker Engine itself (off by default — other things on the
# box may depend on it)
curl -fsSL https://yousafkhamza.github.io/accessrig/uninstall.sh | sudo bash -s -- --purge-data --remove-docker
```

Data is never deleted by default — you have to explicitly opt in with `--purge-data`, and it still confirms before doing anything destructive unless you also pass `--yes`.

## What gets automated vs. what's still manual

| Item | Automated | Notes |
|---|---|---|
| Docker + compose plugin | ✅ | Idempotent — skips if already installed |
| git | ✅ | |
| Language / timezone | ✅ | Written to `config.yml` before first boot |
| Version check + upgrade | ✅ | Compares installed tag vs. latest GitHub release |
| Pre-upgrade backup | ✅ | tarball under `/opt/jumpserver/backups/` |
| Org name in UI | ⚠️ partial | See below — Community edition has no official white-label API |
| S3 recording storage | ❌ manual (one-time) | See below |

### Why org branding and S3 aren't fully automated

Digging into JumpServer's docs before writing this: **logo/title/theme customization ("Appearance") is an Enterprise Edition–only feature** — Community edition has no supported UI or public API to change it. `scripts/branding-proxy.sh` gets you the cosmetic effect anyway via an nginx sidecar that text-substitutes "JumpServer" → your org name in outgoing HTML (`sub_filter`), which survives upgrades since it never touches JumpServer's own containers. It's **off by default** — most setups don't need it — pass `--enable-branding-proxy` if you want it.

S3 storage backend configuration also has no stable public API across Community versions, so scripting it would be more likely to silently break on a version bump than save you time. The script prints the exact `Settings → Storage → Object Storage → S3` steps and the IAM policy (`docs/s3-policy.json`) to attach to the instance role.

## ⚠️ Security note

JumpServer published advisory **JS-2026.7.29** covering four CVEs (Fastjson deserialization, a KoKo SFTP path-traversal, an Applet Host Jinja template-injection RCE, and an org-invitation permission override), affecting **V3 < v3.10.22 LTS** and **V4 < v4.10.17 LTS**. If your current install predates that, run the update flow above before anything else.

## Repo layout

```
install.sh                          # entrypoint — install or update, auto-detected
scripts/branding-proxy.sh           # optional org-name cosmetic proxy (off by default)
scripts/lion-audio-fix.sh           # fixes the RDP black-screen / GUAC_AUDIO bug
docs/s3-policy.json                 # IAM policy for the recordings bucket
docs/index.html                     # GitHub Pages landing page
config/accessrig.env.example
.github/workflows/pages.yml         # deploys docs/ to GitHub Pages on every push to main
```

Server user provisioning (create `admin-pam`/`editor-pam`/`readonly-pam` via SSM) lives in a separate toolkit, not this repo — see [jms-user-provisioning](https://github.com/yousafkhamza/jms-user-provisioning).

## The RDP black-screen bug (GUAC_AUDIO) — now fixed automatically

**As of the install.sh rewrite above, you don't need to do anything for this anymore** — it's applied automatically after install, after upgrade, and even on a plain re-run with nothing to upgrade. This section is background on what it does and how, plus the standalone script for ad-hoc use.

If RDP connections through JumpServer show a black screen and Lion's logs contain:

```
5.audio,1.1,31.audio/L16; instruction with bad Content: 5.audio,1.1,31.audio/L16
```

This is a known upstream bug (matches [jumpserver/jumpserver#13156](https://github.com/jumpserver/jumpserver/issues/13156) and [#13799](https://github.com/jumpserver/jumpserver/issues/13799)) — Luna's client-side JS always appends `GUAC_AUDIO=audio/L8&GUAC_AUDIO=audio/L16` to every RDP connect request, and Lion's protocol parser chokes on it. There's no platform-level toggle for this; it isn't configurable from the JumpServer UI.

**Standalone script**, for cases outside the normal install/upgrade flow (e.g. removing it temporarily for unrelated maintenance):

```bash
sudo ./scripts/lion-audio-fix.sh                    # apply manually
sudo ./scripts/lion-audio-fix.sh --remove           # remove
sudo ./scripts/lion-audio-fix.sh --alt-port 18080   # customize the port jms_web moves to (default 18080)
```

This is a separate, single-purpose script from `branding-proxy.sh` — it strips only `GUAC_AUDIO` from requests to `/lion/ws/connect/` using an OpenResty (nginx + Lua) sidecar, and passes every other path through completely unmodified. The exact same logic is folded directly into `install.sh` now, so both stay in sync by construction rather than by remembering to update two files.

### Real container layout (confirmed against a live jumpserver-installer deployment)

Earlier versions of this script assumed a container named `jms_nginx` — that container doesn't exist on the `jumpserver-installer` layout. Confirmed via `docker ps` against a real box:

| Container | Role |
|---|---|
| `jms_web` | The actual reverse proxy, published on the host at `HTTP_PORT` (default 80). This is what the sidecar needs to take over port 80 from. |
| `jms_lion` | Exposes port `8081` on the internal Docker network only (not published to the host) — this is Lion's own embedded server, and the actual target for the GUAC_AUDIO strip. |

The fix proxies `/lion/ws/connect/` directly to `jms_lion:8081` (after stripping `GUAC_AUDIO`), and everything else to `jms_web:80` — its container-internal port, which stays 80 regardless of whatever the host-side `HTTP_PORT` is remapped to.

### Port handling is fully automated via `.env`, not raw compose editing

The `jumpserver-installer` layout's `.env` file has an `HTTP_PORT` variable specifically for this situation — its own comment says *"if it conflicts with the existing service, please modify it yourself"*. Since this is a single well-defined `KEY=VALUE` line rather than arbitrary YAML structure, `lion-audio-fix.sh` edits it directly and safely:

```bash
sed -i.accessrig-bak "s/^HTTP_PORT=.*/HTTP_PORT=${ALT_PORT}/" "$ENV_FILE"
```

A backup of the original `.env` is written alongside it (`.env.accessrig-bak`) before any edit. `--remove` reverts the value back to `80` and recreates `jms_web` on it. No manual file editing is required for either apply or remove — this was tested end-to-end (apply, verify the diff, then remove, verify it reverts byte-for-byte apart from the one line) before shipping.

### Compose layout: multi-file, versioned directory

The `jumpserver-installer` tool deploys to a **versioned** directory (`/opt/jumpserver-installer-v<X.Y.Z>/` — this path *changes on every upgrade*), with the project split across nine separate compose files under `compose/`: `network.yml`, `core.yml`, `celery.yml`, `koko.yml`, `lion.yml`, `chen.yml`, `web.yml`, `redis.yml`, `postgres.yml`. `lion-audio-fix.sh` doesn't guess or assume a fixed path — it asks Docker directly:

```bash
docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' jms_core
```

Whatever that returns, the script detects all of them and passes **every single one** via `-f` on every `docker compose` call — passing only a subset would make Compose think the missing services left the project, which risks it treating already-running containers as orphaned. Tested against the real 9-file output format, not just a simplified single-file case.

If auto-detection ever fails:

```bash
sudo ./scripts/lion-audio-fix.sh --compose-files "/path/a.yml,/path/b.yml,/path/c.yml"
```

If you also ran `branding-proxy.sh` earlier, remove it first — you don't want two proxies both trying to bind port 80. Note: `branding-proxy.sh` still has the old `jms_nginx` assumption baked in and hasn't been corrected the same way — treat it as unverified against the `jumpserver-installer` layout until it has been.

### ⚠️ `uninstall.sh` is still on the old assumption — `install.sh` is fixed

`install.sh` now correctly detects and handles both layouts (see the "Update" section above — this was the whole point of tonight's rewrite). `uninstall.sh` has **not** been updated the same way yet — it still assumes the older single-directory `/opt/jumpserver` layout for backups and data removal. If you're on the `jumpserver-installer` layout and need to uninstall, don't trust `uninstall.sh`'s `--purge-data` yet; verify what it would actually delete first, or ask for it to be fixed the same way before relying on it.

```bash
# Compare what's actually in each — if /opt/jumpserver is nearly empty while
# the real data (postgres volumes, config, recordings) is under the versioned
# installer directory, uninstall.sh's --purge-data is deleting the wrong thing.
ls -la /opt/jumpserver 2>/dev/null
ls -la /opt/jumpserver-installer-v*/  2>/dev/null
```

## Enabling GitHub Pages on your fork

1. Push this repo to `github.com/yousafkhamza/accessrig`.
2. Repo → **Settings → Pages → Source → GitHub Actions**.
3. Push to `main` (or run the workflow manually) — `.github/workflows/pages.yml` builds `docs/` and publishes it to `https://yousafkhamza.github.io/accessrig/`, which is exactly the URL the `curl` one-liner above points at.

## License / attribution

AccessRig — © Yousaf Hamza. JumpServer — © Fit2Cloud Inc., used here only as an upstream dependency, unmodified. See [jumpserver/jumpserver](https://github.com/jumpserver/jumpserver) for JumpServer's own license.
