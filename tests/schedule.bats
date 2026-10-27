#!/usr/bin/env bats
load helpers/common

setup() {
  vault_setup
  cp "$REPO_ROOT/contrib/cron.d/cwp-vault" "$VAULT_CRON_FILE"
  chmod 0644 "$VAULT_CRON_FILE"
}
teardown() { vault_teardown; }

@test "schedule get --json reads the backup, prune and check lines" {
  need_python
  run vout schedule get --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | json_valid
  [ "$(printf '%s' "$output" | jget 'd["backup"]')" = "{'enabled': True, 'time': '01:30'}" ]
  [ "$(printf '%s' "$output" | jget 'd["prune"]')" = "{'day': 'sun', 'time': '04:00'}" ]
  [ "$(printf '%s' "$output" | jget 'd["check"]')" = "{'day': 'wed', 'time': '04:00'}" ]
  [ "$(printf '%s' "$output" | jget 'sorted(d.keys())')" = "['backup', 'check', 'next_run', 'next_run_epoch', 'now_epoch', 'prune', 'timezone', 'utc_offset']" ]
  [ "$(printf '%s' "$output" | jget 'd["timezone"] != ""')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["next_run_epoch"] > d["now_epoch"] and d["next_run_epoch"] - d["now_epoch"] <= 90000')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["next_run"][11:16]')" = "01:30" ]
}

@test "schedule get without a cron file reports the backup as disabled" {
  need_python
  rm -f "$VAULT_CRON_FILE"
  run vout schedule get --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["backup"]["enabled"]')" = False ]
  [ "$(printf '%s' "$output" | jget 'd["next_run"]')" = None ]
  [ "$(printf '%s' "$output" | jget 'd["next_run_epoch"]')" = None ]
}

@test "schedule set changes only the backup line and keeps every other line" {
  need_python
  printf '# my own note\nMAILTO=ops@example.com\n' >>"$VAULT_CRON_FILE"
  cp "$VAULT_CRON_FILE" "$T/before"
  run vout schedule set --time 03:15 --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["backup"]["time"]')" = "03:15" ]
  grep -q '^15 3 \* \* \*  root /usr/local/bin/vault backup --all --quiet$' "$VAULT_CRON_FILE"
  diff <(grep -v 'vault backup' "$T/before") <(grep -v 'vault backup' "$VAULT_CRON_FILE")
  [ "$(wc -l <"$VAULT_CRON_FILE")" -eq "$(wc -l <"$T/before")" ]
  [ "$(stat -c %a "$VAULT_CRON_FILE")" = 644 ]
  [ -z "$(ls -A "$T" | grep 'tmp' || true)" ]
  grep -q 'schedule backup time=03:15 enabled=yes' "$VAULT_HOME/var/log/audit.log"
  run vout schedule get --json
  [ "$(printf '%s' "$output" | jget 'd["backup"]["time"]')" = "03:15" ]
}

@test "schedule set refuses a bad time or flag and leaves the file alone" {
  cp "$VAULT_CRON_FILE" "$T/before"
  for t in 24:00 1:30 01:60 0130 abc '01:30 ' '$(id)' ''; do
    run vault schedule set --time "$t"
    [ "$status" -eq 2 ]
  done
  run vault schedule set --enabled maybe
  [ "$status" -eq 2 ]
  run vault schedule set
  [ "$status" -eq 2 ]
  run vault schedule frob
  [ "$status" -eq 2 ]
  cmp "$VAULT_CRON_FILE" "$T/before"
}

@test "schedule set --enabled no comments the line out and yes brings it back" {
  need_python
  run vout schedule set --enabled no --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["backup"]["enabled"]')" = False ]
  [ "$(printf '%s' "$output" | jget 'd["next_run"]')" = None ]
  grep -q '^#30 1 \* \* \*  root /usr/local/bin/vault backup --all --quiet$' "$VAULT_CRON_FILE"
  run vout schedule set --time 05:45 --json
  [ "$(printf '%s' "$output" | jget 'd["backup"]')" = "{'enabled': False, 'time': '05:45'}" ]
  run vout schedule set --enabled yes --json
  [ "$(printf '%s' "$output" | jget 'd["backup"]')" = "{'enabled': True, 'time': '05:45'}" ]
  grep -q '^45 5 \* \* \*  root /usr/local/bin/vault backup --all --quiet$' "$VAULT_CRON_FILE"
}

@test "an installer-style commented backup line is read as disabled" {
  need_python
  sed -i 's/^30 1/#30 1/' "$VAULT_CRON_FILE"
  run vout schedule get --json
  [ "$(printf '%s' "$output" | jget 'd["backup"]')" = "{'enabled': False, 'time': '01:30'}" ]
}

@test "schedule set creates the backup line (and the file) when missing" {
  need_python
  rm -f "$VAULT_CRON_FILE"
  run vout schedule set --time 02:00 --json
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$VAULT_CRON_FILE")" = 644 ]
  grep -q '^SHELL=/bin/bash$' "$VAULT_CRON_FILE"
  grep -q '^0 2 \* \* \*  root /usr/local/bin/vault backup --all --quiet$' "$VAULT_CRON_FILE"
  [ "$(printf '%s' "$output" | jget 'd["backup"]')" = "{'enabled': True, 'time': '02:00'}" ]
}

@test "status --json carries the schedule and now_epoch" {
  need_python
  run vout status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["schedule"]["backup"]["time"]')" = "01:30" ]
  [ "$(printf '%s' "$output" | jget 'abs(d["now_epoch"] - d["schedule"]["now_epoch"]) <= 2')" = True ]
}
