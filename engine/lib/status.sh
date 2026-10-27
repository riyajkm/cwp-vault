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

status_running() { # prints JSON objects separated by commas
  local f pid cmd started name first=1
  for f in "$VAULT_LOCK"/*.lock; do
    [[ -s $f ]] || continue
    name=${f##*/}
    name=${name%.lock}
    [[ $name == vault ]] && continue
    read -r pid cmd started <"$f" || continue
    [[ $pid =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    if ((first)); then first=0; else printf ','; fi
    printf '{"account":%s,"command":%s,"pid":%d,"started":%s}' "$(json_str "$name")" "$(json_str "$cmd")" "$pid" "$(json_str "$started")"
  done
}

cmd_status() {
  local f first=1 configured=false
  local -a files=()
  for f in "$VAULT_STATUS"/*.json; do
    [[ -e $f ]] || continue
    case ${f##*/} in restore-*) continue ;; esac
    files+=("$f")
  done
  if [[ -f $VAULT_CONF && -f $VAULT_SECRETS ]] && (cfg_load) >/dev/null 2>&1; then configured=true; fi
  if [[ $ARG_JSON == 1 ]]; then
    printf '{"version":"%s","configured":%s,"accounts":[' "$VAULT_VERSION" "$configured"
    for f in "${files[@]}"; do
      [[ ${f##*/} == _server.json ]] && continue
      if ((first)); then first=0; else printf ','; fi
      status_obj "$f"
    done
    printf '],"server":'
    if [[ -f $VAULT_STATUS/_server.json ]]; then status_obj "$VAULT_STATUS/_server.json"; else printf 'null'; fi
    printf ',"running":[%s]}\n' "$(status_running)"
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
