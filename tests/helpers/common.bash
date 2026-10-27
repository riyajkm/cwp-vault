# shellcheck shell=bash
# shellcheck disable=SC2034,SC2119,SC2120 # sourced by bats: LIB and conf_with are used from the .bats files
# Shared bats helpers. Each test gets a throwaway VAULT_HOME, fake /home and /var/vmail trees,
# and PATH stubs for restic, mysql, mysqldump, sendmail and curl (tests/stubs/*).
# No bats-support/bats-assert needed: plain [ ] asserts and `run`.

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
VAULT=$REPO_ROOT/engine/bin/vault
LIB=$REPO_ROOT/engine/lib

DEFAULT_CONF='S3_ENDPOINT=https://s3.example.com
S3_BUCKET=example-backups
S3_PREFIX=srv1/
BACKUP_SERVER=no
MIN_FREE_GB=0
RETRIES=0'

SECRET_KEY_ID=AKIAEXAMPLE1234
SECRET_KEY=SECRETexample/Key+0987654321
SECRET_PW=correct-horse-battery

vault_setup() {
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"   # Git Bash on Windows: do not rewrite /paths for native python
  T=$(mktemp -d)
  export VAULT_HOME=$T/vh VAULT_HOME_ROOT=$T/home VAULT_VMAIL_ROOT=$T/vmail VAULT_RESTORE_ROOT=$T/restores
  export STUB_LOG=$T/stublog
  mkdir -p "$VAULT_HOME/etc" "$T/home/alice" "$T/home/bob" "$T/vmail/example.com" "$T/vmail/example.org" "$STUB_LOG" "$T/bin"
  local s
  for s in restic mysql mysqldump sendmail curl aws; do
    cp "$REPO_ROOT/tests/stubs/$s" "$T/bin/$s"
    chmod +x "$T/bin/$s"
  done
  PATH="$T/bin:$PATH"
  conf_with
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nRESTIC_PASSWORD=%s\n' \
    "$SECRET_KEY_ID" "$SECRET_KEY" "$SECRET_PW" >"$VAULT_HOME/etc/secrets.env"
  chmod 600 "$VAULT_HOME/etc/secrets.env"
}

vault_teardown() {
  [[ -n ${HOLDER_PID:-} ]] && kill "$HOLDER_PID" 2>/dev/null || true
  rm -rf "$T"
}

# conf_with [KEY=VALUE ...] : default config plus extra lines (the last assignment wins).
conf_with() {
  { printf '%s\n' "$DEFAULT_CONF"; (($# == 0)) || printf '%s\n' "$@"; } >"$VAULT_HOME/etc/vault.conf"
  chmod 640 "$VAULT_HOME/etc/vault.conf"
}

vault() { "$VAULT" "$@"; }
vout() { "$VAULT" "$@" 2>/dev/null; }   # stdout only (JSON)

need_python() { command -v python3 >/dev/null 2>&1 || skip "python3 not available"; }
json_valid() { python3 -I -m json.tool >/dev/null; }
# jget 'EXPR over d' < json
jget() { python3 -I -c 'import sys,json; d=json.loads(sys.stdin.buffer.read().decode("utf-8")); print(eval(sys.argv[1]))' "$1"; }

status_file() { printf '%s/var/status/%s.json' "$VAULT_HOME" "$1"; }
restic_log() { cat "$STUB_LOG/restic.log" 2>/dev/null || true; }
count_lines() { grep -c -- "$1" "$2" 2>/dev/null || true; }
