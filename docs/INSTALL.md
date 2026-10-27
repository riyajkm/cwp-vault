# Installing CWP Vault

> **Store your restic password offline.** Put it in a password manager and keep a printed copy somewhere
> safe, away from this server. Backups are encrypted with it; if it is lost, every backup is unreadable
> and nobody, including the project, can recover them.

## Requirements

- AlmaLinux, Rocky Linux or CentOS 8 or 9 with Control Web Panel (CWP) installed. Other systems: `--force`
  continues, unsupported.
- Root access.
- `curl`, `bzip2`, `sha256sum`, `mysql`, `mysqldump`, `flock`, `setsid`, `timeout` (all standard on CWP servers).
- An S3-compatible bucket (endpoint, bucket name, access key and secret key).
- restic 0.17.0 or newer. If it is missing or older, the installer downloads a pinned version
  (0.19.1, x86_64 or aarch64), checks the signature on restic's `SHA256SUMS` (see
  [restic signature](#restic-signature)) and then the download against a SHA-256 hash stored in `install.sh`.
- `gpg` (optional but recommended) for the signature check; without it the installer warns, or fails with `--strict`.

## Install

Piping a download into a root shell is not supported. Read the code first, then run it.

From git:

```
git clone https://github.com/riyajkm/cwp-vault.git
cd cwp-vault
less install.sh                  # read it
sudo ./install.sh --dry-run      # print every action, change nothing
sudo ./install.sh
```

From a release tarball (verify the hash published on the release page first):

```
sha256sum cwp-vault-<version>.tar.gz     # must match the published SHA-256
tar xzf cwp-vault-<version>.tar.gz
cd cwp-vault-<version>
sudo ./install.sh
```

Options: `--dry-run`, `--enable-cron`, `--force`, `--no-module` (engine only), `--upgrade`, `--check`, `--strict`, `--version`.

What it does: installs restic if needed; copies the engine to `/usr/local/cwp-vault` and links
`/usr/local/bin/vault`; creates `etc/` and `var/` with locked-down permissions; installs the CWP module and
menu entry (temporarily lifting any immutable flag on the CWP admin directories, then restoring it as found);
installs logrotate and cron. It never overwrites an existing `etc/vault.conf` or `etc/secrets.env`.

The module copy kept in `/usr/local/cwp-vault/module-copy` and a daily cron job (`fix-menu`) re-add the
module if a CWP update removes it.

## First run

Nightly backups are installed **disabled** until you confirm storage works.

Web: CWP admin, CWP Vault, setup wizard.

CLI:

```
sudoedit /usr/local/cwp-vault/etc/vault.conf     # S3_ENDPOINT, S3_BUCKET, ...
vault secrets set                                # KEY=VALUE lines on stdin
vault init
vault test-storage
vault backup --account <one-account>
sudo ./install.sh --enable-cron                  # then turn on the nightly job
```

## Immutable backups (ransomware protection)

Normal backups can be erased by anyone with root on the server or a stolen storage key. Immutable mode uses
S3 Object Lock so deleted backups can be recovered. Read `docs/research/immutable.md` for the tested design.

**Cost:** data you delete (old snapshots removed by `vault prune`) is kept until the lock ends plus 7 days,
so you pay for roughly that much extra storage.

**Lock mode:** `COMPLIANCE` cannot be bypassed by anyone, including the provider account owner, until the
retention ends: this is the real protection. `GOVERNANCE` can be bypassed by a key that has the bypass
permission (Contabo keys do), so use it only for testing. You cannot shorten a COMPLIANCE lock, so test with a
throwaway bucket first.

Object Lock can only be enabled when a bucket is created: **you need a new bucket**.

1. Install the AWS CLI v2 on the server (it is only used to read and set bucket settings).
2. Contabo: Object Storage, Create bucket. Pick the region, name it, and tick **Enable Object Lock** in the
   creation form (versioning is turned on for you). Then open the bucket's Object Lock settings and set the
   **default retention**: mode `COMPLIANCE`, **14 days** (or more).
3. Point CWP Vault at the new bucket (Settings, or `S3_BUCKET` in `vault.conf`) and set
   `IMMUTABLE=yes`, `LOCK_MODE=COMPLIANCE`, `LOCK_DAYS=14`. `LOCK_DAYS` must not be more than the bucket default.
4. Run `vault init`. It refuses if the bucket has no object lock or a weaker default, and it adds a lifecycle
   rule `cwp-vault-noncurrent` that frees old versions `LOCK_DAYS + 7` days after they are deleted. Other
   lifecycle rules on the bucket are left alone.
5. Run `vault test-storage` and a first backup. Existing backups in the old bucket are not moved: keep it until
   the new one has enough history.

**Recovering after a wipe** (someone ran `forget --prune` or deleted objects):

```
vault recover --account <user>                 # dry run: shows how many delete markers would be removed
vault recover --account <user> --before 2026-10-28T03:00:00Z   # only markers newer than this time (UTC)
vault recover --account <user> --yes           # remove them, then restic unlock --remove-all and restic check
vault recover --all --yes                      # every account
```

Use `--before` with the time just before the attack so legitimate prunes are not undone. Afterwards check
`vault snapshots --account <user>` and run a test restore. Immutable mode does not protect against an attacker
who simply waits longer than `LOCK_DAYS` while silently breaking your backups: keep the heartbeat URL and the
monthly test restore on.

## Restic signature

When the installer has to download restic, it does not rely on the pinned SHA-256 alone. It also fetches
`SHA256SUMS` and `SHA256SUMS.asc` for the pinned release and the restic signing key
(`https://restic.net/gpg-key-alex.asc`), imports the key into a temporary `0700` GNUPGHOME, and refuses to go on
unless the key carries the fingerprint pinned in `install.sh` (`CF8F 18F2 8445 7597 3F79 D4E1 91A6 868B D3F7 A907`,
see restic's installation docs) and the signature is valid for exactly that key. The signed list must also contain
the same hash as the pinned one. A bad signature always stops the install. If `gpg` is missing (or the signature
files cannot be downloaded) the installer warns and continues with the pinned SHA-256, which is still verified;
`--strict` turns that warning into a failure. An already installed restic (0.17.0 or newer) is kept and not checked.

## Upgrade

Fetch the new version (`git pull` or a new tarball) and run:

```
sudo ./install.sh --upgrade --dry-run     # preview
sudo ./install.sh --upgrade
```

It replaces the engine (`bin/`, `lib/`) and the CWP module (through `fix-menu`, immutable flags restored as found),
refreshes logrotate, and appends cron lines the shipped file has and yours lacks (for example the monthly
`vault verify-restore --quiet`). Existing cron lines are not changed, and a backup line you left disabled (or
enabled) keeps its state. Config, secrets and logs are kept. It prints `old -> new`, records the version in
`/usr/local/cwp-vault/VERSION`, and refuses to downgrade unless you add `--force`. An install made with
`--no-module` stays engine-only. A plain `sudo ./install.sh` on an existing install still works as before.

## Check

```
sudo ./install.sh --check
```

A read-only report; it changes nothing and never prints config or secret values. It checks: restic version, vault
version and the `/usr/local/bin/vault` link, `vault.conf` and `secrets.env` present (secrets non-empty, mode 600),
the nightly backup cron line enabled, module files and the menu line in place, and the last backup result per
account from `vault status --json`. Each line starts with `ok` or `FAIL`; the exit code is 1 if anything failed
(including a still-disabled backup cron line, so do not use it before `vault init`), otherwise 0.

## Uninstall

```
sudo ./uninstall.sh              # asks first; add --yes to skip the prompt, --dry-run to preview
```

Removes the module and menu line, cron, logrotate, the `vault` symlink and the engine code. **Keeps** config,
secrets, logs, the restic binary and all remote backups. `--purge-local` also deletes `/usr/local/cwp-vault`
entirely (config and secrets included; keep your restic password elsewhere). Neither mode ever touches
remote storage.
