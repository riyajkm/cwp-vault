# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Safe restore: by default never into live data (files to a fresh directory, databases into a new database).
# --in-place restores into the live account, only after a fresh safety backup and with --confirm <account>.

RS_MB_DOMAIN='' RS_MB_PATH='' RS_APPLY_ERR=''
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

# restore_dest_check ROOT DEST : DEST is ROOT or below it and no component from ROOT down is a symlink.
restore_dest_check() {
  local root=$1 dest=$2 cur part
  local -a parts=()
  [[ $dest == "$root" || $dest == "$root"/* ]] || return 1
  [[ -d $root && ! -L $root ]] || return 1
  cur=$root
  IFS=/ read -ra parts <<<"${dest#"$root"}" || true
  for part in "${parts[@]}"; do
    [[ -n $part ]] || continue
    cur+=/$part
    [[ ! -L $cur ]] || return 1
  done
}

# restore_mailbox_check ACCOUNT user@domain : sets RS_MB_DOMAIN and RS_MB_PATH; dies (2) unless valid and owned.
restore_mailbox_check() {
  local acct=$1 mb=$2 lp dom doms
  [[ $mb =~ ^([A-Za-z0-9][A-Za-z0-9._+-]{0,63})@([A-Za-z0-9.-]{3,253})$ ]] || die 2 "invalid --mailbox"
  lp=${BASH_REMATCH[1]}
  dom=${BASH_REMATCH[2],,}
  valid_domain "$dom" || die 2 "invalid --mailbox domain"
  doms=$(acct_domains "$acct") || die 1 "cannot list domains"
  grep -qxF -- "$dom" <<<"$doms" || die 2 "domain $dom does not belong to $acct"
  RS_MB_DOMAIN=$dom
  RS_MB_PATH=$VMAIL_ROOT/$dom/$lp
}

# restore_safety_backup ACCOUNT : a fresh full backup; fills RS_SAFETY with its snapshot ids. Dies (1) if it fails.
restore_safety_backup() {
  local f=$VAULT_STATUS/$1.json ids
  restore_audit "$1" "$ARG_SNAPSHOT" "$RS_WHAT" in-place "safety backup started"
  if ! "$VAULT_SELF" backup --account "$1" --quiet </dev/null >/dev/null 2>&1 || [[ $(status_get "$f" result) != ok ]]; then
    restore_audit "$1" "$ARG_SNAPSHOT" "$RS_WHAT" in-place "safety backup FAILED, nothing restored"
    die 1 "the safety backup of $1 failed; nothing was restored"
  fi
  ids=$(grep '^  "snapshots"' "$f" | grep -o '[0-9a-f]\{8,64\}' || true)
  mapfile -t RS_SAFETY <<<"$ids"
  if [[ -z ${RS_SAFETY[0]:-} ]]; then RS_SAFETY=(); fi
  restore_audit "$1" "$ARG_SNAPSHOT" "$RS_WHAT" in-place "safety snapshots: $(join_by , "${RS_SAFETY[@]}")"
}

# restore_apply ACCOUNT PATH... : copy staged paths over the live ones (in place). Sets RS_APPLY_ERR on failure.
restore_apply() {
  local acct=$1 p src root owner
  local -a rs=(rsync -a --no-specials --no-devices --safe-links)
  shift
  if [[ $RS_WHAT == files ]]; then
    root=$HOME_ROOT/$acct
    rs=(runuser -u "$acct" -- "${rs[@]}") # the account's own rights bound what the copy can touch
  else
    root=$VMAIL_ROOT/$RS_MB_DOMAIN
    owner=$(stat -c %U -- "$root") || { RS_APPLY_ERR="cannot read the owner of $root"; return 1; }
    [[ $owner != UNKNOWN ]] || { RS_APPLY_ERR="the owner of $root has no user name"; return 1; }
    chown -- "$owner" "$RS_TARGET" 2>/dev/null || log_warn "cannot hand the staging folder to $owner"
    rs=(runuser -u "$owner" -- "${rs[@]}") # the domain owner's rights bound the copy, as for files
  fi
  for p in "$@"; do
    if ! restore_dest_check "$root" "$p"; then RS_APPLY_ERR="refused: $p is outside $root or has a symlink on its path"; return 1; fi
    src=$RS_TARGET$p
    [[ -e $src ]] || { RS_APPLY_ERR="$p is not in the snapshot"; return 1; }
    if [[ -d $src ]]; then
      "${rs[@]}" -- "$src/" "$p/" || { RS_APPLY_ERR="copy of $p failed"; return 1; }
    else
      "${rs[@]}" -- "$src" "$p" || { RS_APPLY_ERR="copy of $p failed"; return 1; }
    fi
  done
}

# restore_finish OK TARGET FILES BYTES ERROR : writes the result file and prints it.
restore_finish() {
  local ok=$1 target=$2 files=$3 bytes=$4 err=$5 dur json f x='' state=failed pct=0 s ids=''
  dur=$(($(date +%s) - RS_T0))
  RS_FINISHED=1
  json=$(printf '{"ok":%s,"job":%s,"target":%s,"files":%d,"bytes":%d,"duration_s":%d,"error":%s}' \
    "$ok" "$(json_str "$RS_JOB")" "$(json_str "$target")" "$files" "$bytes" "$dur" "$(json_str "$err")")
  if [[ $ok == true ]]; then
    state='done'
    pct=100
  fi
  if ((RS_WORKER)); then
    x+=$(printf ',"state":"%s","account":%s,"what":%s,"percent":%d,"kind":"restore"' "$state" "$(json_str "$RS_ACCT")" "$(json_str "$RS_WHAT")" "$pct")
  fi
  if ((RS_INPLACE)); then
    for s in "${RS_SAFETY[@]}"; do ids+="${ids:+,}$(json_str "$s")"; done
    x+=",\"in_place\":true,\"safety_snapshots\":[$ids]"
  fi
  json="${json%\}}${x}}"
  f=$(job_file "$RS_JOB")
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
  local acct=$ARG_ACCOUNT what=$ARG_WHAT snap=$ARG_SNAPSHOT inc='' rc=0 ts tag='' p root nf nb live
  local -a tagargs=() incs=() incargs=() rcmd=()
  [[ -n $acct ]] || usage_err "restore needs --account U"
  valid_account "$acct" || die 2 "invalid account name"
  valid_snapshot "$snap" || die 2 "invalid snapshot id"
  # shellcheck disable=SC2153 # ARG_INPLACE is set by bin/vault
  RS_ACCT=$acct RS_WHAT=$what RS_INPLACE=$ARG_INPLACE RS_WORKER=0
  if [[ -n $ARG_JOB ]]; then
    valid_job_id "$ARG_JOB" && [[ $ARG_JOB == *-"$acct" && -f $(job_file "$ARG_JOB") ]] || die 2 "invalid --job"
    RS_WORKER=1
  fi
  case $what in
    files) inc=$HOME_ROOT/$acct; tag="files,$acct" ;;
    mail) inc=$VMAIL_ROOT; tag="files,$acct" ;;
    meta) inc=/meta/account.json; tag="meta,$acct" ;;
    mailauth) inc=/meta/mailauth.json; tag="mailauth,$acct" ;;
    db) ;;
    *) usage_err "restore needs --what files|db|mail|meta|mailauth" ;;
  esac
  if ((RS_INPLACE)); then
    case $what in files | db | mail) ;; *) usage_err "--in-place works for files, db and mail only" ;; esac
    [[ $ARG_CONFIRM == "$acct" ]] || die 2 "--in-place needs --confirm $acct (the account name, typed out)"
    [[ $snap != latest ]] || usage_err "--in-place needs an explicit --snapshot ID"
    [[ -z $ARG_TARGET && -z $ARG_TARGET_DB ]] || usage_err "--in-place takes no --target/--target-db"
  else
    [[ -z $ARG_CONFIRM ]] || usage_err "--confirm is only for --in-place"
  fi
  [[ -z $ARG_MAILBOX || $what == mail ]] || usage_err "--mailbox is only for --what mail"
  if [[ $what == db ]]; then
    [[ -z $ARG_TARGET && ${#ARG_PATHS[@]} -eq 0 ]] || usage_err "db restore takes --target-db, not --target/--path"
    valid_db "$acct" "$ARG_DB" || die 2 "--db must be a database of $acct"
    if ((RS_INPLACE)); then
      live=$(acct_dbs "$acct") || die 1 "cannot list databases"
      grep -qxF -- "$ARG_DB" <<<"$live" || die 2 "$ARG_DB is not a live database of $acct"
    else
      [[ -n $ARG_TARGET_DB ]] || usage_err "db restore needs --db NAME and --target-db NAME"
      valid_db "$acct" "$ARG_TARGET_DB" || die 2 "--target-db must start with ${acct}_"
    fi
    tag="db:$ARG_DB"
  else
    [[ -z $ARG_TARGET_DB && -z $ARG_DB ]] || usage_err "--db/--target-db are only for --what db"
    if [[ -n $ARG_MAILBOX ]]; then
      [[ ${#ARG_PATHS[@]} -eq 0 ]] || usage_err "--mailbox replaces --path"
      restore_mailbox_check "$acct" "$ARG_MAILBOX"
      ARG_PATHS=("$RS_MB_PATH")
    elif ((RS_INPLACE)) && [[ $what == mail ]]; then
      usage_err "an in-place mail restore needs --mailbox user@domain"
    fi
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
    if ((RS_INPLACE)); then
      root=$HOME_ROOT/$acct
      if [[ $what == mail ]]; then root=$VMAIL_ROOT/$RS_MB_DOMAIN; fi
      for p in "${incs[@]}"; do
        restore_dest_check "$root" "$p" || die 2 "refused: $p is outside $root or has a symlink on its path"
      done
    fi
    for p in "${incs[@]}"; do incargs+=("--include=$(glob_escape "$p")"); done
    inc=$(join_by ', ' "${incs[@]}")
  fi
  if [[ $snap == latest ]]; then tagargs=(--tag "$tag"); fi

  ts=$(date -u +%Y%m%dT%H%M%SZ)
  RS_JOB=${ARG_JOB:-$ts-$acct}
  RS_T0=$(date +%s)
  if [[ $what != db ]]; then
    if [[ -n $ARG_TARGET ]]; then
      restore_target_check "$ARG_TARGET"
    else
      RS_TARGET="$RESTORE_ROOT/$RS_JOB"
    fi
  else
    RS_TARGET=${ARG_TARGET_DB:-$ARG_DB}
  fi

  if [[ $ARG_DRY == 1 ]]; then
    if [[ $ARG_JSON == 1 ]]; then
      printf '{"ok":true,"job":"dry-run","target":%s,"files":0,"bytes":0,"duration_s":0,"error":""}\n' "$(json_str "$RS_TARGET")"
    elif ((RS_INPLACE)); then
      echo "Would back up $acct, then restore $what of $acct (snapshot $snap) ${inc:+path $inc }into the live account"
    else
      echo "Would restore $what of $acct (snapshot $snap) ${inc:+path $inc }to $RS_TARGET"
    fi
    return 0
  fi

  if ((ARG_DETACH && !RS_WORKER)); then
    job_spawn
    return 0
  fi
  if ((RS_WORKER)); then
    RESTIC_PROGRESS_FPS=0.5
    job_update running 0 0
  fi
  if ((RS_INPLACE)); then
    restore_audit "$acct" "$snap" "$what" "$inc" "in-place restore requested"
    restore_safety_backup "$acct"
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
    if ((RS_INPLACE)); then chmod 0711 -- "$RESTORE_ROOT"; fi # the account must reach its own staging folder
  fi
  restore_free_check "$RS_TARGET" || die 1 "not enough free space for the restore"
  if [[ ! -d $RS_TARGET ]]; then mkdir -p -- "$RS_TARGET"; fi
  chmod 0700 -- "$RS_TARGET"
  if ((RS_INPLACE)) && [[ $what == files ]]; then
    chown -- "$acct" "$RS_TARGET" 2>/dev/null || log_warn "cannot hand the staging folder to $acct"
  fi

  rcmd=("$acct" restore "$snap" "${tagargs[@]}" --target "$RS_TARGET" "${incargs[@]}")
  if ((RS_WORKER)); then
    (set -o pipefail; _restic_once "${rcmd[@]}" --json </dev/null | job_progress) || rc=$?
    RESTIC_ERR=$(restic_scrub <"$RESTIC_STDERR_FILE" 2>/dev/null | tail -n 5 | cut -c1-300 || true)
  else
    restic_run "${rcmd[@]}" || rc=$?
  fi
  if ((rc != 0)); then
    restore_audit "$acct" "$snap" "$what" "$inc" "$RS_TARGET (failed)"
    restore_finish false "$RS_TARGET" 0 0 "restic restore failed: ${RESTIC_ERR:-rc $rc}"
    return 1
  fi
  chmod -R ug-s -- "$RS_TARGET"
  nf=$(find "$RS_TARGET" -type f | wc -l)
  nb=$(du -sb -- "$RS_TARGET" | cut -f1)

  if ((RS_INPLACE)); then
    if ! restore_apply "$acct" "${incs[@]}"; then
      restore_audit "$acct" "$snap" "$what" "$inc" "in-place (failed: $RS_APPLY_ERR) safety=$(join_by , "${RS_SAFETY[@]}")"
      restore_finish false "$inc" 0 0 "$RS_APPLY_ERR; the staged copy is kept in $RS_TARGET"
      return 1
    fi
    restore_audit "$acct" "$snap" "$what" "$inc" "in-place safety=$(join_by , "${RS_SAFETY[@]}")"
    rm -rf -- "${RS_TARGET:?}"
    restore_finish true "$inc" "$nf" "$nb" ""
    return 0
  fi
  restore_audit "$acct" "$snap" "$what" "$inc" "$RS_TARGET"
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
  local acct=$1 snap=$2 db=$ARG_DB target=$RS_TARGET exists tables bytes safety=''
  local -a tagargs=()
  if [[ $snap == latest ]]; then tagargs=(--tag "db:$db"); fi
  if ((RS_INPLACE)); then
    safety=" in-place safety=$(join_by , "${RS_SAFETY[@]}")"
  else
    exists=$(db_q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$target'") || die 1 "cannot query MySQL"
    [[ $exists == 0 ]] || die 2 "database $target already exists; choose a new name"
    db_q "CREATE DATABASE \`$target\`" || die 1 "cannot create database $target"
  fi
  # the dump starts each table with DROP TABLE IF EXISTS, so in place it overwrites the live tables
  if restic_dump "$acct" dump "${tagargs[@]}" "$snap" "/db/$db.sql" | strip_definer | mysql -- "$target"; then
    restore_audit "$acct" "$snap" db "db/$db.sql" "db:$target$safety"
    tables=$(db_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$target'" || echo 0)
    bytes=$(db_q "SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema='$target'" || echo 0)
    [[ $tables =~ ^[0-9]+$ ]] || tables=0
    [[ $bytes =~ ^[0-9]+$ ]] || bytes=0
    restore_finish true "$target" "$tables" "$bytes" ""
  else
    restore_audit "$acct" "$snap" db "db/$db.sql" "db:$target (failed)$safety"
    if ((RS_INPLACE)); then
      restore_finish false "$target" 0 0 "import failed; $target may be partly restored, the safety snapshot has the previous state"
    else
      restore_finish false "$target" 0 0 "import failed; database $target was left in place, drop it before retrying"
    fi
    return 1
  fi
}
