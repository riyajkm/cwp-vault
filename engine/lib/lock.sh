# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Paths, directories, locks, run registry, free-space check.

declare -a LOCK_FDS=()
LOCK_LAST_FD=''

vault_paths() {
  VAULT_CONF="$VAULT_HOME/etc/vault.conf"
  VAULT_SECRETS="$VAULT_HOME/etc/secrets.env"
  VAULT_VAR="$VAULT_HOME/var"
  VAULT_STATUS="$VAULT_VAR/status"
  VAULT_LOG_DIR="$VAULT_VAR/log"
  VAULT_LOG_FILE="$VAULT_LOG_DIR/vault.log"
  VAULT_AUDIT="$VAULT_LOG_DIR/audit.log"
  VAULT_LOCK="$VAULT_VAR/lock"
  VAULT_CACHE="$VAULT_VAR/cache"
  VAULT_TMP="$VAULT_VAR/tmp"
  VAULT_RUN="$VAULT_VAR/run"
  RESTIC_STDERR_FILE="$VAULT_TMP/restic.$$.err"
  HOME_ROOT=${VAULT_HOME_ROOT:-/home}
  VMAIL_ROOT=${VAULT_VMAIL_ROOT:-/var/vmail}
  RESTORE_ROOT=${VAULT_RESTORE_ROOT:-/var/lib/cwp-vault/restore}
}

# var/ is 0750 root:root; log/status files are made 0640 where written.
vault_dirs() {
  local d
  mkdir -p -- "$VAULT_VAR" "$VAULT_HOME/etc"
  chmod 0750 -- "$VAULT_VAR"
  for d in "$VAULT_STATUS" "$VAULT_LOG_DIR" "$VAULT_LOCK" "$VAULT_CACHE" "$VAULT_TMP" "$VAULT_RUN"; do
    mkdir -p -- "$d"
    chmod 0750 -- "$d"
  done
  chmod 0700 -- "$VAULT_CACHE"
  for d in "$VAULT_LOG_FILE" "$VAULT_AUDIT"; do
    if [[ ! -e $d ]]; then : >"$d"; fi
    chmod 0640 -- "$d"
  done
}

# lock_take FILE x|s : non-blocking; sets LOCK_LAST_FD. Returns 1 when busy.
lock_take() {
  local fd
  exec {fd}>>"$1" || return 1
  if ! flock -n "-$2" "$fd"; then
    exec {fd}>&-
    return 1
  fi
  LOCK_LAST_FD=$fd
  LOCK_FDS+=("$fd")
  # who holds it (read by "vault status" for the running list); exclusive locks only
  if [[ $2 == x && ${3:-} != noinfo ]]; then printf '%s %s %s\n' "$$" "${VAULT_CMD:-vault}" "$(log_ts)" >"/proc/self/fd/$fd" 2>/dev/null || true; fi
}

lock_release() {
  local fd=$1 x
  local -a keep=()
  : >"/proc/self/fd/$fd" 2>/dev/null || true
  exec {fd}>&-
  for x in "${LOCK_FDS[@]}"; do
    if [[ $x != "$fd" ]]; then keep+=("$x"); fi
  done
  LOCK_FDS=("${keep[@]}")
}

# Run registry: a file per live vault process, so unlock knows if it is alone.
run_register() { : >"$VAULT_RUN/$$"; }
run_unregister() { rm -f -- "$VAULT_RUN/$$" "${RESTIC_STDERR_FILE:-/nonexistent}" 2>/dev/null || true; }

others_alive() {
  local f pid
  for f in "$VAULT_RUN"/*; do
    [[ -e $f ]] || continue
    pid=${f##*/}
    [[ $pid == "$$" ]] && continue
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -f -- "$f"
  done
  return 1
}

# check_free_gb PATH : returns 1 when free space is below MIN_FREE_GB.
check_free_gb() {
  local kib
  ((MIN_FREE_GB > 0)) || return 0
  kib=$(df -Pk -- "$1" | awk 'NR==2 {print $4}')
  [[ $kib =~ ^[0-9]+$ ]] || return 0
  if ((kib / 1048576 < MIN_FREE_GB)); then
    log_error "free space on filesystem of $1 is below ${MIN_FREE_GB} GB"
    return 1
  fi
}
