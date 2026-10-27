# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Installer: restic `SHA256SUMS` is verified with gpg against the pinned release key fingerprint (temporary 0700
  GNUPGHOME) on top of the pinned per-arch SHA-256; missing gpg warns, `--strict` fails.
- Installer: `--upgrade` (engine, module, missing cron lines merged without touching existing lines or the backup
  line's state; prints old -> new; refuses downgrades without `--force`; version kept in
  `/usr/local/cwp-vault/VERSION`) and `--check` (read-only health report, non-zero on problems).
- Monthly `vault verify-restore --quiet` cron line in the shipped cron file; `tests/installer.bats`.

- Immutable mode (S3 object lock): config keys `IMMUTABLE`, `LOCK_MODE`, `LOCK_DAYS`; `vault init` refuses a bucket
  without a matching default retention and merges a `cwp-vault-noncurrent` lifecycle rule; needs the `aws` CLI v2.
- `vault recover (--account U | --all) [--before TIME] [--yes]`: removes the delete markers left by a wipe, then
  unlocks and checks each repository. Dry run by default.
- `vault status --json` reports `immutable`; admin module shows an "Immutable (MODE, N days)" badge and an
  "Immutable backups" settings group.
- Docs: "Immutable backups" in `docs/INSTALL.md` (Contabo steps and recovery), engine spec section.

## [0.2.0] - 2026-10-28

### Added

- Engine (`vault` CLI): per-account restic repositories on S3-compatible storage; backup of home files,
  mail, streamed databases (no temp files, `DEFINER` stripped) and account metadata; safe restore of
  files, single databases, mail and metadata; prune, check, unlock, status, snapshots, ls, test-storage,
  verify-secrets; config and secrets management; email/webhook/heartbeat alerts; JSON output for the
  admin module. See `docs/ENGINE.md`.
- CWP admin module: dashboard, restore browser and wizard, settings with write-only keys, live log,
  first-run setup wizard; native CWP (Bootstrap 3) look.
- `install.sh` / `uninstall.sh`: pinned, checksum-verified restic; module and menu install that keeps
  CWP's own locks intact; daily self-heal of the menu after CWP updates; cron and logrotate.
- 150 bats tests for the engine; `docs/INSTALL.md`.

### Security

- Input validation for accounts, databases, domains and restore paths; restores never write into live
  data; setuid/setgid stripped after restore; audit log of every restore; secrets only via stdin and
  root-only files; admin module requires a CWP admin session and a CSRF token.

### Fixed

- Concurrent `vault init` no longer corrupts a repository (found on the reference server).

## [0.1.0] - 2026-10-27

### Added

- Stage 0 findings: restic 0.19 on Contabo Object Storage verified on a real CWP server (backup,
  incremental, restore with 0 differences, database streaming, object lock, lifecycle rules) —
  see `docs/research/stage0.md`.
- Project roadmap and workflow documents.
- Repository scaffolding: license, contributing guide, security policy, issue and PR templates, CI.

[Unreleased]: https://github.com/riyajkm/cwp-vault/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/riyajkm/cwp-vault/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/riyajkm/cwp-vault/releases/tag/v0.1.0
