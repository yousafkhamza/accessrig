# AccessRig

By **Yousaf Hamza** ([github.com/yousafkhamza](https://github.com/yousafkhamza)) — repo: [github.com/yousafkhamza/accessrig](https://github.com/yousafkhamza/accessrig)

A one-command installer/updater for [JumpServer](https://github.com/jumpserver/jumpserver) on a fresh Ubuntu/Amazon Linux EC2 box — dependency checks (git, Docker Engine, compose plugin), domain/CSRF config, S3 recording setup guidance, timezone/locale, and safe in-place upgrades, all in one idempotent script.

**All credit for JumpServer itself goes to [Fit2Cloud](https://fit2cloud.com) and the [JumpServer open-source project](https://github.com/jumpserver/jumpserver)** — an open-source Bastion Host / Privileged Access Management (PAM) platform. AccessRig is just a thin, opinionated deployment wrapper around it; it doesn't fork or modify JumpServer's code.

## Always pin `--version`

Every example in this README passes `--version` explicitly. This is deliberate: silently grabbing "latest" means you don't actually know what you're running until after the fact — check what's available first:

```bash
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --list-versions
```

## Why this exists

The official install tooling (`jmsctl.sh`, from JumpServer's own `installer` repo) is solid but leaves a few things manual every time: Docker Engine setup on a fresh box, the `DOMAINS` config that prevents CSRF errors once you're behind a real domain, timezone/locale, and — critically — no single command that safely does install-or-upgrade without you having to know which one applies. AccessRig wraps that into one idempotent script that detects and adapts to what's actually on the box, verified against a live deployment rather than assumed.

**Deliberately minimal.** Earlier versions of this tool included an automatic RDP-audio-bug workaround and a cosmetic org-branding proxy. Both added extra moving parts (sidecar containers, port remapping, nginx layers) that turned out to be more trouble than they were worth in practice — removed entirely. This version only does what JumpServer itself needs to run correctly: install, upgrade, domain/locale config, uninstall.

## Install (fresh EC2 box)

```bash
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- \
  --version "v4.10.18" \
  --domain "jumpserver.google.com" \
  --org-name "google" \
  --s3-bucket "jumpserver-recordings-prod" \
  --s3-region "eu-central-1" \
  --timezone "Asia/Dubai" \
  --language "en"
```

Uses the real, officially-documented install mechanism — downloads the matching release from [`jumpserver/installer`](https://github.com/jumpserver/installer), extracts to a versioned `/opt/jumpserver-installer-v<X.Y.Z>/` directory, and runs `jmsctl.sh install` / `jmsctl.sh start`. Any `(y/n)` confirmation prompt is auto-answered `y` for unattended runs — pass `--interactive` to answer it yourself instead.

**`--domain` matters more than it looks.** It sets `DOMAINS` in JumpServer's shared config, which is what Django's CSRF Origin check trusts. Skip it, and the first time you access JumpServer over HTTPS through a real domain you will very likely hit `CSRF Failed: Origin checking failed`. If you don't pass it, `--interactive` will prompt for it; skipping both prints a clear warning rather than failing silently.

Re-running the **same command** later automatically detects the existing install (by checking whether `jms_core` is actually running, not a bookkeeping file that can drift out of sync) and switches to update mode instead — see below.

## Update (in place, layout-aware)

```bash
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --version "v4.10.18"
```

Detects the real layout on your box (same Docker-label technique used everywhere in this repo) and branches:

- **`jumpserver-installer` layout** (what modern installs use): downloads the target version from `jumpserver/installer`'s releases, extracts it to a fresh versioned directory, runs `jmsctl.sh upgrade` then `jmsctl.sh start`. `jmsctl.sh upgrade` does its own database backup natively to `/data/jumpserver/db_backup/` — AccessRig doesn't duplicate that.
- **Older `quick_start.sh` single-directory layout**: tar-backs-up `/opt/jumpserver` then runs `quick_start.sh` for the target version, for anyone genuinely still on that model.

Domain config (if `--domain` is passed on this run) is applied at the end either way, even when there's nothing to upgrade — safe to re-run any time you need to change it.

## Choosing a specific version

```bash
# See what's available, and what's currently installed on this box
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --list-versions

# Just the currently installed version
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --current-version

# Pin install/update to a specific tag
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --version "v4.10.17"
```

**Downgrading is protected, not blocked.** If the tag you pass to `--version` is *older* than what's currently installed, AccessRig detects that and refuses to proceed unless you also pass `--confirm-downgrade`:

```bash
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- --version "v4.10.15" --confirm-downgrade
```

Why the extra step: a backup is taken either way, so a downgrade is always *recoverable* — but it isn't automatically *safe* the way an upgrade normally is. JumpServer's database schema may have already migrated forward under the newer version, and there's no guarantee older application code works correctly against a newer schema.

## Uninstall

Uses the real `jmsctl.sh down` (the officially documented full-stop command) and correctly identifies the real data locations: `/opt/jumpserver/config` (shared config, secret keys, `DOMAINS`) and `/data/jumpserver` (the actual database/recordings). The versioned `/opt/jumpserver-installer-v*/` directories are closer to release bundles than data — safe to remove regardless.

```bash
# Safe default: stops everything via jmsctl.sh down, leaves config + real data untouched
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

## Repo layout

```
install.sh                          # entrypoint — install or update, auto-detected
uninstall.sh                        # stop/remove, conservative by default
docs/index.html                     # GitHub Pages landing page
.github/workflows/pages.yml         # deploys install.sh/uninstall.sh/docs to GitHub Pages
```

## Enabling GitHub Pages on your fork

1. Push this repo to `github.com/yousafkhamza/accessrig`.
2. Repo → **Settings → Pages → Source → GitHub Actions**.
3. Push to `main` (or run the workflow manually) — `.github/workflows/pages.yml` builds and publishes `install.sh`, `uninstall.sh`, and `docs/index.html` to `https://yousafkhamza.github.io/accessrig/`, which is exactly the URL every command in this README points at.

## License / attribution

AccessRig — © Yousaf Hamza. JumpServer — © Fit2Cloud Inc., used here only as an upstream dependency, unmodified. See [jumpserver/jumpserver](https://github.com/jumpserver/jumpserver) for JumpServer's own license.
