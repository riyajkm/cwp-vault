#!/usr/bin/env bash
# CWP Vault uninstaller. Keeps config, secrets, logs, the restic binary and ALL remote backups
# unless --purge-local. Never touches remote storage.
set -Eeuo pipefail
IFS=$'\n\t'

VAULT_HOME=/usr/local/cwp-vault
DRY=0 YES=0 PURGE=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run() { if ((DRY)); then (IFS=' '; printf '+ %s\n' "$*"); else "$@"; fi; }

usage() {
  cat <<USAGE
Usage: sudo ./uninstall.sh [--yes] [--purge-local] [--dry-run]
  Removes: CWP module + menu line, cron, logrotate, /usr/local/bin/vault, $VAULT_HOME/{bin,lib,module-copy}
  Keeps:   $VAULT_HOME/{etc,var}, /usr/local/bin/restic, all remote backups
  --purge-local  also delete $VAULT_HOME entirely (config, secrets, logs, status)
  --yes          do not ask for confirmation
  --dry-run      print actions only
USAGE
}

while (($#)); do
  case $1 in
    --yes) YES=1 ;;
    --purge-local) PURGE=1 ;;
    --dry-run) DRY=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done
((EUID == 0 || DRY)) || die "must run as root (use sudo)"

if ((!YES && !DRY)); then
  echo "This removes the CWP Vault engine and module from this server."
  echo "Remote backups are NOT touched."
  if ((PURGE)); then
    echo "--purge-local: $VAULT_HOME (config, secrets.env, logs) will be DELETED."
    echo "Make sure your restic password is stored elsewhere."
  else
    echo "Config, secrets and logs in $VAULT_HOME/{etc,var} are kept."
  fi
  read -r -p "Continue? [y/N] " ans </dev/tty || ans=n
  [[ $ans == y || $ans == Y ]] || { echo "Aborted."; exit 1; }
fi

# fix-menu --remove respects the immutable flags on the CWP directories.
if [[ -x $VAULT_HOME/bin/fix-menu ]]; then
  run "$VAULT_HOME/bin/fix-menu" --remove
else
  echo "WARN: $VAULT_HOME/bin/fix-menu not found; CWP module files and menu line not removed (none installed, or already gone)." >&2
fi

run rm -f -- /etc/cron.d/cwp-vault /etc/logrotate.d/cwp-vault
if [[ -L /usr/local/bin/vault && $(readlink /usr/local/bin/vault) == "$VAULT_HOME/bin/vault" ]]; then
  run rm -f -- /usr/local/bin/vault
fi

if ((PURGE)); then
  run rm -rf -- "${VAULT_HOME:?}"
else
  run rm -rf -- "${VAULT_HOME:?}/bin" "${VAULT_HOME:?}/lib" "${VAULT_HOME:?}/module-copy"
fi
echo "Done. /usr/local/bin/restic, /var/lib/cwp-vault/restore and all remote backups were left in place."
