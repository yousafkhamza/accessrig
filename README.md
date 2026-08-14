# AccessRig

By **Yousaf Hamza** ([github.com/yousafkhamza](https://github.com/yousafkhamza)) — repo: [github.com/yousafkhamza/accessrig](https://github.com/yousafkhamza/accessrig)

A one-command installer/updater for [JumpServer](https://github.com/jumpserver/jumpserver) on a fresh Ubuntu EC2 box — dependency checks (git, Docker Engine, compose plugin), S3 recording setup guidance, org-name branding, timezone/locale, and safe in-place upgrades that never touch your data.

**All credit for JumpServer itself goes to [Fit2Cloud](https://fit2cloud.com) and the [JumpServer open-source project](https://github.com/jumpserver/jumpserver)** — an open-source Bastion Host / Privileged Access Management (PAM) platform. AccessRig is just a thin, opinionated deployment wrapper around it; it doesn't fork or modify JumpServer's code.

## Why this exists

The official quick-start is great but leaves a few things manual every time: Docker Engine + compose-plugin setup on a fresh box, forcing English UI, timezone, S3 recording storage, and — critically — there's no single blessed way to safely re-run it later as an *upgrade* without a checklist. AccessRig wraps all of that into one idempotent script.

## Install (fresh EC2 box)

```bash
curl -fsSL https://yousafkhamza.github.io/accessrig/install.sh | sudo bash -s -- \
  --org-name "Pay10" \
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

Digging into JumpServer's docs before writing this: **logo/title/theme customization ("Appearance") is an Enterprise Edition–only feature** — Community edition has no supported UI or public API to change it. `scripts/branding-proxy.sh` gets you the cosmetic effect anyway via an nginx sidecar that text-substitutes "JumpServer" → your org name in outgoing HTML (`sub_filter`), which survives upgrades since it never touches JumpServer's own containers. It's clearly optional and off with `--no-branding-proxy`.

S3 storage backend configuration also has no stable public API across Community versions, so scripting it would be more likely to silently break on a version bump than save you time. The script prints the exact `Settings → Storage → Object Storage → S3` steps and the IAM policy (`docs/s3-policy.json`) to attach to the instance role.

## ⚠️ Security note

JumpServer published advisory **JS-2026.7.29** covering four CVEs (Fastjson deserialization, a KoKo SFTP path-traversal, an Applet Host Jinja template-injection RCE, and an org-invitation permission override), affecting **V3 < v3.10.22 LTS** and **V4 < v4.10.17 LTS**. If your current install predates that, run the update flow above before anything else.

## Repo layout

```
install.sh                          # entrypoint — install or update, auto-detected
scripts/branding-proxy.sh           # optional org-name cosmetic proxy
docs/s3-policy.json                 # IAM policy for the recordings bucket
docs/index.html                     # GitHub Pages landing page
config/accessrig.env.example
.github/workflows/pages.yml         # deploys docs/ to GitHub Pages on every push to main
```

## Enabling GitHub Pages on your fork

1. Push this repo to `github.com/yousafkhamza/accessrig`.
2. Repo → **Settings → Pages → Source → GitHub Actions**.
3. Push to `main` (or run the workflow manually) — `.github/workflows/pages.yml` builds `docs/` and publishes it to `https://yousafkhamza.github.io/accessrig/`, which is exactly the URL the `curl` one-liner above points at.

## License / attribution

AccessRig — © Yousaf Hamza. JumpServer — © Fit2Cloud Inc., used here only as an upstream dependency, unmodified. See [jumpserver/jumpserver](https://github.com/jumpserver/jumpserver) for JumpServer's own license.
