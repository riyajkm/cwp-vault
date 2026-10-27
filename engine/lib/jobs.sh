# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Background restore jobs: var/status/restore-<job>.json goes queued -> running -> done|failed.

RS_WORKER=0 RS_FINISHED=0 RS_INPLACE=0 RS_JOB='' RS_TARGET='' RS_ACCT='' RS_WHAT='' RS_T0=0 RS_KIND=restore
EX_PASS=''
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
  job_write "$RS_JOB" "$(printf '{"job":%s,"state":%s,"account":%s,"what":%s,"percent":%d,"bytes_done":%d,"pid":%d,"kind":%s}' \
    "$(json_str "$RS_JOB")" "$(json_str "$1")" "$(json_str "$RS_ACCT")" "$(json_str "$RS_WHAT")" "$2" "$3" "$$" "$(json_str "$RS_KIND")")"
}

# job_reap FILE : a "running" job whose worker pid is gone (killed, rebooted) is marked failed.
job_reap() {
  local c pid id
  c=$(<"$1") || return 0
  [[ $c == *'"state":"running"'* ]] || return 0
  pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' <<<"$c")
  [[ -n $pid ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then return 0; fi
  c=$(<"$1") || return 0 # re-read: the worker may have finished just now
  [[ $c == *'"state":"running"'* ]] || return 0
  id=${1##*/restore-}
  c=${c//'"state":"running"'/'"state":"failed"'}
  job_write "${id%.json}" "${c%\}},\"ok\":false,\"error\":\"the worker stopped before it finished\"}"
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
    printf '{"job":%s,"state":"queued","account":%s,"what":%s,"percent":0,"bytes_done":0,"kind":%s}\n' \
      "$(json_str "$RS_JOB")" "$(json_str "$RS_ACCT")" "$(json_str "$RS_WHAT")" "$(json_str "$RS_KIND")" >"$(job_file "$RS_JOB")"
  ) 2>/dev/null || die 3 "a restore for $RS_ACCT started in the same second; try again"
  chmod 0640 -- "$(job_file "$RS_JOB")"
  if [[ -n $EX_PASS ]]; then # the passphrase reaches the worker on its stdin, never on a command line
    printf '%s\n' "$EX_PASS" | setsid -f "$VAULT_SELF" "$RS_KIND" "${args[@]}" --job "$RS_JOB" >/dev/null 2>&1
  else
    setsid -f "$VAULT_SELF" "$RS_KIND" "${args[@]}" --job "$RS_JOB" </dev/null >/dev/null 2>&1
  fi
  printf '{"job":%s}\n' "$(json_str "$RS_JOB")"
}

# job_on_exit : a worker that dies without a result (a die, a signal) still ends as "failed".
job_on_exit() {
  if ((RS_WORKER && !RS_FINISHED)); then
    if [[ $RS_KIND == export ]]; then
      export_finish false '' 0 '' false '' "export stopped before it finished; see the log"
    else
      restore_finish false "$RS_TARGET" 0 0 "restore stopped before it finished; see the log"
    fi
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
      job_reap "$f"
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
  job_reap "$f"
  cat -- "$f"
}
