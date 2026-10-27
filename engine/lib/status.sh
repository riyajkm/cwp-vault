# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Status JSON per account (written with printf, read with sed; no jq).

# status_write NAME STARTED_ISO START_EPOCH RESULT FILES_NEW FILES_CHANGED BYTES ERROR SNAPSHOT...
status_write() {
  local name=$1 started=$2 t0=$3 result=$4 fnew=$5 fchg=$6 bytes=$7 err=$8 f tmp t1 s first=1
  shift 8
  t1=$(date +%s)
  f="$VAULT_STATUS/$name.json"
  tmp="$f.tmp.$$"
  {
    printf '{\n'
    printf '  "account": %s,\n' "$(json_str "$name")"
    printf '  "started": %s,\n' "$(json_str "$started")"
    printf '  "finished": %s,\n' "$(json_str "$(log_ts)")"
    printf '  "duration_s": %d,\n' "$((t1 - t0))"
    printf '  "result": %s,\n' "$(json_str "$result")"
    printf '  "snapshots": ['
    for s in "$@"; do
      if ((first)); then first=0; else printf ', '; fi
      json_str "$s"
    done
    printf '],\n'
    printf '  "files_new": %d,\n  "files_changed": %d,\n  "bytes_added": %d,\n' "$fnew" "$fchg" "$bytes"
    printf '  "error": %s\n}\n' "$(json_str "${err:0:300}")"
  } >"$tmp"
  chmod 0640 -- "$tmp"
  mv -f -- "$tmp" "$f"
}

# status_get FILE KEY : raw value of a simple top-level key (strings keep their JSON escaping).
status_get() {
  local v
  v=$(sed -n "s/^  \"$2\": //p" "$1" | head -n 1)
  v=${v%,}
  v=${v#\"}
  v=${v%\"}
  printf '%s' "$v"
}

status_snap_count() {
  local q
  q=$(grep '^  "snapshots"' "$1" | tr -cd '"' | wc -c)
  printf '%d' "$(((q - 2) / 2))"
}

status_obj() { # FILE
  printf '{"account":"%s","result":"%s","started":"%s","finished":"%s","duration_s":%d,"bytes_added":%d,"snapshots":%d,"error":"%s"}' \
    "$(status_get "$1" account)" "$(status_get "$1" result)" "$(status_get "$1" started)" "$(status_get "$1" finished)" \
    "$(status_get "$1" duration_s)" "$(status_get "$1" bytes_added)" "$(status_snap_count "$1")" "$(status_get "$1" error)"
}

# status_never NAME : placeholder for an account that has no status file yet.
status_never() {
  printf '{"account":%s,"result":"never","started":null,"finished":null,"duration_s":0,"bytes_added":0,"snapshots":0,"error":null}' "$(json_str "$1")"
}

status_running() { # prints JSON objects separated by commas
  local f pid cmd started name first=1
  for f in "$VAULT_LOCK"/*.lock; do
    [[ -s $f ]] || continue
    name=${f##*/}
    name=${name%.lock}
    [[ $name == vault ]] && continue
    IFS=" " read -r pid cmd started <"$f" || continue # global IFS is newline+tab; fields are space-separated
    [[ $pid =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    if ((first)); then first=0; else printf ','; fi
    printf '{"account":%s,"command":%s,"pid":%d,"started":%s}' "$(json_str "$name")" "$(json_str "$cmd")" "$pid" "$(json_str "$started")"
  done
}

cmd_status() {
  local f n first=1 configured=false
  local -a files=() names=()
  for f in "$VAULT_STATUS"/*.json; do
    [[ -e $f ]] || continue
    case ${f##*/} in restore-* | verify-*) continue ;; esac
    files+=("$f")
  done
  if [[ -f $VAULT_CONF && -f $VAULT_SECRETS ]] && (cfg_load) >/dev/null 2>&1; then configured=true; fi
  if [[ $ARG_JSON == 1 ]]; then
    printf '{"version":"%s","configured":%s,"accounts":[' "$VAULT_VERSION" "$configured"
    # every discovered account (ACCOUNTS/EXCLUDE_ACCOUNTS applied); status files only if discovery fails
    if [[ $configured == true ]] && n=$( (cfg_load && acct_discover) 2>/dev/null); then
      mapfile -t names <<<"$n"
    else
      for f in "${files[@]}"; do names+=("${f##*/}"); done
      names=("${names[@]%.json}")
    fi
    for n in "${names[@]}"; do
      [[ -n $n && $n != _server ]] || continue
      if ((first)); then first=0; else printf ','; fi
      if [[ -f $VAULT_STATUS/$n.json ]]; then status_obj "$VAULT_STATUS/$n.json"; else status_never "$n"; fi
    done
    printf '],"server":'
    if [[ -f $VAULT_STATUS/_server.json ]]; then status_obj "$VAULT_STATUS/_server.json"; else printf 'null'; fi
    printf ',"running":[%s],"immutable":%s,"last_verify":%s}\n' "$(status_running)" "$(imm_status_json)" "$(status_last_verify)"
    return 0
  fi
  if ((${#files[@]} == 0)); then
    echo "No backups recorded yet."
    return 0
  fi
  printf '%-20s %-8s %-21s %8s %14s\n' ACCOUNT RESULT FINISHED SECONDS BYTES_ADDED
  for f in "${files[@]}"; do
    printf '%-20s %-8s %-21s %8s %14s\n' "$(status_get "$f" account)" "$(status_get "$f" result)" \
      "$(status_get "$f" finished)" "$(status_get "$f" duration_s)" "$(status_get "$f" bytes_added)"
  done
}
