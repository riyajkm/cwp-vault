# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Backup: files+mail in one restic call, each DB and the metadata streamed.

DEFAULT_EXCLUDES=('*/cache/*' '*/.cache/*' '*/tmp/*' '*/.trash/*' '*/error_log' '*/core.[0-9]*')

BK_SNAPS=()
BK_ERRS=()
BK_NEW=0
BK_CHG=0
BK_BYTES=0

bk_reset() {
  BK_SNAPS=()
  BK_ERRS=()
  BK_NEW=0
  BK_CHG=0
  BK_BYTES=0
}

bk_excludes() {
  local p
  local -a ex=()
  IFS=' ' read -ra ex <<<"$EXCLUDES" || true
  for p in "${DEFAULT_EXCLUDES[@]}" "${ex[@]}"; do printf '%s\n' "--exclude=$p"; done
}

# bk_files REPO LABEL PATH... : one restic backup call; tag files,<label>
bk_files() {
  local repo=$1 label=$2 rc=0
  shift 2
  local -a args=(backup --json --one-file-system --tag "files,$label")
  local x
  while IFS= read -r x; do args+=("$x"); done < <(bk_excludes)
  RESTIC_ACCEPT_3=1 restic_run "$repo" "${args[@]}" -- "$@" || rc=$?
  if ((rc != 0)); then
    BK_ERRS+=("file backup failed (${RESTIC_ERR:-rc $rc})")
    return 1
  fi
  restic_summary "$RESTIC_OUT"
  BK_SNAPS+=("files:$SUM_ID")
  BK_NEW=$((BK_NEW + SUM_NEW))
  BK_CHG=$((BK_CHG + SUM_CHG))
  BK_BYTES=$((BK_BYTES + SUM_ADD))
}

# bk_stream REPO FILENAME TAGS LABEL producer args... : producer's stdout becomes a snapshot.
# A failed producer or upload => failed, and any snapshot that was created is forgotten.
bk_stream() {
  local repo=$1 fname=$2 tags=$3 label=$4 out='' rc=0
  shift 4
  out=$("$@" | restic_stream "$repo" backup --json --stdin --stdin-filename "$fname" --tag "$tags") || rc=$?
  restic_summary "$out"
  if ((rc != 0)); then
    BK_ERRS+=("$label failed")
    if [[ -n $SUM_ID ]]; then
      restic_run "$repo" forget "$SUM_ID" || log_warn "could not forget incomplete snapshot for $label"
    fi
    return 1
  fi
  if [[ -z $SUM_ID ]]; then
    BK_ERRS+=("$label: no snapshot id returned")
    return 1
  fi
  BK_SNAPS+=("$label:$SUM_ID")
  BK_BYTES=$((BK_BYTES + SUM_ADD))
}

# bk_dump_db DB : consistent dump with DEFINER clauses removed.
bk_dump_db() {
  local db=$1 myisam mode=--single-transaction
  myisam=$(db_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db' AND engine='MyISAM'") || return 1
  # shortcut: MyISAM is not transactional, so lock tables instead (blocks writes during the dump).
  if [[ $myisam =~ ^[0-9]+$ ]] && ((myisam > 0)); then mode=--lock-tables; fi
  timeout "$ACCOUNT_TIMEOUT" mysqldump "$mode" --quick --routines --events --triggers --hex-blob "$db" \
    2>>"$VAULT_LOG_FILE" | strip_definer
}

# tsv_to_json : mysql --batch table (header row) on stdin -> JSON array of objects.
tsv_to_json() {
  LC_ALL=C awk '
    function unesc(s,  o,i,c,d) { o=""; for (i=1;i<=length(s);i++) { c=substr(s,i,1)
      if (c=="\\" && i<length(s)) { d=substr(s,++i,1); if (d=="t") o=o "\t"; else if (d=="n") o=o "\n"; else if (d=="0") o=o; else o=o d } else o=o c }
      return o }
    function esc(s,  o,i,c) { o=""; for (i=1;i<=length(s);i++) { c=substr(s,i,1)
      if (c=="\\") o=o "\\\\"; else if (c=="\"") o=o "\\\""; else if (c=="\n") o=o "\\n"; else if (c=="\t") o=o "\\t"
      else if (c=="\r") o=o "\\r"; else if (c<" ") o=o " "; else o=o c }
      return o }
    BEGIN { FS="\t"; n=0; printf "[" }
    NR==1 { nh=NF; for (i=1;i<=NF;i++) h[i]=$i; next }
    { printf "%s\n    {", (n++ ? "," : ""); for (i=1;i<=nh;i++) { printf "%s\"%s\": ", (i>1 ? ", " : ""), esc(h[i])
        if ($i=="NULL") printf "null"; else printf "\"%s\"", esc(unesc($i)) } printf "}" }
    END { printf "%s]", (n ? "\n  " : "") }'
}

bk_in_list_sql() { # domains... -> 'a','b'
  local d out='' first=1
  for d in "$@"; do
    if ((first)); then first=0; else out+=,; fi
    out+="'$d'"
  done
  printf '%s' "${out:-''}"
}

# bk_account_json ACCOUNT : no password hashes (those live in mailauth.json).
bk_account_json() {
  local u=$1 doms dom_in pk
  local -a dl=()
  doms=$(acct_domains "$u") || return 1
  while IFS= read -r d; do
    if [[ -n $d ]]; then dl+=("$d"); fi
  done <<<"$doms"
  dom_in=$(bk_in_list_sql "${dl[@]}")
  printf '{\n  "account": %s,\n  "generated": %s,\n' "$(json_str "$u")" "$(json_str "$(log_ts)")"
  printf '  "user": '
  db_tbl "SELECT username, domain, ip_address, email, setup_date, package, backup, reseller FROM root_cwp.user WHERE username='$u'" | tsv_to_json || return 1
  printf ',\n  "domains": '
  db_tbl "SELECT domain, user, path FROM root_cwp.domains WHERE user='$u'" | tsv_to_json || return 1
  printf ',\n  "subdomains": '
  db_tbl "SELECT subdomain, domain, user, path FROM root_cwp.subdomains WHERE user='$u'" | tsv_to_json || return 1
  printf ',\n  "package": '
  if pk=$(db_tbl "SELECT p.* FROM root_cwp.packages p WHERE p.package_name=(SELECT package FROM root_cwp.user WHERE username='$u')" 2>/dev/null); then
    printf '%s\n' "$pk" | tsv_to_json || return 1
  else
    log_warn "could not read package row for $u"
    printf '[]'
  fi
  printf ',\n  "postfix_domains": '
  db_tbl "SELECT * FROM postfix.domain WHERE domain IN ($dom_in)" | tsv_to_json || return 1
  printf '\n}\n'
}

# bk_mailauth_json ACCOUNT : admin-only (contains mailbox password hashes).
bk_mailauth_json() {
  local u=$1 doms dom_in d
  local -a dl=()
  doms=$(acct_domains "$u") || return 1
  while IFS= read -r d; do
    if [[ -n $d ]]; then dl+=("$d"); fi
  done <<<"$doms"
  dom_in=$(bk_in_list_sql "${dl[@]}")
  printf '{\n  "account": %s,\n  "mailboxes": ' "$(json_str "$u")"
  db_tbl "SELECT * FROM postfix.mailbox WHERE domain IN ($dom_in)" | tsv_to_json || return 1
  printf ',\n  "aliases": '
  db_tbl "SELECT * FROM postfix.alias WHERE domain IN ($dom_in)" | tsv_to_json || return 1
  printf '\n}\n'
}

# backup_account ACCOUNT : returns 0 ok, 1 failed. Always writes a status file.
backup_account() {
  local acct=$1 t0 started db d rc=0
  local -a paths=() dbs=() mails=()
  bk_reset
  t0=$(date +%s)
  started=$(log_ts)
  log_info "backup $acct: start"

  if ! repo_ensure "$acct"; then
    BK_ERRS+=("repository not reachable (restic rc $RESTIC_FAIL_RC)")
    if ((RESTIC_FAIL_RC != 12)); then RUN_STORAGE_DOWN=1; fi
  else
    if ! others_alive; then restic_run "$acct" unlock || log_warn "unlock failed for $acct"; fi

    if [[ -d $HOME_ROOT/$acct ]]; then paths+=("$HOME_ROOT/$acct"); fi
    if [[ $BACKUP_MAIL == yes ]]; then
      mapfile -t mails < <(acct_maildirs "$acct") || BK_ERRS+=("mail discovery failed")
      for d in "${mails[@]}"; do paths+=("$d"); done
    fi
    if ((${#paths[@]} > 0)); then
      bk_files "$acct" "$acct" "${paths[@]}" || true
    else
      BK_ERRS+=("no home directory found")
    fi

    if [[ $BACKUP_DATABASES == yes ]]; then
      mapfile -t dbs < <(acct_dbs "$acct") || BK_ERRS+=("database discovery failed")
      for db in "${dbs[@]}"; do
        bk_stream "$acct" "db/$db.sql" "db,$acct,db:$db" "db:$db" bk_dump_db "$db" || true
      done
    fi

    bk_stream "$acct" meta/account.json "meta,$acct" meta bk_account_json "$acct" || true
    if [[ $BACKUP_MAIL == yes ]]; then
      bk_stream "$acct" meta/mailauth.json "mailauth,$acct" mailauth bk_mailauth_json "$acct" || true
    fi
  fi

  local result=ok err=''
  if ((${#BK_ERRS[@]} > 0)); then
    result=failed
    err=$(join_by '; ' "${BK_ERRS[@]}")
    rc=1
  fi
  status_write "$acct" "$started" "$t0" "$result" "$BK_NEW" "$BK_CHG" "$BK_BYTES" "$err" "${BK_SNAPS[@]}"
  if ((rc != 0)); then
    log_error "backup $acct: failed: $err"
    if [[ -z $RUN_ERROR ]]; then RUN_ERROR="$acct: $err"; fi
  else
    log_info "backup $acct: ok"
  fi
  return "$rc"
}

# targets_resolve INCLUDE_SERVER(0|1) : fills TARGETS from --account / --all.
declare -a TARGETS=()
targets_resolve() {
  local inc=$1 all
  TARGETS=()
  if [[ -n $ARG_ACCOUNT ]]; then
    if [[ $ARG_ACCOUNT == _server ]] && [[ $inc == 1 ]]; then
      TARGETS=(_server)
      return 0
    fi
    valid_account "$ARG_ACCOUNT" || die 2 "invalid account name"
    all=$(acct_discover nofilter) || die 1 "cannot read account list from MySQL"
    printf '%s\n' "$all" | grep -qxF -- "$ARG_ACCOUNT" || die 2 "unknown account $ARG_ACCOUNT"
    TARGETS=("$ARG_ACCOUNT")
  else
    all=$(acct_discover) || die 1 "cannot read account list from MySQL"
    mapfile -t TARGETS <<<"$all"
    if [[ -z ${TARGETS[0]:-} ]]; then TARGETS=(); fi
    if [[ $inc == 1 && $BACKUP_SERVER == yes ]]; then TARGETS+=(_server); fi
  fi
}

cmd_backup() {
  local a fd rc=0
  [[ -n $ARG_ACCOUNT || $ARG_ALL == 1 ]] || usage_err "backup needs --account U or --all"
  [[ -z $ARG_ACCOUNT || $ARG_ALL != 1 ]] || usage_err "use --account or --all, not both"
  targets_resolve 1
  if [[ $ARG_DRY == 1 ]]; then
    for a in "${TARGETS[@]}"; do backup_plan "$a"; done
    return 0
  fi
  lock_take "$VAULT_LOCK/vault.lock" s || die 3 "prune/check/unlock is running"
  if [[ $ARG_ALL == 1 ]]; then
    lock_take "$VAULT_LOCK/all.lock" x || die 3 "another --all run is active"
  fi
  if ! check_free_gb "$VAULT_CACHE"; then
    RUN_ERROR="not enough free disk space"
    return 1
  fi
  for a in "${TARGETS[@]}"; do
    if ! lock_take "$VAULT_LOCK/$a.lock" x; then
      if [[ -n $ARG_ACCOUNT ]]; then die 3 "$a is already being processed"; fi
      log_warn "$a is busy; skipped"
      status_write "$a" "$(log_ts)" "$(date +%s)" skipped 0 0 0 "another vault process holds the lock"
      RUN_SKIPPED=$((RUN_SKIPPED + 1))
      continue
    fi
    fd=$LOCK_LAST_FD
    if [[ $a == _server ]]; then backup_server && rc=0 || rc=1; else backup_account "$a" && rc=0 || rc=1; fi
    lock_release "$fd"
    if ((rc == 0)); then
      RUN_OK=$((RUN_OK + 1))
    else
      RUN_FAILED=$((RUN_FAILED + 1))
      RUN_FAILED_NAMES+=("$a")
    fi
  done
  if ((RUN_FAILED > 0)); then
    if [[ ${RUN_STORAGE_DOWN:-0} == 1 && $RUN_OK == 0 ]]; then return 4; fi
    return 1
  fi
  return 0
}

backup_plan() {
  local a=$1 dbs doms
  if [[ $a == _server ]]; then
    echo "_server: server files, root_cwp and postfix dumps"
    return 0
  fi
  doms=$(acct_domains "$a" | tr '\n' ' ')
  dbs=$(acct_dbs "$a" | tr '\n' ' ')
  echo "$a: home $HOME_ROOT/$a; mail domains: ${doms:-none}; databases: ${dbs:-none}"
}
