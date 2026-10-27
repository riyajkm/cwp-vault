# Stage 0 — proof on a real CWP server

Goal: prove the design (restic → S3-compatible storage, Contabo first) on a production CWP server
before writing engine code. Run on 2026-10-27. Server details are anonymised.

## Environment

| Item | Value |
|---|---|
| OS / panel | AlmaLinux 8.10, CWP Pro, MariaDB 10.11 |
| Hardware | 4 vCPU, 10 GB RAM, 57 GB free disk |
| cwpsrv PHP | 8.3 (installed under the folder name `php71`) |
| Storage | Contabo Object Storage, Asia region, path-style endpoint |
| restic | 0.19.1 (official release, SHA256 verified) |
| Accounts | 6, home sizes 0.9–9.1 GB |

## Results

| Test | Result |
|---|---|
| Init repo on Contabo | OK |
| First backup, 0.9 GB / 23,349 files | 313 MB stored (compressed), **43 s** (~7 MB/s) |
| Second backup, nothing changed | **7 s** |
| Full restore to a temp folder | 45 s, **0 differences** (`diff -rq`), owners and modes preserved |
| `restic check` | no errors |
| DB stream: `mysqldump --single-transaction … \| restic backup --stdin` | 75 InnoDB tables (18.7 MB) in **8 s**, no temp file, pipe exit 0 0 |
| DB restore: `restic dump … \| mysql <throwaway>` | 144 s; row counts match except a live WordPress `options` table (+2 rows written after the dump — expected on a live site) |
| Object lock (separate test bucket) | Bucket with object lock created, versioning auto-enabled, GOVERNANCE 1-day default retention applied, **deleting a locked version → `AccessDenied: forbidden by object lock`**, governance bypass works for cleanup |
| Bucket lifecycle rule | Supported (put + get) |

## Findings → design decisions

1. **restic on Contabo works** end to end (init, backup, incremental, restore, check). Keep restic as the engine.
2. **Throughput** ~7 MB/s with restic defaults, under Contabo's 10 MB/s cap. A first full backup of
   ~25 GB takes roughly an hour; nightly incrementals take minutes. Default `s3.connections` is fine for
   now; add `--limit-upload` as a setting and retry/backoff for 429s.
3. **DB streaming works** with no temp files — solves CWP's "backups fill the disk" problem.
   DB *restore* is the slow part (import time), so restore of one DB must be offered on its own.
4. **Immutable backups are possible on Contabo** (object lock + versioning). Plan an optional
   "immutable mode" (GOVERNANCE or COMPLIANCE retention) after 1.0; restic's own `forget --prune`
   must then respect retention windows. Default stays non-locked.
5. **Lifecycle rules are supported, but must never target a restic repo** (they would delete pack
   files restic still references). Retention stays inside restic.
6. **Restore preserves ownership** — no chown step needed for home files.
7. **WordPress live tables drift** between dump and check; the automatic test-restore must compare the
   restored DB to the *dump*, not to the live DB.

## CWP internals (read-only look)

- `root_cwp` tables: `backups domains nameserver notifications packages settings subdomains user`.
  - `user`: `username domain ip_address email setup_date package backup reseller …`
  - `domains`: `domain user path`; `subdomains`: `subdomain domain user path`
  - `packages`: quotas and limits per package
- Mail: `/var/vmail/<domain>/<mailbox>`; mail accounts in the `postfix` database.
- DNS zones: `/var/named/*.db`. SSL: `/etc/pki/tls/certs`.
- The account record to back up = `user` row + its `domains`/`subdomains` rows + package name +
  `postfix` rows for its domains + zone files + certs.

## Still open

- Does a CWP update remove custom admin modules or `include/3rdparty.php`? (check after next CWP update)
- Is an admin `ajax_*.php` reachable without a session? (test on a throwaway CWP VM)
- Memory use while backing up the largest account (~9 GB) — measure in v0.2.0.
- Restic lock objects becoming unreadable on Contabo (one public report) — add stale-lock handling.
