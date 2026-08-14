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

## Update (in place, zero data loss)

```bash
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash
```

What "zero data loss" actually means here: JumpServer's MySQL/Redis data and your config live under `/opt/jumpserver`, which is a bind mount on the host, not inside a container. Upgrading only replaces container images — it never deletes that directory. AccessRig additionally tars the whole directory to `/opt/jumpserver/backups/` before every upgrade attempt, so a failed upgrade has a one-command rollback path.

### Full upgrade runbook (v4.10.17 → latest, accounting for lion-audio-fix)

If you've applied `lion-audio-fix.sh`, remove it **before** upgrading — it changed `jms_nginx`'s port mapping, and you don't want a stale sidecar fighting the upgrade for port 80:

```bash
# 1. Check what's currently installed and what's newer
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --list-versions

# 1b. Check whether lion-audio-fix is currently applied on this box
docker ps --filter name=accessrig-lion-audio-fix --format '{{.Names}}: {{.Status}}'
# empty output = not applied, skip straight to step 3

# 2. If step 1b showed it running, remove it first
#    (run it from wherever you keep your AccessRig checkout on this server)
sudo ./scripts/lion-audio-fix.sh --remove

# 3. Do the actual upgrade — no version pin needed to just take the latest
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash

# 4. Test the RDP connection that was showing a black screen.
#    v4.10.18 may or may not have fixed the underlying Lion bug — there's no
#    changelog line confirming it either way, so this is a real test, not
#    a formality.

# 5. Only if it's STILL black-screening after the upgrade, reapply the fix:
sudo ./lion-audio-fix.sh
```

This order matters: skipping step 2 means the port-80 sidecar container is still bound when `quick_start.sh` (called internally by the upgrade) tries to bring `jms_nginx` back up on its normal port — that's a conflict you'd rather avoid than debug.

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

## Fixing the RDP black-screen bug (GUAC_AUDIO)

If RDP connections through JumpServer show a black screen and Lion's logs contain:

```
5.audio,1.1,31.audio/L16; instruction with bad Content: 5.audio,1.1,31.audio/L16
```

This is a known upstream bug (matches [jumpserver/jumpserver#13156](https://github.com/jumpserver/jumpserver/issues/13156) and [#13799](https://github.com/jumpserver/jumpserver/issues/13799)) — Luna's client-side JS always appends `GUAC_AUDIO=audio/L8&GUAC_AUDIO=audio/L16` to every RDP connect request, and Lion's protocol parser chokes on it. There's no platform-level toggle for this; it isn't configurable from the JumpServer UI.

```bash
sudo ./scripts/lion-audio-fix.sh              # apply
sudo ./scripts/lion-audio-fix.sh --remove     # remove (e.g. before upgrading JumpServer — see the upgrade runbook above)
```

This is a separate, single-purpose script from `branding-proxy.sh` — it strips only `GUAC_AUDIO` from requests to `/lion/ws/connect/` using an OpenResty (nginx + Lua) sidecar, and passes every other path through completely unmodified.

### Compose layout: this auto-detects correctly for BOTH installer types

JumpServer has shipped two different deployment layouts depending on version/installer:

- **Older `quick_start.sh`**: single directory, one compose file — `/opt/jumpserver/compose.yml` (or `docker-compose.yml`).
- **Newer `jumpserver-installer` tool**: a **versioned** directory (`/opt/jumpserver-installer-v<X.Y.Z>/` — this path *changes on every upgrade*), with the project split across nine separate compose files under `compose/`: `network.yml`, `core.yml`, `celery.yml`, `koko.yml`, `lion.yml`, `chen.yml`, `web.yml`, `redis.yml`, `postgres.yml`.

`lion-audio-fix.sh` doesn't guess which one you're on or assume a fixed path — it asks Docker directly, which always knows exactly which file(s) created each container:

```bash
docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' jms_core
```

Whatever that returns (one file or nine, comma-separated), the script detects all of them and passes **every single one** via `-f` on every `docker compose` call it makes — passing only a subset would make Compose think the missing services aren't part of the project anymore, which risks it treating already-running containers as orphaned. This was tested against the real 9-file output format before shipping, not just the simple single-file case.

If auto-detection ever fails, override it explicitly:

```bash
sudo ./scripts/lion-audio-fix.sh --compose-files "/path/a.yml,/path/b.yml,/path/c.yml"
```

**Finding the port-80 mapping**: with 9 files instead of 1, the script doesn't guess which file has the port mapping either — it prints a `grep -l` command that finds the exact file for you:

```bash
grep -l '80:80' /opt/jumpserver-installer-v4.10.15/compose/*.yml
```

The Lua removal logic and the surrounding nginx config were both verified independently before shipping this: the query-string logic was tested against the literal request URL captured from a real browser DevTools session, confirming both `GUAC_AUDIO` values are removed while every other parameter (including `TOKEN_ID`) survives; the nginx config was validated with `nginx -t` down to a clean pass.

If you also ran `branding-proxy.sh` earlier, remove it first — you don't want two proxies both trying to bind port 80.

### ⚠️ Worth checking if you're on the jumpserver-installer layout

`install.sh`/`uninstall.sh` in this repo still assume the older `/opt/jumpserver` single-directory layout for backups and data (`ACCESSRIG_HOME="/opt/jumpserver"`). If your box uses the versioned `jumpserver-installer` layout instead (check with the `docker inspect` command above), **the backup step in `install.sh`'s update flow may have been backing up the wrong directory** — worth confirming before you trust it for anything important:

```bash
# Compare what's actually in each — if /opt/jumpserver is nearly empty while
# the real data (postgres volumes, config, recordings) is under the versioned
# installer directory, the backup path needs fixing before your next upgrade.
ls -la /opt/jumpserver 2>/dev/null
ls -la /opt/jumpserver-installer-v*/  2>/dev/null
```

I haven't fixed this in `install.sh`/`uninstall.sh` yet — flagging it here rather than silently leaving a gap, since it affects the "zero data loss" guarantee those scripts claim. If your box turns out to be on this layout, say so and I'll rework the backup/data-path detection to match the same Docker-label approach used here.

## Enabling GitHub Pages on your fork

1. Push this repo to `github.com/yousafkhamza/accessrig`.
2. Repo → **Settings → Pages → Source → GitHub Actions**.
3. Push to `main` (or run the workflow manually) — `.github/workflows/pages.yml` builds `docs/` and publishes it to `https://yousafkhamza.github.io/accessrig/`, which is exactly the URL the `curl` one-liner above points at.

## License / attribution

AccessRig — © Yousaf Hamza. JumpServer — © Fit2Cloud Inc., used here only as an upstream dependency, unmodified. See [jumpserver/jumpserver](https://github.com/jumpserver/jumpserver) for JumpServer's own license.
