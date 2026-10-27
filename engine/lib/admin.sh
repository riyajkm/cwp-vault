# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Admin-module commands: config get/set, secrets set/status, log.

# atomic_write FILE MODE : content on stdin; same-directory temp file, then rename.
atomic_write() {
  local f=$1 mode=$2 tmp
  tmp="$f.tmp.$$"
  cat >"$tmp"
  chmod "$mode" -- "$tmp"
  mv -f -- "$tmp" "$f"
}

cmd_config() {
  local sub=${ARG_POS[0]:-} k first=1 p key val old
  local -a keys=() pairs=() changed=()
  local -A oldv=() newv=()
  case $sub in
    get)
      cfg_defaults
      if [[ -f $VAULT_CONF ]]; then cfg_parse_file "$VAULT_CONF" conf; fi
      mapfile -t keys < <(printf '%s\n' "${!CFG_DEFAULTS[@]}" | sort)
      printf '{'
      for k in "${keys[@]}"; do
        if ((first)); then first=0; else printf ','; fi
        printf '%s:%s' "$(json_str "$k")" "$(json_str "${!k}")"
      done
      printf '}\n'
      ;;
    set)
      pairs=("${ARG_POS[@]:1}")
      ((${#pairs[@]} > 0)) || usage_err "config set needs KEY=VALUE pairs"
      cfg_defaults
      if [[ -f $VAULT_CONF ]]; then cfg_parse_file "$VAULT_CONF" conf; fi
      for k in "${!CFG_DEFAULTS[@]}"; do oldv[$k]=${!k}; done
      for p in "${pairs[@]}"; do
        [[ $p == *=* ]] || die 2 "expected KEY=VALUE"
        key=${p%%=*}
        val=${p#*=}
        [[ -v CFG_DEFAULTS[$key] ]] || die 2 "unknown key $key"
        ((${#val} <= CFG_MAXLEN)) || die 2 "value of $key is too long"
        [[ $val =~ [[:cntrl:]] ]] && die 2 "control character in value of $key"
        # shellcheck disable=SC2016 # literal $( is what we look for
        if [[ $val == *'$('* || $val == *'`'* ]]; then die 2 "$key contains \$( or a backtick"; fi
        if [[ $val == [\"\']* || $val != "${val#"${val%%[![:space:]]*}"}" || $val != "${val%"${val##*[![:space:]]}"}" ]]; then
          die 2 "value of $key must not start with a quote or have leading/trailing spaces"
        fi
        printf -v "$key" '%s' "$val"
      done
      cfg_validate
      for p in "${pairs[@]}"; do
        key=${p%%=*}
        newv[$key]=${!key}
        if [[ ${newv[$key]} != "${oldv[$key]}" ]]; then changed+=("$key"); fi
      done
      config_write newv
      printf '{"ok":true,"changed":['
      first=1
      for k in "${changed[@]}"; do
        if ((first)); then first=0; else printf ','; fi
        json_str "$k"
      done
      printf ']}\n'
      ;;
    *) usage_err "config needs get or set" ;;
  esac
  : "${old:-}"
}

# config_write ARRAYNAME : replace KEY= lines in vault.conf (keeps comments), append missing keys.
config_write() {
  local -n nv=$1
  local line k tmp="$VAULT_CONF.tmp.$$"
  local -A done_=()
  {
    if [[ -f $VAULT_CONF ]]; then
      while IFS= read -r line || [[ -n $line ]]; do
        k=${line%%=*}
        if [[ $line =~ ^[A-Z][A-Z0-9_]*= && -v nv[$k] ]]; then
          printf '%s=%s\n' "$k" "${nv[$k]}"
          done_[$k]=1
        else
          printf '%s\n' "$line"
        fi
      done <"$VAULT_CONF"
    fi
    for k in "${!nv[@]}"; do
      if [[ -z ${done_[$k]:-} ]]; then printf '%s=%s\n' "$k" "${nv[$k]}"; fi
    done
  } >"$tmp"
  chmod 0640 -- "$tmp"
  mv -f -- "$tmp" "$VAULT_CONF"
}

secrets_read_existing() {
  cfg_defaults
  if [[ -f $VAULT_SECRETS ]]; then cfg_parse_file "$VAULT_SECRETS" secret; fi
}

cmd_secrets() {
  local sub=${ARG_POS[0]:-} input line key val old_pw hint rc=0
  case $sub in
    status)
      secrets_read_existing
      hint=''
      if [[ ${#AWS_ACCESS_KEY_ID} -ge 4 ]]; then hint="…${AWS_ACCESS_KEY_ID: -4}"; fi
      printf '{"s3_key_set":%s,"access_key_hint":%s,"password_set":%s}\n' \
        "$([[ -n $AWS_ACCESS_KEY_ID && -n $AWS_SECRET_ACCESS_KEY ]] && echo true || echo false)" \
        "$(json_str "$hint")" "$([[ -n $RESTIC_PASSWORD ]] && echo true || echo false)"
      ;;
    set)
      secrets_read_existing
      old_pw=$RESTIC_PASSWORD
      input=$(head -c 8192) || true
      [[ -n $input ]] || usage_err "secrets set reads KEY=VALUE lines from stdin"
      while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line ]] && continue
        [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die 2 "stdin line is not KEY=VALUE"
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        [[ -v CFG_SECRET_KEYS[$key] ]] || die 2 "unknown secret key $key"
        ((${#val} >= 1 && ${#val} <= CFG_MAXLEN)) || die 2 "bad length for $key"
        [[ $val =~ [[:cntrl:]] ]] && die 2 "control character in $key"
        if [[ $val == [\"\']* || $val != "${val#"${val%%[![:space:]]*}"}" || $val != "${val%"${val##*[![:space:]]}"}" ]]; then
          die 2 "$key must not start with a quote or have leading/trailing spaces"
        fi
        if [[ $key != RESTIC_PASSWORD && ! $val =~ ^[A-Za-z0-9/+=_.-]{1,128}$ ]]; then die 2 "$key has unexpected characters"; fi
        printf -v "$key" '%s' "$val"
      done <<<"$input"
      if [[ -n $old_pw && $RESTIC_PASSWORD != "$old_pw" ]]; then
        secrets_refuse_password_change "$old_pw" || die 2 "repositories already exist (or cannot be checked); the restic password cannot be changed here"
      fi
      printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nRESTIC_PASSWORD=%s\n' \
        "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$RESTIC_PASSWORD" | atomic_write "$VAULT_SECRETS" 0600
      printf '{"ok":true}\n'
      ;;
    *) usage_err "secrets needs set or status" ;;
  esac
  : "${rc:-}"
}

# Returns 0 when the password may change (the _server repo is confirmed absent), 1 otherwise.
secrets_refuse_password_change() {
  local old_pw=$1 new_pw=$RESTIC_PASSWORD rc=0
  [[ -f $VAULT_CONF ]] || return 0
  cfg_parse_file "$VAULT_CONF" conf
  RESTIC_PASSWORD=$old_pw
  RETRIES=0 restic_run _server cat config || rc=$?
  RESTIC_PASSWORD=$new_pw
  ((rc == 10))
}

cmd_log() {
  local n=${ARG_TAIL:-50} line first=1
  [[ $n =~ ^[0-9]{1,5}$ ]] || usage_err "--tail needs a number"
  if [[ ! -f $VAULT_LOG_FILE ]]; then
    if [[ $ARG_JSON == 1 ]]; then echo '{"lines":[]}'; fi
    return 0
  fi
  if [[ $ARG_JSON == 1 ]]; then
    printf '{"lines":['
    while IFS= read -r line; do
      if ((first)); then first=0; else printf ','; fi
      json_str "$line"
    done < <(tail -n "$n" -- "$VAULT_LOG_FILE")
    printf ']}\n'
  else
    tail -n "$n" -- "$VAULT_LOG_FILE"
  fi
}
