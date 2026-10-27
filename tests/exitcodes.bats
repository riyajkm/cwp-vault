#!/usr/bin/env bats
load helpers/common

setup() { vault_setup; }
teardown() { vault_teardown; }

@test "exit 0: backup of all accounts succeeds" {
  run vault backup --all
  [ "$status" -eq 0 ]
}

@test "exit 0: version, help and no arguments" {
  run vault version
  [ "$status" -eq 0 ]
  [ "$output" = "cwp-vault 0.2.0" ]
  run vault --help
  [ "$status" -eq 0 ]
  [[ $output == *"Exit codes"* ]]
  run vault
  [ "$status" -eq 0 ]
  run vault backup --help
  [ "$status" -eq 0 ]
  [[ $output == *"vault backup"* ]]
}

@test "exit 1: some accounts failed" {
  export STUB_DUMP_FAIL=bob_main
  run vault backup --all
  [ "$status" -eq 1 ]
}

@test "exit 1: wrong restic password (rc 12) is not a storage outage" {
  export STUB_CAT_RC=12
  run vault backup --all
  [ "$status" -eq 1 ]
}

@test "exit 2: unknown command, unknown option, missing arguments" {
  run vault frobnicate
  [ "$status" -eq 2 ]
  run vault backup --bogus
  [ "$status" -eq 2 ]
  run vault backup --account
  [ "$status" -eq 2 ]
  run vault backup
  [ "$status" -eq 2 ]
  run vault prune
  [ "$status" -eq 2 ]
}

@test "exit 2: stray positional arguments are rejected" {
  run vault status extra-positional
  [ "$status" -eq 2 ]
  run vault backup --account alice stray
  [ "$status" -eq 2 ]
}

@test "exit 2: config problem" {
  rm "$VAULT_HOME/etc/vault.conf"
  run vault backup --all
  [ "$status" -eq 2 ]
}

@test "exit 4: storage unreachable for every account" {
  export STUB_CAT_RC=1
  run vault backup --all
  [ "$status" -eq 4 ]
}

@test "exit 4: test-storage and verify of an unreachable store" {
  export STUB_CAT_RC=1
  run vault test-storage
  [ "$status" -eq 4 ]
}

@test "prune, check and unlock run restic per account and exit 0" {
  run vault prune --all
  [ "$status" -eq 0 ]
  grep -q ' forget --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune' "$STUB_LOG/restic.log"
  run vault check --account alice
  [ "$status" -eq 0 ]
  grep -q ' check --read-data-subset 5%' "$STUB_LOG/restic.log"
  run vault unlock --all
  [ "$status" -eq 0 ]
}

@test "prune exits 1 when restic fails for an account" {
  cat >"$T/bin/restic" <<'WRAP'
#!/usr/bin/env bash
case " $* " in *" cat "*) exit 0 ;; *) echo "Fatal: boom" >&2; exit 1 ;; esac
WRAP
  run vault prune --all
  [ "$status" -eq 1 ]
}

@test "verify-secrets reports a missing and a wrong-password repository" {
  export STUB_NOREPO=1
  run vault verify-secrets
  [ "$status" -ne 0 ]
  [[ $output == *MISSING* ]]
  export STUB_NOREPO= STUB_CAT_RC=12
  run vault verify-secrets
  [ "$status" -ne 0 ]
  [[ $output == *"WRONG PASSWORD"* ]]
}

@test "dry-run backup writes nothing and does not ping alerts" {
  conf_with "HEARTBEAT_URL=https://hc.example.com/u1"
  run vault backup --all --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_LOG/curl.log" ]
}

# ---- alerts ----

@test "a failing backup sends one email with fixed headers and no secrets" {
  conf_with "ALERT_EMAIL=admin@example.com"
  export STUB_DUMP_FAIL=alice_wp
  run vault backup --all
  [ "$status" -eq 1 ]
  [ "$(grep -c '^To:' "$STUB_LOG/sendmail.in")" -eq 1 ]
  grep -q '^To: admin@example.com$' "$STUB_LOG/sendmail.in"
  grep -q '^Subject: \[cwp-vault\] backup FAILED on ' "$STUB_LOG/sendmail.in"
  grep -q 'Failed: alice' "$STUB_LOG/sendmail.in"
  grep -q -- '-t' "$STUB_LOG/sendmail.log"
  ! grep -qF -e "$SECRET_KEY" -e "$SECRET_PW" "$STUB_LOG/sendmail.in"
}

@test "a successful backup sends no email" {
  conf_with "ALERT_EMAIL=admin@example.com"
  run vault backup --all
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_LOG/sendmail.in" ]
}

@test "webhook payload carries counts and failed names only, over https with no redirects" {
  need_python
  conf_with "ALERT_WEBHOOK=https://hooks.example.com/x"
  export STUB_FAIL_FILES=1
  run vault backup --account alice
  [ "$status" -eq 1 ]
  grep -q -- '--proto =https' "$STUB_LOG/curl.log"
  grep -q -- '--max-time 20' "$STUB_LOG/curl.log"
  grep -q -- '--max-redirs 0' "$STUB_LOG/curl.log"
  ! grep -q 'hooks.example.com' <(grep -v '^CONFIG' "$STUB_LOG/curl.log" | grep -v '^DATA')   # URL not on argv
  body=$(grep '^DATA ' "$STUB_LOG/curl.log" | sed 's/^DATA //')
  json_valid <<<"$body"
  [ "$(jget 'd["failed_accounts"]' <<<"$body")" = "['alice']" ]
  [[ $body != *"/home/"* ]]
  [[ $body != *"$SECRET_KEY"* && $body != *"$SECRET_PW"* ]]
}

@test "heartbeat pings start then success, or start then fail" {
  conf_with "HEARTBEAT_URL=https://hc.example.com/u1"
  run vault backup --all
  [ "$status" -eq 0 ]
  mapfile -t cfg < <(grep '^CONFIG ' "$STUB_LOG/curl.log")
  [ "${cfg[0]}" = 'CONFIG url = "https://hc.example.com/u1/start"' ]
  [ "${cfg[1]}" = 'CONFIG url = "https://hc.example.com/u1"' ]
  rm "$STUB_LOG/curl.log"
  export STUB_DUMP_FAIL=bob_main
  run vault backup --all
  mapfile -t cfg < <(grep '^CONFIG ' "$STUB_LOG/curl.log")
  [ "${cfg[1]}" = 'CONFIG url = "https://hc.example.com/u1/fail"' ]
}

@test "alert delivery problems never change the exit code" {
  conf_with "ALERT_EMAIL=admin@example.com" "ALERT_WEBHOOK=https://hooks.example.com/x"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' >"$T/bin/sendmail"
  printf '#!/usr/bin/env bash\nexit 22\n' >"$T/bin/curl"
  export STUB_DUMP_FAIL=alice_wp
  run vault backup --all
  [ "$status" -eq 1 ]
}
