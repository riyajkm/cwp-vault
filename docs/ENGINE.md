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

## Code rules

- `set -Eeuo pipefail`, `IFS=$'\n\t'`; quote everything; arrays for command arguments; no `eval`.
- shellcheck clean (no disables without a comment why).
- Every external command goes through a small wrapper so tests can stub `restic`, `mysql`, `mysqldump` via `PATH`.
- Functions in `lib/` are pure where possible and unit-tested with bats.
