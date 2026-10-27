# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Safe restore: never into live data; files go to a fresh directory, databases into a new database.

RS_REFUSED=(/home /etc /root /usr /var/lib/mysql)

# restore_target_check DIR : sets RS_TARGET (canonical). Dies (2) on any unsafe target.
restore_target_check() {
  local t=$1 norm real r
  [[ $t == /* ]] || die 2 "--target must be an absolute path"
  [[ $t =~ [[:cntrl:]] ]] && die 2 "--target contains control characters"
  norm=$(printf '%s' "$t" | tr -s '/')
  norm=${norm%/}
  [[ -n $norm ]] || die 2 "--target must not be /"
  [[ "$norm/" == */../* ]] && die 2 "--target must not contain .."
  real=$(realpath -m -- "$norm") || die 2 "cannot resolve --target"
  [[ $real == "$norm" ]] || die 2 "--target contains a symlink or non-canonical component"
  for r in "${RS_REFUSED[@]}"; do
    if [[ $real == "$r" || $real == "$r"/* ]]; then die 2 "--target must not be under $r"; fi
  done
  if [[ -e $real ]]; then
    [[ -d $real && ! -L $real ]] || die 2 "--target exists and is not a directory"
    [[ -z $(ls -A -- "$real") ]] || die 2 "--target exists and is not empty"
  fi
  RS_TARGET=$real
}

restore_free_check() { # nearest existing ancestor
  local p=$1
  while [[ ! -e $p && $p != / ]]; do p=${p%/*}; [[ -n $p ]] || p=/; done
  check_free_gb "$p"
}

restore_audit() { # account snapshot what src target
  local line
  printf -v line '%s account=%s snapshot=%s what=%s src=%s target=%s' "$(log_ts)" "$1" "$2" "$3" "$4" "$5"
  printf '%s\n' "${line//[[:cntrl:]]/ }" >>"$VAULT_AUDIT"
}

# restore_finish OK TARGET FILES BYTES ERROR : writes the result file and prints it.
restore_finish() {
  local ok=$1 target=$2 files=$3 bytes=$4 err=$5 dur json f
  dur=$(($(date +%s) - RS_T0))
  json=$(printf '{"ok":%s,"job":%s,"target":%s,"files":%d,"bytes":%d,"duration_s":%d,"error":%s}' \
    "$ok" "$(json_str "$RS_JOB")" "$(json_str "$target")" "$files" "$bytes" "$dur" "$(json_str "$err")")
  f="$VAULT_STATUS/restore-$RS_JOB.json"
  printf '%s\n' "$json" >"$f"
  chmod 0640 -- "$f"
  if [[ $ARG_JSON == 1 ]]; then
    printf '%s\n' "$json"
  elif [[ $ok == true ]]; then
    echo "Restored to $target ($files files, $bytes bytes, ${dur}s)"
  else
    echo "Restore failed: $err" >&2
  fi
}

cmd_restore() {
  local acct=$ARG_ACCOUNT what=$ARG_WHAT snap=$ARG_SNAPSHOT inc='' rc=0 ts tag='' p
  local -a tagargs=() incs=() incargs=()
  [[ -n $acct ]] || usage_err "restore needs --account U"
  valid_account "$acct" || die 2 "invalid account name"
  valid_snapshot "$snap" || die 2 "invalid snapshot id"
  case $what in
    files) inc=$HOME_ROOT/$acct; tag="files,$acct" ;;
    mail) inc=$VMAIL_ROOT; tag="files,$acct" ;;
    meta) inc=/meta/account.json; tag="meta,$acct" ;;
    mailauth) inc=/meta/mailauth.json; tag="mailauth,$acct" ;;
    db) ;;
    *) usage_err "restore needs --what files|db|mail|meta|mailauth" ;;
  esac
  if [[ $what == db ]]; then
    [[ -n $ARG_DB && -n $ARG_TARGET_DB ]] || usage_err "db restore needs --db NAME and --target-db NAME"
    [[ -z $ARG_TARGET && ${#ARG_PATHS[@]} -eq 0 ]] || usage_err "db restore takes --target-db, not --target/--path"
    valid_db "$acct" "$ARG_DB" || die 2 "--db must be a database of $acct"
    valid_db "$acct" "$ARG_TARGET_DB" || die 2 "--target-db must start with ${acct}_"
    tag="db:$ARG_DB"
  else
    [[ -z $ARG_TARGET_DB && -z $ARG_DB ]] || usage_err "--db/--target-db are only for --what db"
    for p in "${ARG_PATHS[@]}"; do
      valid_restore_path "$p" || die 2 "invalid --path"
      case $what in
        files) [[ $p == "$inc" || $p == "$inc"/* ]] || die 2 "--path must be inside $inc" ;;
        mail) [[ $p == "$inc"/* ]] || die 2 "--path must be inside $inc" ;;
        *) die 2 "--path is only for --what files|mail" ;;
      esac
      incs+=("$p")
    done
    if ((${#incs[@]} == 0)); then incs=("$inc"); fi
    for p in "${incs[@]}"; do incargs+=("--include=$(glob_escape "$p")"); done
    inc=$(join_by ', ' "${incs[@]}")
  fi
  if [[ $snap == latest ]]; then tagargs=(--tag "$tag"); fi

  ts=$(date -u +%Y%m%dT%H%M%SZ)
  RS_JOB="$ts-$acct"
  RS_T0=$(date +%s)
  if [[ $what != db ]]; then
    if [[ -n $ARG_TARGET ]]; then
      restore_target_check "$ARG_TARGET"
    else
      RS_TARGET="$RESTORE_ROOT/$RS_JOB"
    fi
  else
    RS_TARGET=$ARG_TARGET_DB
  fi

  if [[ $ARG_DRY == 1 ]]; then
    if [[ $ARG_JSON == 1 ]]; then
      printf '{"ok":true,"job":"dry-run","target":%s,"files":0,"bytes":0,"duration_s":0,"error":""}\n' "$(json_str "$RS_TARGET")"
    else
      echo "Would restore $what of $acct (snapshot $snap) ${inc:+path $inc }to $RS_TARGET"
    fi
    return 0
  fi

  lock_take "$VAULT_LOCK/vault.lock" s || die 3 "prune/check/unlock is running"
  lock_take "$VAULT_LOCK/$acct.lock" x || die 3 "$acct is already being processed"
  repo_ensure_existing "$acct"

  if [[ $what == db ]]; then
    restore_db "$acct" "$snap"
    return
  fi

  if [[ -z $ARG_TARGET ]]; then
    mkdir -p -- "$RESTORE_ROOT"
    chmod 0700 -- "$RESTORE_ROOT"
  fi
  restore_free_check "$RS_TARGET" || die 1 "not enough free space for the restore"
  if [[ ! -d $RS_TARGET ]]; then mkdir -p -- "$RS_TARGET"; fi
  chmod 0700 -- "$RS_TARGET"

  restic_run "$acct" restore "$snap" "${tagargs[@]}" --target "$RS_TARGET" "${incargs[@]}" || rc=$?
  if ((rc != 0)); then
    restore_audit "$acct" "$snap" "$what" "$inc" "$RS_TARGET (failed)"
    restore_finish false "$RS_TARGET" 0 0 "restic restore failed: ${RESTIC_ERR:-rc $rc}"
    return 1
  fi
  chmod -R ug-s -- "$RS_TARGET"
  restore_audit "$acct" "$snap" "$what" "$inc" "$RS_TARGET"
  local nf nb
  nf=$(find "$RS_TARGET" -type f | wc -l)
  nb=$(du -sb -- "$RS_TARGET" | cut -f1)
  restore_finish true "$RS_TARGET" "$nf" "$nb" ""
}

# The repository must already exist; a restore never creates one.
repo_ensure_existing() {
  local rc=0
  restic_run "$1" cat config || rc=$?
  if ((rc == 10)); then die 2 "no backup repository for $1"; fi
  if ((rc != 0)); then die 4 "repository for $1 is not reachable (restic rc $rc)"; fi
}

restore_db() {
  local acct=$1 snap=$2 db=$ARG_DB target=$ARG_TARGET_DB exists tables bytes
  local -a tagargs=()
  if [[ $snap == latest ]]; then tagargs=(--tag "db:$db"); fi
  exists=$(db_q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$target'") || die 1 "cannot query MySQL"
  [[ $exists == 0 ]] || die 2 "database $target already exists; choose a new name"
  db_q "CREATE DATABASE \`$target\`" || die 1 "cannot create database $target"
  if restic_dump "$acct" dump "${tagargs[@]}" "$snap" "/db/$db.sql" | strip_definer | mysql -- "$target"; then
    restore_audit "$acct" "$snap" db "db/$db.sql" "db:$target"
    tables=$(db_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$target'" || echo 0)
    bytes=$(db_q "SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema='$target'" || echo 0)
    [[ $tables =~ ^[0-9]+$ ]] || tables=0
    [[ $bytes =~ ^[0-9]+$ ]] || bytes=0
    restore_finish true "$target" "$tables" "$bytes" ""
  else
    restore_audit "$acct" "$snap" db "db/$db.sql" "db:$target (failed)"
    restore_finish false "$target" 0 0 "import failed; database $target was left in place, drop it before retrying"
    return 1
  fi
}
