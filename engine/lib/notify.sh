# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Alerts: email, webhook, heartbeat. All optional; failures here never change the exit code.

RUN_OK=0
RUN_FAILED=0
RUN_SKIPPED=0
RUN_ERROR=''
declare -a RUN_FAILED_NAMES=()

notify_host() {
  local h
  h=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-') || h=''
  printf '%s' "${h:-server}"
}

# Error text for outside readers: paths scrubbed, capped at 300 chars.
notify_scrub() {
  local s
  s=$(printf '%s' "$1" | tr '\n' ' ' | sed -E 's#(/[A-Za-z0-9._@+-]*)+#<path>#g')
  printf '%s' "${s:0:300}"
}

# _curl_post URL [JSON] : URL goes through a config file on /dev/fd, not argv.
_curl_post() {
  local url=$1 body=${2:-}
  curl --silent --show-error --fail --max-time 20 --proto '=https' --max-redirs 0 \
    --config <(printf 'url = "%s"\n' "$url") \
    --request POST --header 'Content-Type: application/json' --data-binary "$body" \
    --output /dev/null
}

hb_ping() { # start|success|fail
  [[ -n $HEARTBEAT_URL ]] || return 0
  local url=${HEARTBEAT_URL%/}
  case $1 in
    start) url+=/start ;;
    fail) url+=/fail ;;
    *) ;;
  esac
  _curl_post "$url" '' || log_warn "heartbeat $1 ping failed"
  return 0
}

notify_failure() { # COMMAND EXIT_CODE
  local cmd=$1 code=$2 host err subj body json names
  host=$(notify_host)
  err=$(notify_scrub "$RUN_ERROR")
  subj="[cwp-vault] $cmd FAILED on $host (exit $code)"
  names=$(join_by ', ' "${RUN_FAILED_NAMES[@]}")
  body=$(printf 'Command: %s\nHost: %s\nExit code: %s\nOK: %s  Failed: %s  Skipped: %s\nFailed: %s\nError: %s\n' \
    "$cmd" "$host" "$code" "$RUN_OK" "$RUN_FAILED" "$RUN_SKIPPED" "$names" "$err")
  if [[ -n $ALERT_EMAIL ]]; then
    {
      printf 'To: %s\nFrom: cwp-vault@%s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$ALERT_EMAIL" "$host" "$subj" "$body"
    } | sendmail -t -i || log_warn "alert email could not be sent"
  fi
  if [[ -n $ALERT_WEBHOOK ]]; then
    local -a q=()
    local n
    for n in "${RUN_FAILED_NAMES[@]}"; do q+=("$(json_str "$n")"); done
    json=$(printf '{"host":%s,"command":%s,"exit":%d,"ok":%d,"failed":%d,"skipped":%d,"failed_accounts":[%s],"error":%s}' \
      "$(json_str "$host")" "$(json_str "$cmd")" "$code" "$RUN_OK" "$RUN_FAILED" "$RUN_SKIPPED" \
      "$(join_by , "${q[@]}")" "$(json_str "$err")")
    _curl_post "$ALERT_WEBHOOK" "$json" || log_warn "alert webhook failed"
  fi
  return 0
}
