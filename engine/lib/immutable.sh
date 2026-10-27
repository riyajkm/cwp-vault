# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Immutable mode (S3 object lock): bucket checks, lifecycle rule, "vault recover". See docs/research/immutable.md.
# restic cannot read bucket settings, so this needs the aws CLI v2 (s3api) and python3 (JSON).

LIFECYCLE_ID=cwp-vault-noncurrent

# argv: MODE DAYS ; stdin: get-object-lock-configuration JSON. Prints the reason and exits 1 when the lock is not good enough.
PY_LOCKCHECK='
import sys, json
mode, need = sys.argv[1], int(sys.argv[2])
try:
    c = json.load(sys.stdin).get("ObjectLockConfiguration") or {}
except ValueError:
    c = {}
if c.get("ObjectLockEnabled") != "Enabled":
    sys.exit("object lock is not enabled on the bucket")
r = (c.get("Rule") or {}).get("DefaultRetention") or {}
if r.get("Mode") != mode:
    sys.exit("the bucket default retention mode is %s, expected %s" % (r.get("Mode") or "not set", mode))
days = int(r.get("Days") or 0) + 365 * int(r.get("Years") or 0)
if days < need:
    sys.exit("the bucket default retention is %d days, expected at least %d" % (days, need))
'

# argv: RULE_ID PREFIX NONCURRENT_DAYS ; stdin: get-bucket-lifecycle-configuration JSON (or empty).
# Prints "same" or "changed", then the merged configuration on the second line.
PY_LIFECYCLE='
import sys, json
rid, prefix, days = sys.argv[1], sys.argv[2], int(sys.argv[3])
raw = sys.stdin.read().strip()
rules = (json.loads(raw) if raw else {}).get("Rules") or []
ours = {"ID": rid, "Status": "Enabled", "Filter": {"Prefix": prefix},
        "NoncurrentVersionExpiration": {"NoncurrentDays": days}}
state = "same" if ours in rules else "changed"
merged = [r for r in rules if r.get("ID") != rid] + [ours]
print(state)
print(json.dumps({"Rules": merged}))
'

# argv: BEFORE(UTC "YYYY-MM-DDTHH:MM:SS" or empty) ; stdin: list-object-versions JSON.
# Prints "key<TAB>versionid" per delete marker newer than BEFORE.
# shortcut: compares the first 19 characters of LastModified, so it assumes the CLI prints UTC (it does).
PY_MARKERS='
import sys, json, re
before = sys.argv[1]
raw = sys.stdin.read().strip()
for m in (json.loads(raw) if raw else {}).get("DeleteMarkers") or []:
    k, v = m.get("Key", ""), m.get("VersionId", "")
    if re.search(r"[\x00-\x1f]", k + v) or not v:
        continue
    if before and str(m.get("LastModified", ""))[:19] <= before:
        continue
    print(k + "\t" + v)
'

imm_need_tools() {
  command -v aws >/dev/null 2>&1 || die 2 "immutable mode needs the aws CLI v2 (to read the bucket's object lock settings); install it and retry"
  command -v python3 >/dev/null 2>&1 || die 2 "immutable mode needs python3"
}

# aws_s3api args... : sets AWS_OUT (stdout) and AWS_ERR (scrubbed stderr tail); returns aws's rc.
AWS_OUT='' AWS_ERR=''
aws_s3api() {
  local rc=0 errf="$VAULT_TMP/aws.$$.err"
  AWS_OUT=$(
    (
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_PAGER=''
      export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
      export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
      exec timeout 300 aws --endpoint-url "$S3_ENDPOINT" --output json s3api "$@" </dev/null
    ) 2>"$errf"
  ) || rc=$?
  AWS_ERR=$(restic_scrub <"$errf" 2>/dev/null | tail -n 3 | cut -c1-300 | tr '\n' ' ' || true)
  rm -f -- "$errf"
  return "$rc"
}

# aws_error_code ARGS... : the S3 <Code> of a failing call. Contabo sends errors with an empty
# <Message>, which makes the AWS CLI crash ("'NoneType' is not ... iterable") instead of naming the
# error, so read the code from the --debug response body.
aws_error_code() {
  env AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" AWS_PAGER='' \
    AWS_DEFAULT_REGION=us-east-1 \
    timeout 120 aws --endpoint-url "$S3_ENDPOINT" --debug s3api "$@" </dev/null 2>&1 >/dev/null | grep -o '<Code>[A-Za-z]*</Code>' | head -n 1 | sed 's/<[^>]*>//g' || true
}

# imm_init_check : refuse unless the bucket has the required lock; then merge in our lifecycle rule.
imm_init_check() {
  local msg out="$VAULT_TMP/lifecycle.$$.json" res state raw=''
  imm_need_tools
  aws_s3api get-object-lock-configuration --bucket "$S3_BUCKET" ||
    die 2 "cannot read the object lock settings of $S3_BUCKET: ${AWS_ERR:-no answer}. Immutable mode needs a bucket created with Object Lock enabled."
  msg=$(printf '%s' "$AWS_OUT" | python3 -I -c "$PY_LOCKCHECK" "$LOCK_MODE" "$LOCK_DAYS" 2>&1) || die 2 "bucket $S3_BUCKET is not suitable for immutable mode: $msg"
  if aws_s3api get-bucket-lifecycle-configuration --bucket "$S3_BUCKET"; then
    raw=$AWS_OUT
  elif [[ $AWS_ERR != *NoSuchLifecycleConfiguration* ]] &&
    [[ $(aws_error_code get-bucket-lifecycle-configuration --bucket "$S3_BUCKET") != NoSuchLifecycleConfiguration ]]; then
    die 2 "cannot read the lifecycle rules of $S3_BUCKET: ${AWS_ERR:-no answer}"
  fi
  res=$(printf '%s' "$raw" | python3 -I -c "$PY_LIFECYCLE" "$LIFECYCLE_ID" "${S3_PREFIX}vault/" "$((LOCK_DAYS + 7))") ||
    die 2 "cannot merge the lifecycle rules"
  state=${res%%$'\n'*}
  state=${state%$'\r'}
  if [[ $state == changed ]]; then
    printf '%s\n' "${res#*$'\n'}" >"$out"
    aws_s3api put-bucket-lifecycle-configuration --bucket "$S3_BUCKET" --lifecycle-configuration "file://$out" ||
      { rm -f -- "$out"; die 2 "cannot set the lifecycle rule: ${AWS_ERR:-no answer}"; }
    log_info "lifecycle rule $LIFECYCLE_ID set: noncurrent versions expire after $((LOCK_DAYS + 7)) days"
  fi
  rm -f -- "$out"
}

# imm_status_json : the "immutable" object for status --json (never fails; works before the config is complete).
imm_status_json() {
  local en=no mode=COMPLIANCE days=14 v
  if [[ -f $VAULT_CONF ]]; then
    v=$( (cfg_defaults; cfg_parse_file "$VAULT_CONF" conf; printf '%s %s %s' "$IMMUTABLE" "$LOCK_MODE" "$LOCK_DAYS") 2>/dev/null) || v=''
    if [[ -n $v ]]; then IFS=' ' read -r en mode days <<<"$v"; fi
  fi
  [[ $en == yes ]] || en=no
  [[ $mode == COMPLIANCE || $mode == GOVERNANCE ]] || mode=COMPLIANCE
  [[ $days =~ ^[0-9]{1,4}$ ]] || days=14
  printf '{"enabled":%s,"mode":"%s","days":%d}' "$([[ $en == yes ]] && echo true || echo false)" "$mode" "$((10#$days))"
}

# recover_json OK ERROR : prints the JSON result; uses REC_* arrays.
declare -a REC_NAMES=() REC_MARKERS=() REC_REMOVED=() REC_CHECK=()
recover_json() {
  local i first=1
  printf '{"ok":%s,"accounts":[' "$1"
  for i in "${!REC_NAMES[@]}"; do
    if ((first)); then first=0; else printf ','; fi
    printf '{"account":%s,"delete_markers":%d,"removed":%d,"check":%s}' "$(json_str "${REC_NAMES[i]}")" \
      "${REC_MARKERS[i]}" "${REC_REMOVED[i]}" "$(json_str "${REC_CHECK[i]}")"
  done
  printf '],"error":%s}\n' "$(json_str "$2")"
}

cmd_recover() {
  local a before='' norm_before='' line key ver n rc fail=0 err='' i
  local -a lines
  [[ $IMMUTABLE == yes ]] || die 2 "recover only works in immutable mode (set IMMUTABLE=yes)"
  imm_need_tools
  if [[ -n $ARG_BEFORE ]]; then
    [[ $ARG_BEFORE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([T\ ][0-9:.]{4,12})?(Z|[+-][0-9]{2}:?[0-9]{2})?$ ]] || usage_err "--before needs an ISO 8601 time, e.g. 2026-10-28T03:00:00Z"
    before=$ARG_BEFORE
    norm_before=$(date -u -d "$before" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || usage_err "--before is not a valid time"
  fi
  maint_prepare
  for a in "${TARGETS[@]}"; do
    rc=0
    aws_s3api list-object-versions --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}vault/$a/" || rc=$?
    if ((rc != 0)); then
      err="$a: cannot list object versions: ${AWS_ERR:-no answer}"
      log_error "recover $err"
      REC_NAMES+=("$a") REC_MARKERS+=(0) REC_REMOVED+=(0) REC_CHECK+=(failed)
      fail=1
      continue
    fi
    mapfile -t lines < <(printf '%s' "$AWS_OUT" | python3 -I -c "$PY_MARKERS" "$norm_before")
    if [[ -z ${lines[0]:-} ]]; then lines=(); fi
    REC_NAMES+=("$a") REC_MARKERS+=("${#lines[@]}") REC_REMOVED+=(0) REC_CHECK+=(skipped)
    i=$((${#REC_NAMES[@]} - 1))
    [[ $ARG_YES == 1 ]] || continue
    n=0
    for line in "${lines[@]}"; do
      IFS=$'\t' read -r key ver <<<"$line"
      if aws_s3api delete-object --bucket "$S3_BUCKET" --key "$key" --version-id "$ver"; then
        n=$((n + 1))
      else
        err="$a: cannot remove a delete marker: ${AWS_ERR:-no answer}"
        log_error "recover $err"
        fail=1
        break
      fi
    done
    REC_REMOVED[i]=$n
    ((n == ${#lines[@]})) || continue # a marker could not be removed: leave the repository alone
    rc=0
    restic_run "$a" unlock --remove-all || rc=$?
    if ((rc == 0)); then restic_run "$a" check || rc=$?; fi
    if ((rc == 0)); then
      REC_CHECK[i]=ok
    else
      REC_CHECK[i]=failed
      fail=1
      if [[ -z $err ]]; then err="$a: repository check failed: ${RESTIC_ERR:-restic rc $rc}"; fi
    fi
    log_info "recover $a: removed $n of ${REC_MARKERS[i]} delete markers, check ${REC_CHECK[i]}"
  done
  if [[ $ARG_YES == 1 ]]; then
    n=0
    for i in "${!REC_NAMES[@]}"; do n=$((n + REC_REMOVED[i])); done
    printf '%s recover accounts=%s before=%s removed=%d result=%s\n' "$(log_ts)" "$(join_by , "${REC_NAMES[@]}")" "${before:-all}" "$n" \
      "$([[ $fail == 0 ]] && echo ok || echo failed)" >>"$VAULT_AUDIT"
  fi
  if [[ $ARG_JSON == 1 ]]; then
    recover_json "$([[ $fail == 0 ]] && echo true || echo false)" "$err"
  else
    for i in "${!REC_NAMES[@]}"; do
      printf '%s: %d delete markers, removed %d, check %s\n' "${REC_NAMES[i]}" "${REC_MARKERS[i]}" "${REC_REMOVED[i]}" "${REC_CHECK[i]}"
    done
    if [[ $ARG_YES != 1 ]]; then echo "Dry run: nothing was changed. Run again with --yes to remove these delete markers."; fi
  fi
  return "$fail"
}
