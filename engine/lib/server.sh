# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# _server repository: DNS zones, certificates, mail/web config and server-wide DB dumps.

RUN_STORAGE_DOWN=0

# bk_dump_fixed DB : server-wide databases (fixed names, no account prefix).
bk_dump_fixed() {
  timeout "$ACCOUNT_TIMEOUT" mysqldump --single-transaction --quick --routines --events --triggers --hex-blob "$1" \
    2>>"$VAULT_LOG_FILE" | strip_definer
}

backup_server() {
  local t0 started p rc=0 db
  local -a paths=()
  bk_reset
  t0=$(date +%s)
  started=$(log_ts)
  log_info "backup _server: start"
  if ! repo_ensure _server; then
    BK_ERRS+=("repository not reachable (restic rc $RESTIC_FAIL_RC)")
    if ((RESTIC_FAIL_RC != 12)); then RUN_STORAGE_DOWN=1; fi
  else
    if ! others_alive; then restic_run _server unlock || log_warn "unlock failed for _server"; fi
    shopt -s nullglob
    for p in /var/named/*.db /etc/pki/tls/certs /etc/pki/tls/private /usr/local/cwp/.conf /etc/postfix /etc/dovecot; do
      if [[ -e $p ]]; then paths+=("$p"); fi
    done
    shopt -u nullglob
    if ((${#paths[@]} > 0)); then
      bk_files _server _server "${paths[@]}" || true
    else
      BK_ERRS+=("no server files found")
    fi
    for db in root_cwp postfix; do
      bk_stream _server "db/$db.sql" "db,_server,db:$db" "db:$db" bk_dump_fixed "$db" || true
    done
  fi
  local result=ok err=''
  if ((${#BK_ERRS[@]} > 0)); then
    result=failed
    err=$(join_by '; ' "${BK_ERRS[@]}")
    rc=1
  fi
  status_write _server "$started" "$t0" "$result" "$BK_NEW" "$BK_CHG" "$BK_BYTES" "$err" "${BK_SNAPS[@]}"
  if ((rc != 0)); then
    log_error "backup _server: failed: $err"
    if [[ -z $RUN_ERROR ]]; then RUN_ERROR="_server: $err"; fi
  else
    log_info "backup _server: ok"
  fi
  return "$rc"
}
