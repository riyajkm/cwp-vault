#!/usr/bin/env bats
load helpers/common

setup() {
  vault_setup
  command -v flock >/dev/null 2>&1 || skip "flock not available"
  mkdir -p "$VAULT_HOME/var/lock"
}
teardown() { vault_teardown; }

# hold_lock NAME : hold an exclusive flock on var/lock/NAME.lock in the background.
hold_lock() {
  local f=$VAULT_HOME/var/lock/$1.lock i
  ( exec 3>&-; exec 9>>"$f"; flock -x 9; exec sleep 30 3>&- ) &
  HOLDER_PID=$!
  for i in $(seq 1 50); do
    flock -n "$f" true 2>/dev/null || return 0   # lock is held once this fails
    sleep 0.1
  done
  return 1
}

@test "a second backup of the same account exits 3" {
  hold_lock alice
  run vault backup --account alice
  [ "$status" -eq 3 ]
  [[ $output == *"already being processed"* ]]
  [ ! -e "$STUB_LOG/restic.log" ]
}

@test "a locked account is skipped in --all and the others still run" {
  need_python
  hold_lock alice
  run vault backup --all
  [ "$(jget 'd["result"]' <"$(status_file alice)")" = skipped ]
  [ "$(jget 'd["result"]' <"$(status_file bob)")" = ok ]
  ! grep -q '/vault/alice | .*backup' "$STUB_LOG/restic.log"
}

@test "a different account is not blocked by the lock" {
  hold_lock alice
  run vault backup --account bob
  [ "$status" -eq 0 ]
}

@test "backup refuses to run while prune/check/unlock holds the global lock" {
  hold_lock vault
  run vault backup --account alice
  [ "$status" -eq 3 ]
}

@test "restore of an account being backed up exits 3" {
  hold_lock alice
  run vault restore --account alice --what files --target "$T/out"
  [ "$status" -eq 3 ]
}

@test "prune exits 3 while a backup holds the shared global lock" {
  local f=$VAULT_HOME/var/lock/vault.lock
  ( exec 3>&-; exec 9>>"$f"; flock -s 9; exec sleep 30 3>&- ) &
  HOLDER_PID=$!
  sleep 0.5
  run vault prune --account alice
  [ "$status" -eq 3 ]
}

@test "status --json lists a running holder" {
  need_python
  # A lock file with a live pid in it counts as running.
  printf '%s backup 2026-01-01T00:00:00Z\n' "$$" >"$VAULT_HOME/var/lock/alice.lock"
  run vout status --json
  [ "$(printf '%s' "$output" | jget 'd["running"][0]["account"]')" = alice ]
  [ "$(printf '%s' "$output" | jget 'd["running"][0]["command"]')" = backup ]
}
