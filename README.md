# CWP Vault

Encrypted, incremental, S3-compatible backups for CWP (Control Web Panel) servers, built on [restic](https://restic.net).

[![CI](https://github.com/riyajkm/cwp-vault/actions/workflows/ci.yml/badge.svg)](https://github.com/riyajkm/cwp-vault/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/riyajkm/cwp-vault?include_prereleases)](https://github.com/riyajkm/cwp-vault/releases)

> **Status: v0.2.0 — early release.** Backup and restore are verified on a production CWP server
> (AlmaLinux 8, Contabo Object Storage). Test a restore on your own server before relying on it.

## Why

CWP's built-in "NEW Backup (beta)" is the only S3 option for CWP, and users report it failing: uploads
breaking after updates, S3 credentials not saved, restore not listing S3 backups, temp files filling the
root disk, and no retention. No open-source alternative exists. CWP Vault fills that gap.

## Features (v0.2.0)

- One encrypted, incremental restic repository per account, plus one for server config (DNS, SSL, CWP config).
- Home files, mail, and databases **streamed** into the backup (`mysqldump --single-transaction`, no temp files), plus the account record.
- Retention with `restic forget --prune` (default 7 daily / 4 weekly / 3 monthly) and weekly integrity checks.
- Failure alerts by email or webhook, plus a heartbeat URL (healthchecks.io style).
- CWP admin page: first-run wizard, per-account status, back up now, file browser restore, single-database restore, settings with write-only keys, live log.
- Safe restores: never into live data by default, symlink-proof targets, setuid stripped, every restore audit-logged.
- `vault` CLI for everything, with JSON output.

Planned: object-lock (ransomware-proof) mode, restore into a live account, customer self-service restore, more notifiers.

## Supported storage

Tested: Contabo Object Storage. Should work with any S3-compatible storage (Wasabi, Backblaze B2,
Cloudflare R2, MinIO, AWS S3) — reports welcome.

## Install

```bash
git clone https://github.com/riyajkm/cwp-vault.git
cd cwp-vault
sudo ./install.sh --dry-run   # see what it will do
sudo ./install.sh
```

Then open **CWP → CWP Vault** and follow the setup wizard. Full guide: [docs/INSTALL.md](docs/INSTALL.md).

> Store the backup password the wizard shows you **offline**. Without it, nobody can read your backups.

## Docs

- [Roadmap](docs/ROADMAP.md)
- [Workflow](docs/WORKFLOW.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Code of conduct](CODE_OF_CONDUCT.md)

## License

[MIT](LICENSE)
