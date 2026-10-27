# CWP Vault

Encrypted, incremental, S3-compatible backups for CWP (Control Web Panel) servers, built on [restic](https://restic.net).

[![CI](https://github.com/riyajkm/cwp-vault/actions/workflows/ci.yml/badge.svg)](https://github.com/riyajkm/cwp-vault/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/riyajkm/cwp-vault?include_prereleases)](https://github.com/riyajkm/cwp-vault/releases)

> **Status: early development (pre-0.1) — not ready for production.**

## Why

CWP's built-in "NEW Backup (beta)" is the only S3 option for CWP, and users report it failing: uploads
breaking after updates, S3 credentials not saved, restore not listing S3 backups, temp files filling the
root disk, and no retention. No open-source alternative exists. CWP Vault fills that gap.

## Planned features

- One restic repository per account, plus one for server config (CWP config, DNS, SSL).
- Home files, databases (streamed with `mysqldump --single-transaction`, no temp files), mail, PostgreSQL, and the account record.
- Retention with `restic forget --prune` (for example 7 daily / 4 weekly / 3 monthly).
- Weekly integrity check, monthly automatic test restore, failure alerts, success heartbeat.
- Engine CLI: `vault backup|restore|check|prune|status|test-storage`, driven by cron.
- Installer that survives CWP updates (pinned restic, checksum verified).
- CWP admin module: settings, per-account status, back up now, live log, restore.
- Restore: whole account, files, one database, one mailbox or one path, to the original or a new account, with dry run.

## Supported storage

Contabo Object Storage first. Also planned: Wasabi, Backblaze B2, Cloudflare R2, MinIO, AWS S3.

## Install

Coming in v0.3.0.

## Docs

- [Roadmap](docs/ROADMAP.md)
- [Workflow](docs/WORKFLOW.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Code of conduct](CODE_OF_CONDUCT.md)

## License

[MIT](LICENSE)
