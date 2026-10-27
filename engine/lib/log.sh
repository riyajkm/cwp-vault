# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Logging helpers. No side effects on source.

log_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# log LEVEL message... ; INFO goes to stderr only on a tty or with VAULT_VERBOSE=1.
log() {
  local level=$1 msg line
  shift
  printf -v msg '%s ' "$@"
  msg=${msg% }
  msg=${msg//[[:cntrl:]]/ }
  line="$(log_ts) $level $msg"
  if [[ -n ${VAULT_LOG_FILE:-} && -d ${VAULT_LOG_FILE%/*} ]]; then
    printf '%s\n' "$line" >>"$VAULT_LOG_FILE" 2>/dev/null || true
  fi
  if [[ $level != INFO || ( -t 2 && ${VAULT_QUIET:-0} != 1 ) || ${VAULT_VERBOSE:-0} == 1 ]]; then
    printf '%s\n' "$line" >&2
  fi
}
log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }

# die CODE message...
die() {
  local code=$1 msg
  shift
  log ERROR "$@"
  if [[ ${ARG_JSON:-0} == 1 ]]; then
    printf -v msg '%s ' "$@"
    printf '{"error":%s,"code":%d}\n' "$(json_str "${msg% }")" "$code"
  fi
  exit "$code"
}

# JSON string literal (no jq needed).
json_str() {
  local s=$1 q='"' bs="\\"
  s=${s//"$bs"/"$bs$bs"}
  s=${s//"$q"/"$bs$q"}
  s=${s//$'\n'/"${bs}n"}
  s=${s//$'\r'/"${bs}r"}
  s=${s//$'\t'/"${bs}t"}
  s=${s//[[:cntrl:]]/ }
  printf '"%s"' "$s"
}

# join_by SEP items... (IFS here is newline/tab, so "$*" is unusable)
join_by() {
  local sep=$1 out='' first=1 x
  shift
  for x in "$@"; do
    if ((first)); then out=$x; first=0; else out+="$sep$x"; fi
  done
  printf '%s' "$out"
}
