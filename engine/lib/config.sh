# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Config + secrets parsing. Files are parsed as KEY=value data and never sourced.

CFG_MAXLEN=1024
declare -A CFG_DEFAULTS=(
  [S3_ENDPOINT]='' [S3_BUCKET]='' [S3_PREFIX]='' [ACCOUNTS]=all [EXCLUDE_ACCOUNTS]=''
  [EXCLUDES]='' [BACKUP_MAIL]=yes [BACKUP_DATABASES]=yes [BACKUP_SERVER]=yes
  [S3_CONNECTIONS]=4 [LIMIT_UPLOAD_KIB]=0 [KEEP_DAILY]=7 [KEEP_WEEKLY]=4 [KEEP_MONTHLY]=3
  [CHECK_SUBSET]='5%' [ALERT_EMAIL]='' [ALERT_WEBHOOK]='' [HEARTBEAT_URL]='' [RETRIES]=3
  [ALLOW_INSECURE]=no [ACCOUNT_TIMEOUT]=6h [MIN_FREE_GB]=5
  [IMMUTABLE]=no [LOCK_MODE]=COMPLIANCE [LOCK_DAYS]=14 [EXPORT_KEEP_HOURS]=24 [ORPHAN_KEEP_DAYS]=30
)
declare -A CFG_SECRET_KEYS=([AWS_ACCESS_KEY_ID]=1 [AWS_SECRET_ACCESS_KEY]=1 [RESTIC_PASSWORD]=1)

cfg_defaults() {
  local k
  for k in "${!CFG_DEFAULTS[@]}"; do printf -v "$k" '%s' "${CFG_DEFAULTS[$k]}"; done
  for k in "${!CFG_SECRET_KEYS[@]}"; do printf -v "$k" '%s' ''; done
}

# cfg_parse_file FILE conf|secret
cfg_parse_file() {
  local file=$1 kind=$2 line key val n=0 a b
  local dq='^"(.*)"$' sq="^'(.*)'\$" kv='^([A-Z][A-Z0-9_]*)=(.*)$'
  [[ -f $file && -r $file ]] || die 2 "cannot read $file"
  a=$(cksum <"$file")
  b=$(LC_ALL=C tr -d '\000' <"$file" | cksum)
  [[ $a == "$b" ]] || die 2 "$file contains a NUL byte"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line#"${line%%[![:space:]]*}"}
    if [[ -z $line || $line == '#'* ]]; then continue; fi
    [[ $line =~ $kv ]] || die 2 "$file:$n: expected KEY=value"
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    val=${val%"${val##*[![:space:]]}"}
    if [[ $val =~ $dq ]]; then val=${BASH_REMATCH[1]}; elif [[ $val =~ $sq ]]; then val=${BASH_REMATCH[1]}; fi
    ((${#val} <= CFG_MAXLEN)) || die 2 "$file:$n: value of $key longer than $CFG_MAXLEN"
    [[ $val =~ [[:cntrl:]] ]] && die 2 "$file:$n: control character in $key"
    if [[ $kind == conf ]]; then
      # shellcheck disable=SC2016 # literal $( is what we look for
      if [[ $val == *'$('* || $val == *'`'* ]]; then die 2 "$file:$n: $key contains \$( or a backtick"; fi
      if [[ ! -v CFG_DEFAULTS[$key] ]]; then log_warn "$file:$n: unknown key $key ignored"; continue; fi
    else
      if [[ ! -v CFG_SECRET_KEYS[$key] ]]; then log_warn "$file:$n: unknown key $key ignored"; continue; fi
    fi
    printf -v "$key" '%s' "$val"
  done <"$file"
}

# cfg_check_perms FILE MAXMODE(octal digits to forbid, e.g. 077)
cfg_check_perms() {
  local mode
  mode=$(stat -c %a "$1") || die 2 "cannot stat $1"
  if ((8#$mode & 8#$2)); then die 2 "$1 has mode $mode; too open (forbidden bits $2)"; fi
}

cfg_bad() { die 2 "vault.conf: invalid $1: $2"; }

cfg_validate() {
  local k v w ep_re
  for k in BACKUP_MAIL BACKUP_DATABASES BACKUP_SERVER ALLOW_INSECURE IMMUTABLE; do
    [[ ${!k} == yes || ${!k} == no ]] || cfg_bad "$k" "must be yes or no"
  done
  for k in S3_CONNECTIONS LIMIT_UPLOAD_KIB KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY RETRIES MIN_FREE_GB ORPHAN_KEEP_DAYS; do
    [[ ${!k} =~ ^[0-9]{1,6}$ ]] || cfg_bad "$k" "must be a number"
  done
  [[ $LOCK_MODE == COMPLIANCE || $LOCK_MODE == GOVERNANCE ]] || cfg_bad LOCK_MODE "must be COMPLIANCE or GOVERNANCE"
  [[ $LOCK_DAYS =~ ^[0-9]{1,4}$ ]] || cfg_bad LOCK_DAYS "must be a number"
  ((10#$LOCK_DAYS >= 1 && 10#$LOCK_DAYS <= 3650)) || cfg_bad LOCK_DAYS "must be 1 to 3650"
  LOCK_DAYS=$((10#$LOCK_DAYS))
  [[ $EXPORT_KEEP_HOURS =~ ^[0-9]{1,4}$ ]] || cfg_bad EXPORT_KEEP_HOURS "must be a number"
  ((10#$EXPORT_KEEP_HOURS >= 1 && 10#$EXPORT_KEEP_HOURS <= 720)) || cfg_bad EXPORT_KEEP_HOURS "must be 1 to 720"
  EXPORT_KEEP_HOURS=$((10#$EXPORT_KEEP_HOURS))
  ORPHAN_KEEP_DAYS=$((10#$ORPHAN_KEEP_DAYS))
  ((S3_CONNECTIONS >= 1)) || cfg_bad S3_CONNECTIONS "must be at least 1"
  ((RETRIES <= 10)) || cfg_bad RETRIES "at most 10"
  [[ $ACCOUNT_TIMEOUT =~ ^[0-9]+[smhd]?$ ]] || cfg_bad ACCOUNT_TIMEOUT "use e.g. 6h"
  [[ $CHECK_SUBSET =~ ^([0-9]{1,3}(\.[0-9]+)?%|[0-9]+/[0-9]+|[0-9]+[KMGT])$ ]] || cfg_bad CHECK_SUBSET "use e.g. 5%"

  [[ -n $S3_ENDPOINT ]] || cfg_bad S3_ENDPOINT "required"
  [[ -n $S3_BUCKET ]] || cfg_bad S3_BUCKET "required"
  ep_re='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$'
  if [[ $ALLOW_INSECURE == yes ]]; then ep_re='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$'; fi
  [[ $S3_ENDPOINT =~ $ep_re ]] || cfg_bad S3_ENDPOINT "must be https://host[:port] (no path)"
  [[ $S3_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || cfg_bad S3_BUCKET "3-63 chars a-z 0-9 . -"
  if [[ -n $S3_PREFIX ]]; then
    [[ $S3_PREFIX == */ ]] || S3_PREFIX+=/
    [[ $S3_PREFIX =~ ^([A-Za-z0-9._-]+/)+$ ]] || cfg_bad S3_PREFIX "letters, digits . _ - and /"
    [[ $S3_PREFIX == *..* ]] && cfg_bad S3_PREFIX "no .."
  fi

  if [[ $ACCOUNTS != all ]]; then
    for w in $(printf '%s' "$ACCOUNTS" | tr ' ' '\n'); do valid_account "$w" || cfg_bad ACCOUNTS "bad username"; done
  fi
  for w in $(printf '%s' "$EXCLUDE_ACCOUNTS" | tr ' ' '\n'); do valid_account "$w" || cfg_bad EXCLUDE_ACCOUNTS "bad username"; done
  for w in $(printf '%s' "$EXCLUDES" | tr ' ' '\n'); do
    [[ $w =~ ^[][A-Za-z0-9_.*?/{}@+=,:~-]+$ ]] || cfg_bad EXCLUDES "bad pattern"
  done

  if [[ -n $ALERT_EMAIL ]]; then
    [[ $ALERT_EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || cfg_bad ALERT_EMAIL "must be one plain address"
  fi
  for k in ALERT_WEBHOOK HEARTBEAT_URL; do
    v=${!k}
    if [[ -n $v ]]; then
      [[ $v =~ ^https://[^[:space:]\"\'\\\<\>]+$ ]] || cfg_bad "$k" "must be an https:// URL"
    fi
  done
}

# cfg_load : defaults, conf, secrets, validation. Dies with 2 on any problem.
cfg_load() {
  cfg_defaults
  cfg_check_perms "$VAULT_CONF" 002
  cfg_parse_file "$VAULT_CONF" conf
  cfg_validate
  cfg_check_perms "$VAULT_SECRETS" 077
  cfg_parse_file "$VAULT_SECRETS" secret
  [[ -n $AWS_ACCESS_KEY_ID && -n $AWS_SECRET_ACCESS_KEY && -n $RESTIC_PASSWORD ]] ||
    die 2 "secrets.env must define AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and RESTIC_PASSWORD"
  [[ $AWS_ACCESS_KEY_ID =~ ^[A-Za-z0-9/+=_.-]{1,128}$ && $AWS_SECRET_ACCESS_KEY =~ ^[A-Za-z0-9/+=_.-]{1,128}$ ]] ||
    die 2 "secrets.env: access key or secret key has unexpected characters"
}
