# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Schedule: the "vault backup|prune|check --all" lines of the cron file, read and (backup only) rewritten.
# Times are server local time, because cron runs in server time.

# 1 hash, 2 minute, 3 hour, 4 day of week, 5 command part (starts at "root"), 6 kind
SCH_RE='^(#*)[[:space:]]*([0-9]{1,2})[[:space:]]+([0-9]{1,2})[[:space:]]+\*[[:space:]]+\*[[:space:]]+([0-7]|[A-Za-z]{3}|\*)[[:space:]]+(root[[:space:]]+[^[:space:]]*vault[[:space:]]+(backup|prune|check)[[:space:]]+--all.*)$'
declare -A SCH_EN=() SCH_T=() SCH_D=() SCH_N=()

sch_day() {
  local -a names=(sun mon tue wed thu fri sat sun)
  case $1 in
    [0-7]) printf '%s' "${names[$1]}" ;;
    *) printf '%s' "${1,,}" ;;
  esac
}

# sch_load : fills SCH_EN/SCH_T/SCH_D/SCH_N (line number) per kind; an active line beats a commented one.
sch_load() {
  local line k n=0 en
  SCH_EN=() SCH_T=() SCH_D=() SCH_N=()
  [[ -r $VAULT_CRON_FILE ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ $SCH_RE ]] || continue
    ((10#${BASH_REMATCH[2]} <= 59 && 10#${BASH_REMATCH[3]} <= 23)) || continue
    k=${BASH_REMATCH[6]}
    en=true
    if [[ -n ${BASH_REMATCH[1]} ]]; then en=false; fi
    if [[ -n ${SCH_N[$k]:-} && ( ${SCH_EN[$k]} == true || $en == false ) ]]; then continue; fi
    SCH_EN[$k]=$en
    SCH_N[$k]=$n
    SCH_T[$k]=$(printf '%02d:%02d' "$((10#${BASH_REMATCH[3]}))" "$((10#${BASH_REMATCH[2]}))")
    SCH_D[$k]=$(sch_day "${BASH_REMATCH[4]}")
  done <"$VAULT_CRON_FILE"
}

sch_tz() {
  local tz=''
  if command -v timedatectl >/dev/null 2>&1; then tz=$(timedatectl show -p Timezone --value 2>/dev/null || true); fi
  if [[ -z $tz && -L /etc/localtime ]]; then
    tz=$(readlink /etc/localtime)
    tz=${tz#*zoneinfo/}
  fi
  if [[ -z $tz ]]; then tz=$(date +%Z); fi
  printf '%s' "$tz"
}

# sch_json : the schedule object (also nested in status --json).
sch_json() {
  local now t e next='null' nexte='null'
  sch_load
  now=$(date +%s)
  t=${SCH_T[backup]:-01:30}
  if [[ ${SCH_EN[backup]:-false} == true ]]; then
    e=$(date -d "today $t" +%s)
    if ((e <= now)); then e=$(date -d "tomorrow $t" +%s); fi
    nexte=$e
    next=$(json_str "$(date -d "@$e" +%Y-%m-%dT%H:%M:%S%z)")
  fi
  printf '{"backup":{"enabled":%s,"time":"%s"},"prune":{"day":"%s","time":"%s"},"check":{"day":"%s","time":"%s"},' \
    "${SCH_EN[backup]:-false}" "$t" "${SCH_D[prune]:-sun}" "${SCH_T[prune]:-04:00}" "${SCH_D[check]:-wed}" "${SCH_T[check]:-04:00}"
  printf '"timezone":%s,"utc_offset":"%s","now_epoch":%d,"next_run":%s,"next_run_epoch":%s}' \
    "$(json_str "$(sch_tz)")" "$(date +%z)" "$now" "$next" "$nexte"
}

# sch_set : rewrite only the "backup --all" line (temp file + rename, mode 0644); create it when missing.
sch_set() {
  local t=$ARG_TIME en=$ARG_ENABLED hash='' idx line n=0 tmp
  [[ -n $t || -n $en ]] || usage_err "schedule set needs --time HH:MM and/or --enabled yes|no"
  if [[ -n $t && ! $t =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then die 2 "invalid --time; use HH:MM from 00:00 to 23:59"; fi
  [[ -z $en || $en == yes || $en == no ]] || die 2 "--enabled must be yes or no"
  sch_load
  idx=${SCH_N[backup]:-0}
  if [[ -z $t ]]; then t=${SCH_T[backup]:-01:30}; fi
  if [[ -z $en ]]; then
    en=yes
    if [[ ${SCH_EN[backup]:-} == false ]]; then en=no; fi
  fi
  if [[ $en == no ]]; then hash='#'; fi
  tmp=${VAULT_CRON_FILE%/*}/.${VAULT_CRON_FILE##*/}.tmp.$$
  {
    if [[ -r $VAULT_CRON_FILE ]]; then
      while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        if ((n == idx)) && [[ $line =~ $SCH_RE ]]; then
          printf '%s%d %d * * %s  %s\n' "$hash" "$((10#${t#*:}))" "$((10#${t%:*}))" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
        else
          printf '%s\n' "$line"
        fi
      done <"$VAULT_CRON_FILE"
    else
      printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    fi
    if ((idx == 0)); then
      printf '%s%d %d * * *  root /usr/local/bin/vault backup --all --quiet\n' "$hash" "$((10#${t#*:}))" "$((10#${t%:*}))"
    fi
  } >"$tmp" || { rm -f -- "$tmp"; die 1 "cannot write the cron file"; }
  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$VAULT_CRON_FILE" || { rm -f -- "$tmp"; die 1 "cannot replace the cron file"; }
  printf '%s schedule backup time=%s enabled=%s\n' "$(log_ts)" "$t" "$en" >>"$VAULT_AUDIT"
}

cmd_schedule() {
  local sub=${ARG_POS[0]:-get}
  ((${#ARG_POS[@]} <= 1)) || usage_err "schedule takes get or set"
  case $sub in
    get) ;;
    set) sch_set ;;
    *) usage_err "schedule takes get or set" ;;
  esac
  if [[ $ARG_JSON == 1 ]]; then
    sch_json
    echo
  else
    sch_load
    printf 'Backup: %s at %s (server time)\nPrune: %s at %s\nCheck: %s at %s\n' \
      "$([[ ${SCH_EN[backup]:-false} == true ]] && echo daily || echo disabled)" "${SCH_T[backup]:-01:30}" \
      "${SCH_D[prune]:-sun}" "${SCH_T[prune]:-04:00}" "${SCH_D[check]:-wed}" "${SCH_T[check]:-04:00}"
  fi
}
