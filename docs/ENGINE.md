# Engine specification (v0.2.0)

The engine is a bash program run as root. It owns every backup, restore, check and prune. The CWP
module (later) only calls it. Target: bash ≥ 4.4 on AlmaLinux/Rocky 8–9, restic ≥ 0.17.

## Layout on the server

```
/usr/local/cwp-vault/
  bin/vault                 # entry point (symlinked to /usr/local/bin/vault by the installer)
  lib/*.sh                  # sourced modules (no side effects on source)
  etc/vault.conf            # settings, 0640 root (no secrets)
  etc/secrets.env           # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, RESTIC_PASSWORD — 0600 root
  var/status/<name>.json    # last result per account and for _server
  var/log/vault.log         # timestamped log, rotated by logrotate (installer)
  var/lock/vault.lock       # flock
  var/cache/                # RESTIC_CACHE_DIR
```

All paths come from `VAULT_HOME` (default `/usr/local/cwp-vault`) so tests can point it at a temp dir.

## Config (`etc/vault.conf`, shell `KEY=value`, parsed — never `source`d)

| Key | Default | Meaning |
|---|---|---|
| `S3_ENDPOINT` | — (required) | e.g. `https://eu2.contabostorage.com` (host only, no bucket) |
| `S3_BUCKET` | — (required) | bucket name |
| `S3_PREFIX` | `` | e.g. `server1/` |
| `ACCOUNTS` | `all` | `all` or space-separated usernames |
| `EXCLUDE_ACCOUNTS` | `` | usernames to skip |
| `EXCLUDES` | see below | extra glob patterns for home backups |
| `BACKUP_MAIL` / `BACKUP_DATABASES` / `BACKUP_SERVER` | `yes` | toggles |
| `S3_CONNECTIONS` | `4` | `-o s3.connections=` |
| `LIMIT_UPLOAD_KIB` | `0` | `--limit-upload` (0 = off) |
| `KEEP_DAILY` / `KEEP_WEEKLY` / `KEEP_MONTHLY` | `7` / `4` / `3` | retention |
| `CHECK_SUBSET` | `5%` | `restic check --read-data-subset` |
| `ALERT_EMAIL` | `` | failure mail (via `sendmail -t`) |
| `ALERT_WEBHOOK` | `` | POST JSON on failure |
| `HEARTBEAT_URL` | `` | healthchecks-style: `/start`, success, `/fail` |
| `RETRIES` | `3` | retries for a failed restic call, backoff 30 s, 120 s, 300 s |
| `IMMUTABLE` | `no` | `yes` turns on immutable (object lock) mode; see "Immutable mode" below |
| `LOCK_MODE` | `COMPLIANCE` | `COMPLIANCE` or `GOVERNANCE`; must equal the bucket's default retention mode |
| `LOCK_DAYS` | `14` | 1-3650; the bucket's default retention must be at least this many days |

Unknown keys → warning. Values are validated (bucket/endpoint/prefix charset, numbers, yes/no).
Default excludes: `*/cache/*`, `*/.cache/*`, `*/tmp/*`, `*/.trash/*`, `*/error_log`, `*/core.[0-9]*`.

## Repositories

`s3:${S3_ENDPOINT}/${S3_BUCKET}/${S3_PREFIX}vault/<account>` — one per account.
`…/vault/_server` — server-wide data. Same `RESTIC_PASSWORD` for all (one secret to keep safe).

## Account discovery

- Accounts: `SELECT username FROM root_cwp.user`, then `ACCOUNTS` / `EXCLUDE_ACCOUNTS` filters.
- Usernames must match `^[a-z][a-z0-9_]{0,31}$`; anything else is skipped with a warning.
- Domains: `user.domain` + `domains.domain WHERE user=?` + `subdomains`.
- Databases: `SHOW DATABASES LIKE '<user>\_%'` (CWP's naming rule).
- Mail dirs: `/var/vmail/<domain>` for each of the account's domains that exists.
- All SQL uses the root client defaults (`/root/.my.cnf`); usernames are validated before use in SQL.

## What one account backup contains (one snapshot per run, tag `account`)

1. `/home/<user>` (with `--one-file-system`, excludes).
2. `/var/vmail/<domain>/` for each domain (if `BACKUP_MAIL=yes`).
3. Each database, **streamed**: `mysqldump --single-transaction --quick --routines --events --triggers --hex-blob <db> | restic backup --stdin --stdin-filename db/<db>.sql --tag db,<account>` — one snapshot per DB. `set -o pipefail`; a dump error fails that DB.
4. `account.json` streamed the same way (`--stdin-filename meta/account.json --tag meta`): rows from `root_cwp.user`, `domains`, `subdomains`, package row, and `postfix` mailbox/alias/domain rows for its domains.

Files 1+2 go in one `restic backup` call (tag `files`). Each run records all snapshot IDs in the status file.

## `_server` backup (if `BACKUP_SERVER=yes`)

Files: `/var/named/*.db`, `/etc/pki/tls/certs`, `/etc/pki/tls/private`, `/usr/local/cwp/.conf`,
`/etc/postfix`, `/etc/dovecot`. Streams: full `root_cwp` and `postfix` DB dumps.

## Commands

```
vault init                       # create missing repos (accounts + _server); idempotent
vault backup [--account U|--all] [--dry-run]
vault restore --account U [--snapshot ID|latest] --what files|db|mail|meta [--path P] [--db NAME]
              [--target DIR | --target-db NAME] [--dry-run]
vault snapshots --account U      # list (JSON with --json)
vault prune [--account U|--all]  # forget --keep-* --prune
vault check [--account U|--all]  # check --read-data-subset
vault unlock [--account U|--all] # restic unlock (stale locks only)
vault recover (--account U|--all) [--before ISO8601] [--yes] [--json]   # immutable mode only
vault status [--json]            # summary of var/status/*.json
vault test-storage               # write → read → delete a probe snapshot in _server; reports timing
vault version
```

Restore in v0.2 is CLI-only and **never writes over live data by default**: files restore to
`--target` (required, must not be `/` or under `/home/<user>` unless `--in-place` is given);
databases restore into `--target-db` (required; refuses an existing non-empty DB unless `--force`).

## Behaviour

- One run at a time: `flock -n var/lock/vault.lock`, else exit 3.
- Before each account: `restic unlock` (removes only stale locks).
- Every restic call: `-o s3.connections=$S3_CONNECTIONS`, `--limit-upload` if set, retries per `RETRIES`.
- `AWS_REQUEST_CHECKSUM_CALCULATION` / `AWS_RESPONSE_CHECKSUM_VALIDATION` are not needed (restic uses minio-go).
- One failing account never stops the others.
- Status JSON per account: `{account, started, finished, duration_s, result: ok|failed|skipped, snapshots:[…], files_new, files_changed, bytes_added, error}`.
- Exit codes: `0` all ok, `1` some accounts failed, `2` config/usage error, `3` already running, `4` storage unreachable.
- Logs: `YYYY-MM-DDTHH:MM:SSZ LEVEL message`. Secrets never logged; restic output is filtered.
- Alerts on exit ≠ 0: email + webhook with the summary; heartbeat `/start` at begin, success or `/fail` at end.

## Cron (`contrib/cron.d/cwp-vault`, installed in v0.3)

```
30 1 * * *  root /usr/local/bin/vault backup --all
0  4 * * 0  root /usr/local/bin/vault prune --all
0  4 * * 3  root /usr/local/bin/vault check --all
```

## Admin module ↔ engine contract

The CWP admin module (PHP, runs as root under cwpsrv) talks to the engine **only** by running
`/usr/local/bin/vault` with `proc_open()` and an **argument array** (no shell), from a fixed verb allowlist.
Every read command supports `--json` and prints one JSON document to stdout; errors print
`{"error":"…","code":N}` with the matching exit code.

| Command | JSON output |
|---|---|
| `vault status --json` | `{"version":"x.y.z","configured":bool,"accounts":[{"account","result","started","finished","duration_s","bytes_added","snapshots":n,"error"}],"server":{…same…},"running":[{"account","command","pid","started"}]}` |
| `vault snapshots --account U --json` | `[{"id","short_id","time","tags":[],"paths":[],"kind":"files|db|meta","db":null|"name","size":n|null}]` |
| `vault ls --account U --snapshot ID [--path P] --json` | one directory level: `[{"name","type":"dir|file|symlink","size","mtime","path"}]` |
| `vault config get --json` | all non-secret keys with current values |
| `vault config set KEY=VALUE …` | validates every pair first, then writes `vault.conf` atomically; `{"ok":true,"changed":[…]}` |
| `vault secrets set` | reads `KEY=VALUE` lines from **stdin** (never argv): `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `RESTIC_PASSWORD` (refused if repos already exist with another password) |
| `vault secrets status --json` | `{"s3_key_set":bool,"access_key_hint":"…abcd","password_set":bool}` — never the values |
| `vault log --tail N [--json]` | last N log lines (secrets already filtered) |
| `vault test-storage --json` | `{"ok":bool,"write_ms","read_ms","delete_ms","error"}` |
| `vault restore … --json` | `{"ok","job","target","files","bytes","duration_s","error"}`; also written to `var/status/restore-<job>.json` |

Long-running verbs (`backup`, `restore`, `prune`, `check`) are started by the module detached:
`setsid -f /usr/local/bin/vault <verb> … --quiet`; the module then polls `status --json` / `log --tail`.

## Immutable mode (v0.3)

Design and test results: `docs/research/immutable.md`. Needs the `aws` CLI v2 and `python3` on the server
(restic cannot read bucket settings). Exit 2 with a clear message when either is missing.

- `vault init` with `IMMUTABLE=yes` first runs `aws s3api get-object-lock-configuration`; it refuses (exit 2)
  unless `ObjectLockEnabled=Enabled`, the default retention mode equals `LOCK_MODE` and its days are at least
  `LOCK_DAYS`. It then merges the lifecycle rule `cwp-vault-noncurrent` (`NoncurrentVersionExpiration` of
  `LOCK_DAYS + 7` days, prefix `${S3_PREFIX}vault/`) into the bucket's rules: other rules are kept, only our own
  ID is replaced, and nothing is written when it is already there.
- `vault recover` lists the delete markers under each account repository prefix (those newer than `--before`).
  It is a dry run unless `--yes`, which deletes each marker by version id, then runs `restic unlock --remove-all`
  and `restic check` per repository. It refuses unless `IMMUTABLE=yes`, holds the global exclusive lock and appends
  a line to `var/log/audit.log`. A marker that cannot be removed stops that account and skips its check.
  JSON: `{"ok":bool,"accounts":[{"account","delete_markers","removed","check":"ok|failed|skipped"}],"error":"…"}`.
  It deletes one marker per `aws` call; a wipe of a very large repository takes a while.
- `vault status --json` has a top-level `"immutable":{"enabled":bool,"mode":"…","days":N}`.

## Security rules (from the v0.2 threat review)

What v0.2 protects against: disk loss, accidental deletion, a compromised customer account,
a bad update. It does **not** protect against root on this host deleting backups — that needs the
no-delete key / object-lock mode planned for v0.3 (object lock verified working on Contabo in Stage 0).

**Input validation (one function each, used by every command):**
- account `^[a-z][a-z0-9_]{0,31}$`; database `^<account>_[A-Za-z0-9_]{1,56}$` (must belong to the account);
  domain: hostname regex (`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`) before
  building any `/var/vmail/<domain>` path; restore path: absolute, no `..`, no newline, restic glob chars escaped,
  passed only as `--include` after option parsing.
- Config parser rejects values containing `$(`, backticks, newlines or NUL; caps value length at 1024.
  `ALERT_EMAIL` must be a single plain address (no newline, comma or header text); mail built with fixed headers.
- `S3_ENDPOINT`, `ALERT_WEBHOOK`, `HEARTBEAT_URL` must be `https://` (`ALLOW_INSECURE=yes` overrides the endpoint only).

**Restore safety:**
- Default target: a fresh `0700` root dir `/var/lib/cwp-vault/restore/<timestamp>-<account>`. A user-given
  `--target` must not exist or be empty, is resolved with `realpath`, and is refused if any path component is a
  symlink or it lies under `/home`, `/etc`, `/root`, `/usr`, `/var/lib/mysql` or `/`. `--in-place` is not in v0.2.
- After a files restore: strip setuid/setgid (`chmod -R ug-s`) in the target.
- DB restore: into `--target-db` that must not exist (created by the engine); dumps are piped through a filter that
  removes `DEFINER=` clauses.
- Every restore appends one line to `var/log/audit.log` (time, account, snapshot, what, path/db, target).

**Secrets and files:** entry point sets `umask 077`; `var/` is `0750 root:root`, files `0640`; secrets passed to
children only via environment, never on a command line; restic and mysqldump command lines are never logged.
`meta/account.json` holds no password hashes; postfix mailbox/alias rows go to a separate `meta/mailauth.json`
(admin-only). Webhook payload: counts and failed account names only; `error` text capped at 300 chars with paths
scrubbed. curl uses `--max-time 20 --proto =https` and no redirects.

**Reliability:** per-account lock `var/lock/<account>.lock`; global lock only for `prune`/`check`/`unlock`;
`restic unlock` runs only when no other `vault` process is alive. Every restic call is wrapped in `timeout`
(`ACCOUNT_TIMEOUT`, default `6h`). Abort if free space on the cache or restore filesystem is below `MIN_FREE_GB`
(default `5`). A DB whose dump or upload failed is recorded as failed and its snapshot (if one was created) is
forgotten. MyISAM tables are not consistent under `--single-transaction`; documented, `--lock-tables` used when a
database has MyISAM tables.

**Password safety:** `vault verify-secrets` confirms every repo opens with the current password. The install guide
tells the admin to store the restic password offline — losing it makes all backups unreadable.

Deferred (tracked): no-delete cron key + object-lock immutable mode (v0.3), per-repo restic keys (v0.3),
GPG-verified restic download (v0.3 installer), PHP↔engine job-queue contract (v0.4), deleted-account repo
retention (v0.3), customer restore isolation (v1.x).

## Code rules

- `set -Eeuo pipefail`, `IFS=$'\n\t'`; quote everything; arrays for command arguments; no `eval`.
- shellcheck clean (no disables without a comment why).
- Every external command goes through a small wrapper so tests can stub `restic`, `mysql`, `mysqldump` via `PATH`.
- Functions in `lib/` are pure where possible and unit-tested with bats.
