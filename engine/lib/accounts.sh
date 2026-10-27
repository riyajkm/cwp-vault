# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Validators and CWP account discovery. All SQL values are validated before use.

valid_account() { [[ ${1:-} =~ ^[a-z][a-z0-9_]{0,31}$ ]]; }
valid_domain() {
  [[ ${1:-} =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#1} -le 253 ]]
}
# valid_db ACCOUNT DB : database must start with "<account>_".
valid_db() { valid_account "${1:-}" && [[ ${2:-} =~ ^${1}_[A-Za-z0-9_]{1,56}$ ]]; }
valid_snapshot() { [[ ${1:-} =~ ^([0-9a-f]{8,64}|latest)$ ]]; }
valid_repo_name() { [[ ${1:-} == _server ]] || valid_account "${1:-}"; }

# valid_restore_path P : absolute, no "..", no control chars.
valid_restore_path() {
  local p=${1:-}
  [[ $p == /* && ${#p} -le 1024 ]] || return 1
  [[ $p =~ [[:cntrl:]] ]] && return 1
  [[ "$p/" == */../* || "$p/" == */./* ]] && return 1
  return 0
}

# glob_escape P : escape restic glob characters.
glob_escape() {
  local s=$1 c bs="\\"
  s=${s//"$bs"/"$bs$bs"}
  for c in '*' '?' '['; do s=${s//"$c"/"$bs$c"}; done
  printf '%s' "$s"
}

in_list() {
  local x=$1 y
  shift
  for y in "$@"; do
    if [[ $x == "$y" ]]; then return 0; fi
  done
  return 1
}

# Remove DEFINER clauses from a dump on stdin (they would run with the original owner's rights).
# shellcheck disable=SC2016 # literal backticks are the mysqldump identifier quotes
strip_definer() { sed -E 's/DEFINER=`[^`]*`@`[^`]*`//g'; }

# Root MySQL/MariaDB client via its defaults (/root/.my.cnf).
db_q() { mysql --batch --skip-column-names --execute="$1"; }
db_tbl() { mysql --batch --execute="$1"; }

# acct_discover [nofilter] : prints valid usernames, one per line.
acct_discover() {
  local raw u
  local -a ex=() only=()
  raw=$(db_q "SELECT username FROM root_cwp.user") || return 1
  if [[ ${1:-} != nofilter ]]; then
    IFS=' ' read -ra ex <<<"$EXCLUDE_ACCOUNTS" || true
    if [[ $ACCOUNTS != all ]]; then IFS=' ' read -ra only <<<"$ACCOUNTS" || true; fi
  fi
  while IFS= read -r u; do
    [[ -n $u ]] || continue
    if ! valid_account "$u"; then
      log_warn "skipping account with invalid username"
      continue
    fi
    if in_list "$u" "${ex[@]}"; then continue; fi
    if [[ $ACCOUNTS != all && ${1:-} != nofilter ]] && ! in_list "$u" "${only[@]}"; then continue; fi
    printf '%s\n' "$u"
  done <<<"$raw"
}

# acct_domains ACCOUNT : valid, lower-cased, unique domains (main, addon, sub).
acct_domains() {
  local u=$1 raw d
  valid_account "$u" || return 1
  raw=$(
    db_q "SELECT domain FROM root_cwp.user WHERE username='$u'"
    db_q "SELECT domain FROM root_cwp.domains WHERE user='$u'"
    db_q "SELECT CONCAT(subdomain,'.',domain) FROM root_cwp.subdomains WHERE user='$u'"
  ) || return 1
  raw=$(printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]' | sort -u)
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if valid_domain "$d"; then printf '%s\n' "$d"; else log_warn "skipping invalid domain name for account $u"; fi
  done <<<"$raw"
}

# acct_dbs ACCOUNT : databases named <account>_*.
acct_dbs() {
  local u=$1 raw d
  valid_account "$u" || return 1
  raw=$(db_q "SHOW DATABASES LIKE '${u}\\_%'") || return 1
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if valid_db "$u" "$d"; then printf '%s\n' "$d"; else log_warn "skipping database with unexpected name in account $u"; fi
  done <<<"$raw"
}

# acct_maildirs ACCOUNT : existing /var/vmail/<domain> directories.
acct_maildirs() {
  local d doms
  doms=$(acct_domains "$1") || return 1
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if [[ -d $VMAIL_ROOT/$d ]]; then printf '%s\n' "$VMAIL_ROOT/$d"; fi
  done <<<"$doms"
}
