# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# prune, check, unlock, snapshots, ls, init, verify-secrets.

PY_SNAPSHOTS='
import sys, json
out = []
for s in json.load(sys.stdin) or []:
    tags = s.get("tags") or []
    kind = "files"
    if "db" in tags:
        kind = "db"
    elif "meta" in tags or "mailauth" in tags:
        kind = "meta"
    db = next((t[3:] for t in tags if t.startswith("db:")), None)
    size = (s.get("summary") or {}).get("total_bytes_processed")
    out.append({"id": s.get("id"), "short_id": s.get("short_id") or (s.get("id") or "")[:8],
                "time": s.get("time"), "tags": tags, "paths": s.get("paths") or [],
                "kind": kind, "db": db, "size": size})
print(json.dumps(out))
'

PY_LS='
import sys, json, posixpath
req = sys.argv[1].rstrip("/") or "/"
out = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    n = json.loads(line)
    if "path" not in n or "type" not in n:
        continue
    if posixpath.dirname(n["path"].rstrip("/") or "/") != req or n["path"] == req:
        continue
    out.append({"name": n.get("name"), "type": n["type"], "size": n.get("size", 0),
                "mtime": n.get("mtime"), "path": n["path"]})
print(json.dumps(out))
'

need_python() { command -v python3 >/dev/null 2>&1 || die 1 "python3 is required for --json output of this command"; }

# maint_each LABEL restic-args... : run on every target; failures counted in RUN_*.
maint_each() {
  local label=$1 a rc
  shift
  for a in "${TARGETS[@]}"; do
    if ! repo_ensure "$a"; then
      log_error "$label $a: repository not reachable (rc $RESTIC_FAIL_RC)"
      RUN_FAILED=$((RUN_FAILED + 1))
      RUN_FAILED_NAMES+=("$a")
      if [[ -z $RUN_ERROR ]]; then RUN_ERROR="$a: repository not reachable"; fi
      if ((RESTIC_FAIL_RC != 12)); then RUN_STORAGE_DOWN=1; fi
      continue
    fi
    rc=0
    restic_run "$a" "$@" || rc=$?
    if ((rc == 0)); then
      log_info "$label $a: ok"
      RUN_OK=$((RUN_OK + 1))
    else
      log_error "$label $a: failed (rc $rc) ${RESTIC_ERR:-}"
      RUN_FAILED=$((RUN_FAILED + 1))
      RUN_FAILED_NAMES+=("$a")
      if [[ -z $RUN_ERROR ]]; then RUN_ERROR="$a: ${RESTIC_ERR:-rc $rc}"; fi
    fi
  done
  if ((RUN_FAILED > 0)); then
    if [[ $RUN_STORAGE_DOWN == 1 && $RUN_OK == 0 ]]; then return 4; fi
    return 1
  fi
}

maint_prepare() { # needs --account or --all; takes the global lock exclusively
  [[ -n $ARG_ACCOUNT || $ARG_ALL == 1 ]] || usage_err "$VAULT_CMD needs --account U or --all"
  [[ -z $ARG_ACCOUNT || $ARG_ALL != 1 ]] || usage_err "use --account or --all, not both"
  targets_resolve 1
  lock_take "$VAULT_LOCK/vault.lock" x || die 3 "a backup or another maintenance run is active"
  if [[ $ARG_ALL == 1 ]]; then lock_take "$VAULT_LOCK/all.lock" x || die 3 "another --all run is active"; fi
}

cmd_prune() {
  maint_prepare
  maint_each prune forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune
}

cmd_check() {
  maint_prepare
  maint_each check check --read-data-subset "$CHECK_SUBSET"
}

cmd_unlock() {
  maint_prepare
  if others_alive; then die 3 "another vault process is alive; not unlocking"; fi
  maint_each unlock unlock
}

cmd_init() {
  local a n first
  local -a existing=() created=()
  targets_resolve_all_init
  for a in "${TARGETS[@]}"; do
    if repo_ensure "$a"; then
      RUN_OK=$((RUN_OK + 1))
      if in_list "$a" "${REPO_CREATED[@]}"; then created+=("$a"); else existing+=("$a"); fi
      if [[ $ARG_JSON != 1 ]]; then echo "ok $a"; fi
    else
      RUN_FAILED=$((RUN_FAILED + 1))
      if ((RESTIC_FAIL_RC != 12)); then RUN_STORAGE_DOWN=1; fi
      if [[ $ARG_JSON != 1 ]]; then echo "FAILED $a (restic rc $RESTIC_FAIL_RC)"; fi
    fi
  done
  if ((RUN_FAILED > 0)); then
    if [[ $RUN_STORAGE_DOWN == 1 ]]; then die 4 "storage unreachable or repository unreadable"; fi
    die 1 "some repositories could not be opened (wrong password?)"
  fi
  if [[ $ARG_JSON == 1 ]]; then
    printf '{"ok":true,"created":['
    first=1
    for n in "${created[@]}"; do
      if ((first)); then first=0; else printf ','; fi
      json_str "$n"
    done
    printf '],"existing":['
    first=1
    for n in "${existing[@]}"; do
      if ((first)); then first=0; else printf ','; fi
      json_str "$n"
    done
    printf ']}\n'
  fi
}

targets_resolve_all_init() {
  ARG_ACCOUNT=''
  targets_resolve 1
}

cmd_verify_secrets() {
  local a rc
  targets_resolve_all_init
  for a in "${TARGETS[@]}"; do
    rc=0
    RETRIES=0 restic_run "$a" cat config || rc=$?
    case $rc in
      0) echo "ok $a" ;;
      10) echo "MISSING $a (repository does not exist)"; RUN_FAILED=$((RUN_FAILED + 1)) ;;
      12) echo "WRONG PASSWORD $a"; RUN_FAILED=$((RUN_FAILED + 1)) ;;
      *) echo "ERROR $a (restic rc $rc)"; RUN_FAILED=$((RUN_FAILED + 1)) ;;
    esac
  done
  ((RUN_FAILED == 0))
}

cmd_snapshots() {
  local rc=0
  [[ -n $ARG_ACCOUNT ]] || usage_err "snapshots needs --account U"
  valid_repo_name "$ARG_ACCOUNT" || die 2 "invalid account name"
  if [[ $ARG_JSON == 1 ]]; then
    need_python
    restic_run "$ARG_ACCOUNT" snapshots --json || rc=$?
    ((rc == 0)) || die 4 "cannot list snapshots: ${RESTIC_ERR:-restic rc $rc}"
    printf '%s\n' "$RESTIC_OUT" | python3 -I -c "$PY_SNAPSHOTS"
  else
    restic_run "$ARG_ACCOUNT" snapshots --group-by '' || rc=$?
    ((rc == 0)) || die 4 "cannot list snapshots: ${RESTIC_ERR:-restic rc $rc}"
    printf '%s\n' "$RESTIC_OUT"
  fi
}

cmd_ls() {
  local rc=0 path=${ARG_PATHS[-1]:-/}
  [[ -n $ARG_ACCOUNT ]] || usage_err "ls needs --account U"
  valid_repo_name "$ARG_ACCOUNT" || die 2 "invalid account name"
  valid_snapshot "$ARG_SNAPSHOT" || die 2 "invalid snapshot id"
  valid_restore_path "$path" || die 2 "invalid path"
  need_python
  restic_run "$ARG_ACCOUNT" ls --json "$ARG_SNAPSHOT" "$path" || rc=$?
  ((rc == 0)) || die 4 "cannot list snapshot: ${RESTIC_ERR:-restic rc $rc}"
  printf '%s\n' "$RESTIC_OUT" | python3 -I -c "$PY_LS" "$path"
}
