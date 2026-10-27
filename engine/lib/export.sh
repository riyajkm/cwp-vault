# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Downloads: one account's files, a database or a mailbox as a single archive in $EXPORT_ROOT (0700),
# with a <job>.json record beside it. An export is a job of kind "export" (see jobs.sh).

EX_PART='' EX_TICK=0 EX_EST=0 EX_FILE='' EX_ACCT='' EX_PATH=''

# ex_get FILE KEY : value of a simple key in a one-line JSON record written by this module.
ex_get() {
  local v
  v=$(sed -n "s/.*\"$2\":\(\"[^\"]*\"\|[^,}]*\).*/\1/p" "$1" | head -n 1)
  v=${v#\"}
  printf '%s' "${v%\"}"
}

ex_iso_epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }

# ex_tick_start : while the dump runs, report output size and a rough percent (output bytes / snapshot size).
ex_tick_start() {
  local parent=$$
  (
    local b pct
    while kill -0 "$parent" 2>/dev/null; do
      sleep 2
      b=$(stat -c %s -- "$EX_PART" 2>/dev/null || echo 0)
      pct=0
      if ((EX_EST > 0)); then pct=$((b * 100 / EX_EST)); fi
      if ((pct > 99)); then pct=99; fi
      job_update running "$pct" "$b"
    done
  ) &
  EX_TICK=$!
}

ex_tick_stop() {
  if ((EX_TICK > 0)); then
    kill "$EX_TICK" 2>/dev/null || true
    wait "$EX_TICK" 2>/dev/null || true
    EX_TICK=0
  fi
}

# ex_estimate SNAPSHOT TAG : size of the snapshot in bytes (EX_EST), 0 when unknown. Used for progress only.
ex_estimate() {
  local -a sel=(--latest 1 --tag "$2")
  if [[ $1 != latest ]]; then sel=("$1"); fi
  EX_EST=0
  if restic_run "$ARG_ACCOUNT" snapshots --json "${sel[@]}"; then
    EX_EST=$(printf '%s' "$RESTIC_OUT" | grep -o '"total_bytes_processed":[0-9]*' | head -n 1 | cut -d: -f2 || true)
  fi
  [[ $EX_EST =~ ^[0-9]+$ ]] || EX_EST=0
}

# export_finish OK FILE BYTES SHA256 ENCRYPTED EXPIRES ERROR : writes the job record and prints the result.
export_finish() {
  local ok=$1 json x='' state=failed pct=0 f
  RS_FINISHED=1
  ex_tick_stop
  if [[ -n $EX_PART ]]; then
    rm -f -- "$EX_PART"
    EX_PART=''
  fi
  json=$(printf '{"ok":%s,"job":%s,"file":%s,"bytes":%d,"sha256":%s,"encrypted":%s,"expires":%s,"error":%s}' \
    "$ok" "$(json_str "$RS_JOB")" "$(json_str "$2")" "$3" "$(json_str "$4")" "$5" "$(json_str "$6")" "$(json_str "$7")")
  if [[ $ok == true ]]; then
    state='done'
    pct=100
  fi
  if ((RS_WORKER)); then
    x=$(printf ',"state":"%s","account":%s,"what":%s,"percent":%d,"kind":"export"' "$state" "$(json_str "$RS_ACCT")" "$(json_str "$RS_WHAT")" "$pct")
  fi
  json="${json%\}}${x}}"
  f=$(job_file "$RS_JOB")
  printf '%s\n' "$json" >"$f"
  chmod 0640 -- "$f"
  if [[ $ARG_JSON == 1 ]]; then
    printf '%s\n' "$json"
  elif [[ $ok == true ]]; then
    echo "Export ready: $2 ($3 bytes)"
  else
    echo "Export failed: $7" >&2
  fi
}

cmd_export() {
  local acct=$ARG_ACCOUNT what=$ARG_WHAT snap=$ARG_SNAPSHOT tag='' src='' ts rc=0 out final bytes sha created expires enc=false inc=''
  local -a tagargs=() dargs=()
  [[ -n $acct ]] || usage_err "export needs --account U"
  valid_account "$acct" || die 2 "invalid account name"
  valid_snapshot "$snap" || die 2 "invalid snapshot id"
  RS_KIND=export RS_ACCT=$acct RS_WHAT=$what RS_WORKER=0
  if [[ -n $ARG_JOB ]]; then
    valid_job_id "$ARG_JOB" && [[ $ARG_JOB == *-"$acct" && -f $(job_file "$ARG_JOB") ]] || die 2 "invalid --job"
    RS_WORKER=1
  fi
  case $what in
    files)
      inc=$HOME_ROOT/$acct
      [[ -z $ARG_DB && -z $ARG_MAILBOX ]] || usage_err "--db/--mailbox do not apply to --what files"
      ((${#ARG_PATHS[@]} <= 1)) || usage_err "export takes one --path"
      src=${ARG_PATHS[0]:-$inc}
      valid_restore_path "$src" || die 2 "invalid --path"
      [[ $src == "$inc" || $src == "$inc"/* ]] || die 2 "--path must be inside $inc"
      tag="files,$acct"
      out=tar.gz
      ;;
    mail)
      [[ -z $ARG_DB && ${#ARG_PATHS[@]} -eq 0 ]] || usage_err "mail export takes --mailbox user@domain only"
      [[ -n $ARG_MAILBOX ]] || usage_err "mail export needs --mailbox user@domain"
      restore_mailbox_check "$acct" "$ARG_MAILBOX"
      src=$RS_MB_PATH
      tag="files,$acct"
      out=tar.gz
      ;;
    db)
      [[ -z $ARG_MAILBOX && ${#ARG_PATHS[@]} -eq 0 ]] || usage_err "db export takes --db NAME only"
      valid_db "$acct" "$ARG_DB" || die 2 "--db must be a database of $acct"
      src=/db/$ARG_DB.sql
      tag="db:$ARG_DB"
      out=sql.gz
      ;;
    *) usage_err "export needs --what files|db|mail" ;;
  esac
  if ((ARG_ENCRYPT)); then
    command -v "$GPG_BIN" >/dev/null 2>&1 || die 2 "gpg not installed"
    IFS= read -r EX_PASS || true # first line of stdin; never an argument or an environment variable
    if ((${#EX_PASS} < 12 || ${#EX_PASS} > 256)); then die 2 "the passphrase (first line of stdin) must be 12 to 256 characters"; fi
    if [[ $EX_PASS =~ [[:cntrl:]] ]]; then die 2 "the passphrase must not contain control characters"; fi
    enc=true
    out+=.gpg
  fi

  ts=$(date -u +%Y%m%dT%H%M%SZ)
  RS_JOB=${ARG_JOB:-$ts-$acct}
  RS_T0=$(date +%s)
  if ((ARG_DETACH && !RS_WORKER)); then
    job_spawn
    return 0
  fi
  if ((RS_WORKER)); then
    RESTIC_PROGRESS_FPS=0.5
    job_update running 0 0
  fi
  restore_audit "$acct" "$snap" "$what" "$src" "export job=$RS_JOB encrypted=$enc"

  lock_take "$VAULT_LOCK/vault.lock" s || die 3 "prune/check/unlock is running"
  repo_ensure_existing "$acct"
  mkdir -p -- "$EXPORT_ROOT"
  chmod 0700 -- "$EXPORT_ROOT"
  check_free_gb "$EXPORT_ROOT" || die 1 "not enough free space for the export"
  ex_estimate "$snap" "$tag"

  if [[ $snap == latest ]]; then tagargs=(--tag "$tag"); fi
  if [[ $what == db ]]; then dargs=(dump "${tagargs[@]}" "$snap" "$src"); else dargs=(dump --archive tar "${tagargs[@]}" "$snap" "$src"); fi
  final=$RS_JOB.$out
  EX_PART=$EXPORT_ROOT/$final.part
  : >"$EX_PART"
  if ((RS_WORKER)); then ex_tick_start; fi
  if [[ $enc == true ]]; then
    # fd 3 carries the passphrase: fd 0 is the data stream, and gpg may only read both from stdin for a file argument
    (set -o pipefail; restic_dump "$acct" "${dargs[@]}" </dev/null | gzip -c |
      "$GPG_BIN" --batch --yes --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 --output "$EX_PART" 3< <(printf '%s\n' "$EX_PASS")) || rc=$?
  else
    (set -o pipefail; restic_dump "$acct" "${dargs[@]}" </dev/null | gzip -c >"$EX_PART") || rc=$?
  fi
  ex_tick_stop
  EX_PASS=''
  if ((rc != 0)); then
    RESTIC_ERR=$(restic_scrub <"$RESTIC_STDERR_FILE" 2>/dev/null | tail -n 5 | cut -c1-300 || true)
    restore_audit "$acct" "$snap" "$what" "$src" "export job=$RS_JOB (failed)"
    export_finish false '' 0 '' "$enc" '' "export failed: ${RESTIC_ERR:-rc $rc}"
    return 1
  fi
  mv -f -- "$EX_PART" "$EXPORT_ROOT/$final"
  EX_PART=''
  chmod 0600 -- "$EXPORT_ROOT/$final"
  bytes=$(stat -c %s -- "$EXPORT_ROOT/$final")
  sha=$(sha256sum -- "$EXPORT_ROOT/$final" | cut -d' ' -f1)
  created=$(log_ts)
  expires=$(date -u -d "+${EXPORT_KEEP_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
  printf '{"job":%s,"account":%s,"what":%s,"file":%s,"bytes":%d,"encrypted":%s,"created":%s,"expires":%s}\n' \
    "$(json_str "$RS_JOB")" "$(json_str "$acct")" "$(json_str "$what")" "$(json_str "$final")" "$bytes" "$enc" \
    "$(json_str "$created")" "$(json_str "$expires")" >"$EXPORT_ROOT/$RS_JOB.json.tmp.$$"
  mv -f -- "$EXPORT_ROOT/$RS_JOB.json.tmp.$$" "$EXPORT_ROOT/$RS_JOB.json"
  restore_audit "$acct" "$snap" "$what" "$src" "export job=$RS_JOB file=$final bytes=$bytes encrypted=$enc expires=$expires"
  export_finish true "$final" "$bytes" "$sha" "$enc" "$expires" ""
}

# ex_records : the export records, newest first.
ex_records() {
  local f
  for f in "$EXPORT_ROOT"/*.json; do
    if [[ -f $f && ! -L $f ]]; then printf '%s\n' "$f"; fi
  done | sort -r
}

# ex_file_ok NAME : a plain file name, as written by cmd_export.
ex_file_ok() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$ ]]; }

cmd_exports() {
  local f file first=1
  local -a recs=()
  mapfile -t recs < <(ex_records)
  if [[ $ARG_JSON == 1 ]]; then printf '['; fi
  for f in "${recs[@]}"; do
    file=$(ex_get "$f" file)
    ex_file_ok "$file" && [[ -f $EXPORT_ROOT/$file ]] || continue
    if [[ $ARG_JSON == 1 ]]; then
      if ((first)); then first=0; else printf ','; fi
      tr -d '\n' <"$f"
    else
      printf '%s %s %s bytes, expires %s\n' "$(ex_get "$f" job)" "$file" "$(ex_get "$f" bytes)" "$(ex_get "$f" expires)"
    fi
  done
  if [[ $ARG_JSON == 1 ]]; then printf ']\n'; fi
}

# ex_keep_hours : EXPORT_KEEP_HOURS from vault.conf, or the default when the config is unusable.
ex_keep_hours() {
  if (cfg_load) >/dev/null 2>&1; then cfg_load >/dev/null 2>&1; else cfg_defaults; fi
}

cmd_export_clean() {
  local f file now removed=0 name job
  local -a recs=() orphans=()
  ex_keep_hours
  now=$(date +%s)
  mapfile -t recs < <(ex_records)
  for f in "${recs[@]}"; do
    file=$(ex_get "$f" file)
    if ex_file_ok "$file" && [[ -f $EXPORT_ROOT/$file ]] && (($(ex_iso_epoch "$(ex_get "$f" expires)") > now)); then continue; fi
    if ex_file_ok "$file"; then rm -f -- "${EXPORT_ROOT:?}/$file"; fi
    rm -f -- "$f"
    removed=$((removed + 1))
  done
  # leftovers of an export that never finished (no record) once they are older than the keep time
  if [[ -d $EXPORT_ROOT ]]; then
    mapfile -d '' -t orphans < <(find "$EXPORT_ROOT" -maxdepth 1 -type f ! -name '*.json' -mmin "+$((EXPORT_KEEP_HOURS * 60))" -print0)
  fi
  for f in "${orphans[@]}"; do
    name=${f##*/}
    job=${name%%.*}
    if [[ ! -f $EXPORT_ROOT/$job.json ]]; then
      rm -f -- "$f"
      removed=$((removed + 1))
    fi
  done
  log_info "export-clean: removed $removed"
  if [[ $ARG_JSON == 1 ]]; then printf '{"removed":%d}\n' "$removed"; fi
}

# ex_lookup JOB : sets EX_FILE, EX_ACCT, EX_PATH for a live (unexpired) export. Dies (2) otherwise.
ex_lookup() {
  local rec=$EXPORT_ROOT/$1.json p
  valid_job_id "$1" || usage_err "needs --job ID"
  [[ -f $rec && ! -L $rec ]] || die 2 "no such export"
  EX_FILE=$(ex_get "$rec" file)
  EX_ACCT=$(ex_get "$rec" account)
  ex_file_ok "$EX_FILE" || die 2 "the export record is damaged"
  (($(ex_iso_epoch "$(ex_get "$rec" expires)") > $(date +%s))) || die 2 "the export has expired"
  p=$EXPORT_ROOT/$EX_FILE
  [[ -f $p && ! -L $p ]] || die 2 "the export file is gone"
  [[ $(realpath -- "$p") == "$(realpath -- "$EXPORT_ROOT")/$EX_FILE" ]] || die 2 "the export file is outside the exports folder"
  EX_PATH=$p
}

cmd_export_path() {
  ex_lookup "$ARG_JOB"
  printf '%s\n' "$EX_PATH"
}

cmd_audit_download() {
  ex_lookup "$ARG_JOB"
  restore_audit "$EX_ACCT" - export "$EX_FILE" "download job=$ARG_JOB"
  if [[ $ARG_JSON == 1 ]]; then printf '{"ok":true}\n'; fi
}
