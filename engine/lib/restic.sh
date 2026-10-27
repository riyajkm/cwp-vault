# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# restic wrapper: repo URL, common args, timeout, retries, secret scrubbing.
# Secrets reach restic only through its environment (set in a subshell), never argv.

restic_repo_url() { printf 's3:%s/%s/%svault/%s' "$S3_ENDPOINT" "$S3_BUCKET" "$S3_PREFIX" "$1"; }

# Drops any line that mentions a key name or contains a secret value.
restic_scrub() {
  VS1=${AWS_ACCESS_KEY_ID:-} VS2=${AWS_SECRET_ACCESS_KEY:-} VS3=${RESTIC_PASSWORD:-} awk '
    BEGIN { s[1]=ENVIRON["VS1"]; s[2]=ENVIRON["VS2"]; s[3]=ENVIRON["VS3"] }
    /AWS_(ACCESS|SECRET)|RESTIC_PASSWORD/ { next }
    { for (i=1;i<=3;i++) if (s[i] != "" && index($0, s[i])) next; print }'
}

# _restic_exec REPO_NAME restic-args... (stdin/stdout passed through)
_restic_exec() {
  local name=$1
  shift
  local -a cmd=(timeout "$ACCOUNT_TIMEOUT" restic -o "s3.connections=$S3_CONNECTIONS")
  if ((LIMIT_UPLOAD_KIB > 0)); then cmd+=(--limit-upload "$LIMIT_UPLOAD_KIB"); fi
  cmd+=("$@")
  (
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
    export RESTIC_REPOSITORY RESTIC_CACHE_DIR RESTIC_PROGRESS_FPS
    RESTIC_REPOSITORY=$(restic_repo_url "$name")
    RESTIC_CACHE_DIR=$VAULT_CACHE
    RESTIC_PROGRESS_FPS=0.016
    exec "${cmd[@]}"
  )
}

# One attempt; stdout scrubbed to stdout, stderr scrubbed into $RESTIC_STDERR_FILE.
_restic_once() {
  local rc=0
  _restic_exec "$@" 2>"$RESTIC_STDERR_FILE" | restic_scrub || rc=$?
  return "$rc"
}

# restic_run REPO args... : retries with backoff. Sets RESTIC_OUT, RESTIC_ERR; returns restic's rc.
# RESTIC_ACCEPT_3=1 treats rc 3 (some files unreadable) as success. rc 10/12 are never retried.
restic_run() {
  local rc i=0 tries=$((RETRIES + 1))
  local -a delays
  IFS=' ' read -ra delays <<<"${RETRY_DELAYS:-30 120 300}"
  while :; do
    rc=0
    RESTIC_OUT=$(_restic_once "$@" </dev/null) || rc=$?
    RESTIC_ERR=$(restic_scrub <"$RESTIC_STDERR_FILE" 2>/dev/null | tail -n 5 | cut -c1-300 || true)
    if ((rc == 0)); then return 0; fi
    if ((rc == 3)) && [[ ${RESTIC_ACCEPT_3:-0} == 1 ]]; then
      log_warn "restic finished with unreadable files (rc 3)"
      return 0
    fi
    if ((rc == 10 || rc == 12)); then return "$rc"; fi
    i=$((i + 1))
    if ((i >= tries)); then return "$rc"; fi
    local d=${delays[i - 1]:-${delays[${#delays[@]} - 1]}}
    log_warn "restic failed (rc $rc); retry $i of $RETRIES in ${d}s"
    sleep "$d"
  done
}

# restic_stream REPO args... : stdin is the data; no retry. Prints scrubbed stdout.
restic_stream() {
  local rc=0
  _restic_once "$@" || rc=$?
  if ((rc != 0)); then
    log_warn "restic stream failed (rc $rc): $(restic_scrub <"$RESTIC_STDERR_FILE" 2>/dev/null | tail -n 3 | cut -c1-300 | tr '\n' ' ' || true)"
  fi
  return "$rc"
}

# restic_dump REPO args... : raw stdout (file contents), scrubbed stderr to the error file.
restic_dump() { _restic_exec "$@" 2>>"$RESTIC_STDERR_FILE"; }

# repo_ensure NAME : create the repo when it does not exist. rc: 0 ok, 1 failed (RESTIC_FAIL_RC set).
declare -A REPO_READY=()
declare -a REPO_CREATED=()
RESTIC_FAIL_RC=0
repo_ensure() {
  local name=$1 rc=0
  if [[ -n ${REPO_READY[$name]:-} ]]; then return 0; fi
  restic_run "$name" cat config || rc=$?
  if ((rc == 10)); then
    log_info "creating repository $name"
    rc=0
    restic_run "$name" init || rc=$?
    if ((rc == 0)); then REPO_CREATED+=("$name"); fi
  fi
  if ((rc != 0)); then
    RESTIC_FAIL_RC=$rc
    return 1
  fi
  REPO_READY[$name]=1
}

# restic_summary OUTPUT : sets SUM_ID SUM_NEW SUM_CHG SUM_ADD from restic --json output.
restic_summary() {
  local l
  l=$(grep -m1 '"message_type":"summary"' <<<"$1" || true)
  SUM_ID=$(sed -n 's/.*"snapshot_id":"\([0-9a-f]*\)".*/\1/p' <<<"$l")
  SUM_NEW=$(sed -n 's/.*"files_new":\([0-9]*\).*/\1/p' <<<"$l")
  SUM_CHG=$(sed -n 's/.*"files_changed":\([0-9]*\).*/\1/p' <<<"$l")
  SUM_ADD=$(sed -n 's/.*"data_added":\([0-9]*\).*/\1/p' <<<"$l")
  SUM_NEW=${SUM_NEW:-0}
  SUM_CHG=${SUM_CHG:-0}
  SUM_ADD=${SUM_ADD:-0}
}
