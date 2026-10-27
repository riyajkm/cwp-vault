# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# test-storage: write, read back and delete a tiny probe snapshot in _server.

now_ms() {
  local n
  n=$(date +%s%N)
  printf '%d' "$((n / 1000000))"
}

storage_report() { # OK WRITE READ DELETE ERROR
  if [[ $ARG_JSON == 1 ]]; then
    printf '{"ok":%s,"write_ms":%d,"read_ms":%d,"delete_ms":%d,"error":%s}\n' "$1" "$2" "$3" "$4" "$(json_str "$5")"
  elif [[ $1 == true ]]; then
    printf 'Storage OK: write %d ms, read %d ms, delete %d ms\n' "$2" "$3" "$4"
  else
    printf 'Storage test FAILED: %s\n' "$5" >&2
  fi
}

cmd_test_storage() {
  local t id='' probe back out rc=0 w=0 r=0 d=0
  lock_take "$VAULT_LOCK/vault.lock" s || die 3 "prune/check/unlock is running"
  if ! repo_ensure _server; then
    storage_report false 0 0 0 "repository not reachable (restic rc $RESTIC_FAIL_RC): ${RESTIC_ERR:-}"
    return 4
  fi
  probe="cwp-vault probe $(date +%s)"
  t=$(now_ms)
  out=$(printf '%s\n' "$probe" | restic_stream _server backup --json --stdin --stdin-filename probe/probe.txt --tag probe) || rc=$?
  restic_summary "$out"
  id=$SUM_ID
  w=$(($(now_ms) - t))
  if ((rc != 0)) || [[ -z $id ]]; then
    storage_report false "$w" 0 0 "write failed"
    return 4
  fi
  t=$(now_ms)
  back=$(restic_dump _server dump "$id" /probe/probe.txt) || rc=$?
  r=$(($(now_ms) - t))
  if ((rc != 0)) || [[ $back != "$probe" ]]; then
    restic_run _server forget "$id" --prune || true
    storage_report false "$w" "$r" 0 "read-back failed or did not match"
    return 4
  fi
  t=$(now_ms)
  restic_run _server forget "$id" --prune || rc=$?
  d=$(($(now_ms) - t))
  if ((rc != 0)); then
    storage_report false "$w" "$r" "$d" "probe could not be deleted"
    return 4
  fi
  storage_report true "$w" "$r" "$d" ""
}
