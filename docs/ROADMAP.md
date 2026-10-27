# Roadmap

CWP Vault backs up every account on a CWP (Control Web Panel) server to S3-compatible object
storage with [restic](https://restic.net): encrypted, incremental, with retention, integrity checks
and a restore you can trust. Contabo Object Storage is the first-class target; Wasabi, Backblaze B2,
Cloudflare R2, MinIO and AWS S3 also work.

## Why

CWP's built-in "NEW Backup (beta)" is the only S3 option for CWP and users report it failing:
uploads breaking after updates, S3 credentials not saved, restore not listing S3 backups, temp files
filling the root disk, no retention. No open-source alternative exists. CWP Vault fills that gap.

## Design in one screen

- **Engine** (`/usr/local/cwp-vault/`, bash, root, cron). Lives outside CWP so panel updates can't break it.
- **One restic repository per account** (`<prefix>/vault/<account>`) plus `_server` (CWP config, DNS, SSL).
- **Per account:** home files, each database streamed with `mysqldump --single-transaction | restic backup --stdin`
  (no temp files), mail, PostgreSQL if present, and the account record (package, domains, cron, FTP, email).
- **Tuned for Contabo:** path-style, small multipart parts, `s3.connections=2`, upload limit, retry on 429.
- **Retention:** restic `forget --prune` weekly (e.g. 7 daily / 4 weekly / 3 monthly). Never a bucket lifecycle rule.
- **Trust:** weekly `restic check`, monthly automatic test restore, alerts on failure, heartbeat on success.
- **Admin module:** settings (keys write-only), per-account status, back up now, live log, restore.
- **Restore:** account → date → all / files / one DB / one mailbox / one path → original or new account → dry run → run.

## Milestones

| Version | Milestone | Done when |
|---|---|---|
| 0.1.0 | **Stage 0 proof** — restic + Contabo verified on a real server (backup, restore, DB stream, speed, object lock) | Findings in `docs/research/stage0.md` |
| 0.2.0 | **Engine CLI** — `vault backup|restore|check|prune|status|test-storage`, config, cron, alerts | Nightly backups of all accounts succeed for 3 nights |
| 0.3.0 | **Installer** — `install.sh` / `uninstall.sh`, pinned restic with checksum, idempotent, survives CWP update | Clean install + uninstall on a fresh CWP VM |
| 0.4.0 | **Admin module** — settings, status, back up now, live log | Configure and run from CWP without SSH |
| 0.5.0 | **Restore** — CLI + UI: partial restore, restore to new account, dry run | Restore an account to a new name from the UI |
| 0.9.0 | **Hardening** — security review, pen test of module, performance on large accounts, docs | All review findings closed |
| 1.0.0 | **Release** — README with screenshots, docs site, launch | Public announcement |
| 1.x | Customer self-service restore module, object-lock immutable mode, more notifiers | — |

## Open questions (answered in Stage 0)

- Object lock and versioning behaviour on Contabo, and restic on a versioned bucket.
- Real throughput and 429 behaviour under restic against the 10 MB/s / 250 req/s limits.
- CWP account schema (root_cwp tables or API) needed to rebuild an account.
- Mail layout under `/var/vmail` and how to restore a single mailbox.
- Whether a CWP update removes custom admin modules or `include/3rdparty.php`.
- Is an admin `ajax_*.php` reachable without an admin session?
- cwpsrv PHP version and admin UI framework.
