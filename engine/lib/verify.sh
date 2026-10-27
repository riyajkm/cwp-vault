# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# verify-restore: prove the backups restore. Random files go to a throwaway directory, every database
# into a throwaway database; both are removed again (also on error or signal, see verify_cleanup).

VERIFY_FILES=20
VERIFY_DB=''
VERIFY_DIR=''
declare -a VR_OBJ=() VR_TXT=()

# Removes whatever a verify run left behind. Called from cleanup() on every exit.
verify_cleanup() {
  if [[ $VERIFY_DB =~ ^cwpvault_verify_[0-9a-f]{8}$ ]]; then
    db_q "DROP DATABASE IF EXISTS \`$VERIFY_DB\`" >/dev/null 2>&1 || log_error "could not drop the throwaway database $VERIFY_DB; drop it by hand"
  fi
  VERIFY_DB=''
  if [[ -n $VERIFY_DIR && $VERIFY_DIR == "$RESTORE_ROOT"/verify-* ]]; then rm -rf -- "$VERIFY_DIR"; fi
  VERIFY_DIR=''
}

# stdin: restic ls --json. Prints up to VERIFY_FILES random regular files as "size<TAB>path".
# shortcut: paths with a backslash (JSON escapes) are skipped; fine for a sample, upgrade if you need them covered.
verify_sample() {
  awk '/"type":"file"/ && match($0, /"path":"[^"\\]*"/) {
         p = substr($0, RSTART + 8, RLENGTH - 9); s = 0
         if (match($0, /"size":[0-9]+/)) s = substr($0, RSTART + 7, RLENGTH - 7)
         print s "\t" p }' | shuf -n "$VERIFY_FILES"
}

# verify_files ACCOUNT : sets VF_CHECKED, VF_OK; returns 1 with VF_ERR on failure.
VF_CHECKED=0 VF_OK=0 VF_ERR=''
verify_files() {
  local acct=$1 list="$VAULT_TMP/verify.$$.list" rc=0 line p sz got ts i
  local -a lines=() paths=() sizes=() incs=()
  VF_CHECKED=0 VF_OK=0 VF_ERR=''
  : >"$RESTIC_STDERR_FILE"
  restic_dump "$acct" ls --json latest --tag "files,$acct" | verify_sample >"$list" || rc=$?
  mapfile -t lines <"$list"
  rm -f -- "$list"
  if ((rc != 0)); then
    VF_ERR="cannot list the latest files snapshot: $(restic_scrub <"$RESTIC_STDERR_FILE" 2>/dev/null | tail -n 2 | cut -c1-200 | tr '\n' ' ' || true)"
    return 1
  fi
  for line in "${lines[@]}"; do
    [[ -n $line ]] || continue
    IFS=$'\t' read -r sz p <<<"$line"
    sizes+=("$sz") paths+=("$p") incs+=("--include=$(glob_escape "$p")")
  done
  VF_CHECKED=${#paths[@]}
  ((VF_CHECKED > 0)) || return 0
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  VERIFY_DIR=$(mktemp -d "$RESTORE_ROOT/verify-$ts.XXXXXX")
  chmod 0700 -- "$VERIFY_DIR"
  restic_run "$acct" restore --verify latest --tag "files,$acct" --target "$VERIFY_DIR" "${incs[@]}" || rc=$?
  if ((rc != 0)); then
    VF_ERR="restic restore --verify failed: ${RESTIC_ERR:-rc $rc}"
    return 1
  fi
  for i in "${!paths[@]}"; do
    got=$(stat -c %s -- "$VERIFY_DIR${paths[i]}" 2>/dev/null || echo missing)
    if [[ $got == "${sizes[i]}" ]]; then VF_OK=$((VF_OK + 1)); fi
  done
  if ((VF_OK != VF_CHECKED)); then
    VF_ERR="$((VF_CHECKED - VF_OK)) of $VF_CHECKED restored files are missing or have the wrong size"
    return 1
  fi
}

# verify_db ACCOUNT DB : sets VD_EXP, VD_GOT; returns 1 with VD_ERR on failure.
VD_EXP=0 VD_GOT=0 VD_ERR=''
verify_db() {
  local acct=$1 db=$2 name
  VD_EXP=0 VD_GOT=0 VD_ERR=''
  printf -v name 'cwpvault_verify_%08x' $((RANDOM * 32768 + RANDOM))
  VERIFY_DB=$name
  if ! db_q "CREATE DATABASE \`$name\`"; then
    VD_ERR="cannot create the throwaway database"
    VERIFY_DB=''
    return 1
  fi
  : >"$RESTIC_STDERR_FILE"
  if ! restic_dump "$acct" dump --tag "db:$db" latest "/db/$db.sql" | strip_definer | mysql -- "$name"; then
    VD_ERR="the dump of $db did not import"
    verify_cleanup
    return 1
  fi
  VD_EXP=$(restic_dump "$acct" dump --tag "db:$db" latest "/db/$db.sql" | grep -a -c '^CREATE TABLE' || true)
  VD_GOT=$(db_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$name' AND table_type='BASE TABLE'") || VD_GOT=-1
  verify_cleanup
  [[ $VD_EXP =~ ^[0-9]+$ ]] || VD_EXP=-1
  if [[ $VD_EXP != "$VD_GOT" ]]; then
    VD_ERR="$db: $VD_GOT tables restored, $VD_EXP expected"
    return 1
  fi
}

# verify_obj OK ACCOUNT FINISHED CHECKED FILES_OK DBS_JSON DURATION ERROR : one JSON object, one line.
verify_obj() {
  printf '{"ok":%s,"account":%s,"finished":%s,"files_checked":%d,"files_ok":%d,"dbs":[%s],"duration_s":%d,"error":%s}' \
    "$1" "$(json_str "$2")" "$(json_str "$3")" "$4" "$5" "$6" "$7" "$(json_str "$8")"
}

# verify_account ACCOUNT : appends the result object to VR_OBJ, writes var/status/verify-<account>.json.
verify_account() {
  local acct=$1 t0 obj f ok=true rc=0 db dbj='' finished
  local -a errs=() dbs=()
  t0=$(date +%s)
  log_info "verify-restore $acct: start"
  restic_run "$acct" cat config || rc=$?
  VF_CHECKED=0 VF_OK=0
  if ((rc != 0)); then
    errs+=("repository not reachable (restic rc $rc)")
  else
    verify_files "$acct" || errs+=("files: $VF_ERR")
    verify_cleanup
    restic_run "$acct" snapshots --json --tag "db,$acct" || rc=$?
    if ((rc != 0)); then
      errs+=("cannot list database snapshots: ${RESTIC_ERR:-rc $rc}")
    else
      mapfile -t dbs < <(grep -o '"db:[A-Za-z0-9_]*"' <<<"$RESTIC_OUT" | tr -d '"' | sed 's/^db://' | sort -u || true)
      for db in "${dbs[@]}"; do
        valid_db "$acct" "$db" || continue
        rc=0
        verify_db "$acct" "$db" || rc=$?
        if ((rc != 0)); then errs+=("db: $VD_ERR"); fi
        if [[ -n $dbj ]]; then dbj+=,; fi
        dbj+=$(printf '{"db":%s,"tables_expected":%d,"tables_restored":%d,"ok":%s}' "$(json_str "$db")" \
          "$((VD_EXP < 0 ? 0 : VD_EXP))" "$((VD_GOT < 0 ? 0 : VD_GOT))" "$([[ $rc == 0 ]] && echo true || echo false)")
      done
    fi
  fi
  if ((${#errs[@]} > 0)); then ok=false; fi
  finished=$(log_ts)
  obj=$(verify_obj "$ok" "$acct" "$finished" "$VF_CHECKED" "$VF_OK" "$dbj" "$(($(date +%s) - t0))" "$(join_by '; ' "${errs[@]}")")
  f="$VAULT_STATUS/verify-$acct.json"
  printf '%s\n' "$obj" >"$f.tmp.$$"
  chmod 0640 -- "$f.tmp.$$"
  mv -f -- "$f.tmp.$$" "$f"
  VR_OBJ+=("$obj")
  if [[ $ok == true ]]; then
    log_info "verify-restore $acct: ok ($VF_OK of $VF_CHECKED files)"
    VR_TXT+=("$acct: OK, $VF_OK of $VF_CHECKED files and ${#dbs[@]} databases restored")
    RUN_OK=$((RUN_OK + 1))
  else
    log_error "verify-restore $acct: FAILED: $(join_by '; ' "${errs[@]}")"
    VR_TXT+=("$acct: FAILED: $(join_by '; ' "${errs[@]}")")
    RUN_FAILED=$((RUN_FAILED + 1))
    RUN_FAILED_NAMES+=("$acct")
    if [[ -z $RUN_ERROR ]]; then RUN_ERROR="$acct: $(join_by '; ' "${errs[@]}")"; fi
  fi
}

cmd_verify_restore() {
  local a fd o
  [[ -z $ARG_ACCOUNT || $ARG_ALL != 1 ]] || usage_err "use --account or --all, not both"
  targets_resolve 0
  ((${#TARGETS[@]} > 0)) || die 1 "no accounts to verify"
  if [[ -z $ARG_ACCOUNT && $ARG_ALL != 1 ]]; then TARGETS=("${TARGETS[RANDOM % ${#TARGETS[@]}]}"); fi
  lock_take "$VAULT_LOCK/vault.lock" s || die 3 "prune/check/unlock is running"
  mkdir -p -- "$RESTORE_ROOT"
  chmod 0700 -- "$RESTORE_ROOT"
  trap 'exit 143' TERM INT HUP # so cleanup() runs and the throwaway data goes away
  if ! restore_free_check "$RESTORE_ROOT"; then
    RUN_ERROR="not enough free disk space"
    return 1
  fi
  for a in "${TARGETS[@]}"; do
    if ! lock_take "$VAULT_LOCK/$a.lock" x; then
      if [[ -n $ARG_ACCOUNT ]]; then die 3 "$a is already being processed"; fi
      log_warn "$a is busy; skipped"
      RUN_SKIPPED=$((RUN_SKIPPED + 1))
      continue
    fi
    fd=$LOCK_LAST_FD
    verify_account "$a"
    lock_release "$fd"
  done
  if [[ $ARG_JSON == 1 ]]; then
    if [[ $ARG_ALL == 1 ]]; then printf '[%s]\n' "$(join_by , "${VR_OBJ[@]}")"; else printf '%s\n' "${VR_OBJ[0]:-null}"; fi
  elif [[ $ARG_QUIET != 1 ]]; then
    for o in "${VR_TXT[@]}"; do echo "$o"; done
  fi
  ((RUN_FAILED == 0)) || return 1
}

# verify_with_alert : failure alert (email/webhook) without the backup heartbeat.
verify_with_alert() {
  local rc=0
  cmd_verify_restore || rc=$?
  if ((rc != 0)); then notify_failure "$VAULT_CMD" "$rc"; fi
  return "$rc"
}

# status_last_verify : the "last_verify" object for status --json (newest finished across accounts), or null.
status_last_verify() {
  local f best='' bestf='' fin
  for f in "$VAULT_STATUS"/verify-*.json; do
    [[ -f $f ]] || continue
    fin=$(sed -n 's/^{"ok":[a-z]*,"account":"[^"]*","finished":"\([^"]*\)".*/\1/p' "$f" | head -n 1)
    [[ -n $fin ]] || continue
    if [[ $fin > $best ]]; then
      best=$fin
      bestf=$f
    fi
  done
  if [[ -z $bestf ]]; then
    printf 'null'
    return 0
  fi
  sed -n 's/^{"ok":\([a-z]*\),"account":"\([^"]*\)","finished":"\([^"]*\)".*/{"finished":"\3","ok":\1,"account":"\2"}/p' "$bestf" | head -n 1 | tr -d '\n'
}
