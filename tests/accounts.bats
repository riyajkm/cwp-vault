#!/usr/bin/env bats
load helpers/common

setup() { vault_setup; }
teardown() { vault_teardown; }

@test "dry run lists discovered accounts with domains and databases" {
  run vault backup --all --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"alice: home $T/home/alice; mail domains: example.com"* ]]
  [[ $output == *"alice_wp"* && $output == *"alice_shop"* ]]
  [[ $output == *"bob: home $T/home/bob; mail domains: example.org"* ]]
  [[ $output == *"bob_main"* ]]
}

@test "dry run does not call restic or write a status file" {
  run vault backup --all --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_LOG/restic.log" ]
  [ -z "$(ls "$VAULT_HOME/var/status")" ]
}

@test "invalid usernames from MySQL are skipped with a warning" {
  export STUB_USERS='alice\nBob\nbad-name\n1x\nbob;DROP\nbob'
  run vault backup --all --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"invalid username"* ]]
  [[ $output == *"alice: home"* && $output == *"bob: home"* ]]
  [[ $output != *"Bob"* && $output != *"bad-name"* && $output != *"DROP"* ]]
  # only the two valid accounts are planned
  [ "$(printf '%s\n' "$output" | grep -c ': home ')" -eq 2 ]
}

@test "ACCOUNTS limits discovery to the listed usernames" {
  conf_with "ACCOUNTS=bob"
  run vault backup --all --dry-run
  [[ $output == *"bob: home"* ]]
  [[ $output != *"alice: home"* ]]
}

@test "EXCLUDE_ACCOUNTS removes accounts" {
  conf_with "EXCLUDE_ACCOUNTS=bob"
  run vault backup --all --dry-run
  [[ $output == *"alice: home"* ]]
  [[ $output != *"bob: home"* ]]
}

@test "--account for a user MySQL does not know is refused" {
  run vault backup --account carol --dry-run
  [ "$status" -eq 2 ]
  [[ $output == *"unknown account"* ]]
}

@test "--account with an invalid name is refused" {
  run vault backup --account 'Alice;x' --dry-run
  [ "$status" -eq 2 ]
  [[ $output == *"invalid account name"* ]]
}

@test "databases outside the account prefix are skipped" {
  export STUB_DBS_alice='alice_wp\nbob_stolen\nalice_bad-name\nalice\nmysql'
  run vault backup --account alice --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"alice_wp"* ]]
  [[ $output != *"bob_stolen"* && $output != *"alice_bad-name"* ]]
  [[ $output == *"unexpected name"* ]]
}

@test "invalid domain names (traversal) are skipped and never used as a mail path" {
  export STUB_DOM_alice='example.com\n../../etc\nFoo.COM'
  mkdir -p "$T/vmail/foo.com"
  run vault backup --account alice --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"example.com"* ]]
  [[ $output == *"foo.com"* ]]
  [[ $output != *"etc"* ]]
  [[ $output == *"invalid domain"* ]]
}

@test "a MySQL failure during discovery exits 1 with a clear error" {
  export STUB_MYSQL_FAIL=1
  run vault backup --all --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"cannot read account list"* ]]
}
