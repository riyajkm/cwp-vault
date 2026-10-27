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
  (0.19.1, x86_64 or aarch64) and checks it against a SHA-256 hash stored in `install.sh`.
  GPG verification is planned for v0.3.

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

Options: `--dry-run`, `--enable-cron`, `--force`, `--no-module` (engine only), `--version`.

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

## Upgrade

Fetch the new version (`git pull` or a new tarball) and run `sudo ./install.sh` again. Engine files and the
module are replaced; config, secrets, logs and an existing cron file are kept. Use `--enable-cron` only if you
want the backup line switched on in an existing cron file.

## Uninstall

```
sudo ./uninstall.sh              # asks first; add --yes to skip the prompt, --dry-run to preview
```

Removes the module and menu line, cron, logrotate, the `vault` symlink and the engine code. **Keeps** config,
secrets, logs, the restic binary and all remote backups. `--purge-local` also deletes `/usr/local/cwp-vault`
entirely (config and secrets included; keep your restic password elsewhere). Neither mode ever touches
remote storage.
