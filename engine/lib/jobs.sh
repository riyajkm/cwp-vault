# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Background restore jobs: var/status/restore-<job>.json goes queued -> running -> done|failed.

RS_WORKER=0 RS_FINISHED=0 RS_INPLACE=0 RS_JOB='' RS_TARGET='' RS_ACCT='' RS_WHAT='' RS_T0=0
declare -a RS_SAFETY=()

valid_job_id() { [[ ${1:-} =~ ^[0-9]{8}T[0-9]{6}Z-[a-z][a-z0-9_]{0,31}$ ]]; }
job_file() { printf '%s/restore-%s.json' "$VAULT_STATUS" "$1"; }

# job_write ID JSON : atomic replace, 0640.
job_write() {
  local f tmp
  f=$(job_file "$1")
  tmp="$f.tmp.$$"
  printf '%s\n' "$2" >"$tmp"
  chmod 0640 -- "$tmp"
  mv -f -- "$tmp" "$f"
}

# job_update STATE PERCENT BYTES_DONE : progress record of the running job.
job_update() {
  job_write "$RS_JOB" "$(printf '{"job":%s,"state":%s,"account":%s,"what":%s,"percent":%d,"bytes_done":%d}' \
    "$(json_str "$RS_JOB")" "$(json_str "$1")" "$(json_str "$RS_ACCT")" "$(json_str "$RS_WHAT")" "$2" "$3")"
}

# job_progress : reads `restic restore --json` lines on stdin, keeps the job file current.
job_progress() {
  local line pct bytes
  while IFS= read -r line; do
    [[ $line == *'"message_type":"status"'* ]] || continue
    pct=$(sed -n 's/.*"percent_done":\([0-9.]*\).*/\1/p' <<<"$line")
    bytes=$(sed -nE 's/.*"bytes_(restored|done)":([0-9]+).*/\2/p' <<<"$line")
    pct=$(awk -v p="${pct:-0}" 'BEGIN { printf "%d", p * 100 }')
    job_update running "$pct" "${bytes:-0}"
  done
  return 0
}

# job_spawn : queue the job and re-exec this restore detached; prints {"job":ID}.
job_spawn() {
  local a
  local -a args=()
  for a in "${VAULT_ARGS[@]}"; do
    if [[ $a != --detach ]]; then args+=("$a"); fi
  done
  (
    set -C
    printf '{"job":%s,"state":"queued","account":%s,"what":%s,"percent":0,"bytes_done":0}\n' \
      "$(json_str "$RS_JOB")" "$(json_str "$RS_ACCT")" "$(json_str "$RS_WHAT")" >"$(job_file "$RS_JOB")"
  ) 2>/dev/null || die 3 "a restore for $RS_ACCT started in the same second; try again"
  chmod 0640 -- "$(job_file "$RS_JOB")"
  setsid -f "$VAULT_SELF" restore "${args[@]}" --job "$RS_JOB" </dev/null >/dev/null 2>&1
  printf '{"job":%s}\n' "$(json_str "$RS_JOB")"
}

# job_on_exit : a worker that dies without a result (a die, a signal) still ends as "failed".
job_on_exit() {
  if ((RS_WORKER && !RS_FINISHED)); then
    restore_finish false "$RS_TARGET" 0 0 "restore stopped before it finished; see the log"
  fi
  return 0
}

cmd_jobs() {
  local f first=1
  local -a files=("$VAULT_STATUS"/restore-*.json)
  mapfile -t files < <(printf '%s
' "${files[@]}" | sort -r | head -n 20)
  if [[ $ARG_JSON == 1 ]]; then
    printf '['
    for f in "${files[@]}"; do
      [[ -f $f ]] || continue
      if ((first)); then first=0; else printf ','; fi
      tr -d '\n' <"$f"
    done
    printf ']\n'
  else
    for f in "${files[@]}"; do
      [[ -f $f ]] && echo "${f##*/restore-}"
    done
  fi
  return 0
}

cmd_job() {
  local f
  valid_job_id "$ARG_ID" || usage_err "job needs --id JOB"
  f=$(job_file "$ARG_ID")
  [[ -f $f ]] || die 2 "no such job"
  cat -- "$f"
}
