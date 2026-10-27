#!/usr/bin/env bats
load helpers/common

setup() {
  vault_setup
  need_python
  unset STUB_VERIFY_BAD STUB_VERIFY_MISSING STUB_VERIFY_TABLES STUB_LS_FAIL STUB_IMPORT_FAIL STUB_RESTORE_FAIL
}
teardown() { vault_teardown; }

verify_file() { printf '%s/var/status/verify-%s.json' "$VAULT_HOME" "$1"; }
no_leftovers() {
  ! ls "$T/restores" 2>/dev/null | grep -q '^verify-'
  # every CREATE DATABASE of a throwaway has a matching DROP
  [ "$(grep -c 'CREATE DATABASE `cwpvault_verify_' "$STUB_LOG/mysql.log")" -eq "$(grep -c 'DROP DATABASE IF EXISTS `cwpvault_verify_' "$STUB_LOG/mysql.log")" ]
}

@test "verify-restore --account checks files and databases, then cleans up" {
  run vout verify-restore --account alice --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["account"]')" = alice ]
  [ "$(printf '%s' "$output" | jget 'd["files_checked"]')" -eq 2 ]
  [ "$(printf '%s' "$output" | jget 'd["files_ok"]')" -eq 2 ]
  [ "$(printf '%s' "$output" | jget 'd["dbs"][0]["db"]')" = alice_wp ]
  [ "$(printf '%s' "$output" | jget 'd["dbs"][0]["tables_expected"]')" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["dbs"][0]["tables_restored"]')" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["error"]')" = "" ]
  grep -q ' restore --verify latest --tag files,alice --target .*/verify-' "$STUB_LOG/restic.log"
  grep -q -- '--include=/home/alice/index.php' "$STUB_LOG/restic.log"
  grep -q ' dump --tag db:alice_wp latest /db/alice_wp.sql' "$STUB_LOG/restic.log"
  no_leftovers
  json_valid <"$(verify_file alice)"
  [ "$(jget 'd["ok"]' <"$(verify_file alice)")" = True ]
}

@test "the throwaway database has a validated name and the dump is imported without DEFINER" {
  run vault verify-restore --account alice
  [ "$status" -eq 0 ]
  [[ $output == *"alice: OK"* ]]
  grep -Eq 'CREATE DATABASE `cwpvault_verify_[0-9a-f]{8}`' "$STUB_LOG/mysql.log"
  ! grep -q DEFINER "$STUB_LOG/mysql_import.sql"
}

@test "without --account or --all exactly one account is checked and the result is an object" {
  run vout verify-restore --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'type(d).__name__')" = dict ]
  [ "$(ls "$VAULT_HOME"/var/status/verify-*.json | wc -l)" -eq 1 ]
}

@test "--all checks every account and prints an array" {
  run vout verify-restore --all --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'len(d)')" -eq 2 ]
  [ -f "$(verify_file alice)" ]
  [ -f "$(verify_file bob)" ]
  ! grep -q 'vault/_server' "$STUB_LOG/restic.log"
}

@test "--account and --all together is a usage error" {
  run vault verify-restore --account alice --all
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_LOG/restic.log" ]
}

@test "an unknown account is refused" {
  run vault verify-restore --account mallory
  [ "$status" -eq 2 ]
}

@test "a table count that differs from the dump fails, still drops the database and alerts" {
  conf_with ALERT_EMAIL=admin@example.com
  STUB_VERIFY_TABLES=2 run vout verify-restore --account alice --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
  [ "$(printf '%s' "$output" | jget 'd["dbs"][0]["ok"]')" = False ]
  [ "$(printf '%s' "$output" | jget 'd["dbs"][0]["tables_restored"]')" -eq 2 ]
  no_leftovers
  grep -q '^Subject: \[cwp-vault\] verify-restore FAILED on ' "$STUB_LOG/sendmail.in"
  grep -q 'Failed: alice' "$STUB_LOG/sendmail.in"
  [ "$(jget 'd["ok"]' <"$(verify_file alice)")" = False ]
}

@test "a failed import still drops the throwaway database" {
  STUB_IMPORT_FAIL=1 run vout verify-restore --account alice --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
  no_leftovers
  grep -q 'DROP DATABASE IF EXISTS `cwpvault_verify_' "$STUB_LOG/mysql.log"
}

@test "a restored file with the wrong size fails and the restore directory is removed" {
  STUB_VERIFY_BAD=1 run vout verify-restore --account alice --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["files_ok"]')" -eq 0 ]
  [[ $(printf '%s' "$output" | jget 'd["error"]') == *"wrong size"* ]]
  no_leftovers
}

@test "a file that was not restored fails" {
  STUB_VERIFY_MISSING=1 run vout verify-restore --account alice --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["files_ok"]')" -eq 0 ]
  no_leftovers
}

@test "a failing restic restore or listing fails the account" {
  STUB_RESTORE_FAIL=1 run vout verify-restore --account alice --json
  [ "$status" -eq 1 ]
  [[ $(printf '%s' "$output" | jget 'd["error"]') == *"restore --verify failed"* ]]
  STUB_LS_FAIL=1 run vout verify-restore --account alice --json
  [ "$status" -eq 1 ]
  [[ $(printf '%s' "$output" | jget 'd["error"]') == *"cannot list"* ]]
  no_leftovers
}

@test "an unreachable repository fails and sends an alert without leaking secrets" {
  conf_with ALERT_WEBHOOK=https://hooks.example.com/x
  STUB_CAT_RC=1 run vout verify-restore --account alice --json
  [ "$status" -eq 1 ]
  grep -q 'DATA .*"command":"verify-restore"' "$STUB_LOG/curl.log"
  ! grep -qF -e "$SECRET_KEY" -e "$SECRET_PW" "$STUB_LOG/curl.log" "$VAULT_HOME/var/log/vault.log"
}

@test "a success sends no alert and no heartbeat" {
  conf_with ALERT_EMAIL=admin@example.com HEARTBEAT_URL=https://hc.example.com/u1
  run vault verify-restore --account alice --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$STUB_LOG/sendmail.in" ]
  [ ! -e "$STUB_LOG/curl.log" ]
}

@test "not enough free space stops before any restore" {
  conf_with MIN_FREE_GB=999999
  run vault verify-restore --account alice
  [ "$status" -eq 1 ]
  ! grep -q ' restore ' "$STUB_LOG/restic.log" 2>/dev/null
}

@test "status --json reports last_verify and does not list verify files as accounts" {
  run vout status --json
  [ "$(printf '%s' "$output" | jget 'd["last_verify"]')" = None ]
  vault verify-restore --account alice --quiet
  run vout status --json
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'd["last_verify"]["ok"]')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["last_verify"]["account"]')" = alice ]
  [[ $(printf '%s' "$output" | jget 'd["last_verify"]["finished"]') == 20*Z ]]
  [ "$(printf '%s' "$output" | jget 'len(d["accounts"])')" -eq 2 ]
}

@test "the monthly cron line is installed" {
  grep -q '^0 5 1 \* \* root /usr/local/bin/vault verify-restore --quiet$' "$REPO_ROOT/contrib/cron.d/cwp-vault"
}
