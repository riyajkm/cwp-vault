#!/usr/bin/env bats
load helpers/common

setup() { vault_setup; }
teardown() { vault_teardown; }

plan() { vault backup --account alice --dry-run; }

@test "default fixture config loads and a dry run succeeds" {
  run plan
  [ "$status" -eq 0 ]
  [[ $output == *"alice: home"* ]]
}

@test "config value with \$(...) is rejected and nothing executes" {
  conf_with "ALERT_EMAIL=\$(touch $T/pwned)@example.com"
  run plan
  [ "$status" -eq 2 ]
  [ ! -e "$T/pwned" ]
}

@test "config value with a backtick is rejected and nothing executes" {
  conf_with "EXCLUDES=\`touch $T/pwned2\`"
  run plan
  [ "$status" -eq 2 ]
  [ ! -e "$T/pwned2" ]
}

@test "a shell-looking line is data, never executed" {
  printf 'touch %s/pwned3\n' "$T" >>"$VAULT_HOME/etc/vault.conf"
  run plan
  [ "$status" -eq 2 ]
  [ ! -e "$T/pwned3" ]
}

@test "unknown config key warns and is ignored" {
  conf_with "NOT_A_KEY=1"
  run plan
  [ "$status" -eq 0 ]
  [[ $output == *"unknown key NOT_A_KEY"* ]]
}

@test "http endpoint is rejected by default" {
  conf_with "S3_ENDPOINT=http://s3.example.com"
  run plan
  [ "$status" -eq 2 ]
  [[ $output == *"S3_ENDPOINT"* ]]
}

@test "http endpoint is accepted with ALLOW_INSECURE=yes" {
  conf_with "S3_ENDPOINT=http://127.0.0.1:9000" "ALLOW_INSECURE=yes"
  run plan
  [ "$status" -eq 0 ]
}

@test "endpoint with a path is rejected" {
  conf_with "S3_ENDPOINT=https://s3.example.com/bucket"
  run plan
  [ "$status" -eq 2 ]
}

@test "ALLOW_INSECURE does not relax the webhook or heartbeat URL" {
  conf_with "ALLOW_INSECURE=yes" "ALERT_WEBHOOK=http://hooks.example.com/x"
  run plan
  [ "$status" -eq 2 ]
  conf_with "ALLOW_INSECURE=yes" "HEARTBEAT_URL=http://hc.example.com/x"
  run plan
  [ "$status" -eq 2 ]
}

@test "ALERT_EMAIL with a comma, space or header text is rejected" {
  local bad
  for bad in "a@example.com,b@example.com" "a@example.com Bcc: x@example.org" "a@example.com;b@example.com" "Bcc:x@example.org"; do
    conf_with "ALERT_EMAIL=$bad"
    run plan
    [ "$status" -eq 2 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "ALERT_EMAIL with an embedded newline cannot be set via config set" {
  run vault config set "ALERT_EMAIL=a@example.com"$'\n'"Bcc: x@example.org"
  [ "$status" -eq 2 ]
  ! grep -q Bcc "$VAULT_HOME/etc/vault.conf"
}

@test "a plain ALERT_EMAIL is accepted" {
  conf_with "ALERT_EMAIL=admin@example.com"
  run plan
  [ "$status" -eq 0 ]
}

@test "value longer than 1024 characters is rejected" {
  conf_with "EXCLUDES=$(head -c 1025 /dev/zero | tr '\0' 'x')"
  run plan
  [ "$status" -eq 2 ]
  [[ $output == *"1024"* ]]
}

@test "value of exactly 1024 characters is accepted" {
  conf_with "EXCLUDES=$(head -c 1024 /dev/zero | tr '\0' 'x')"
  run plan
  [ "$status" -eq 0 ]
}

@test "NUL byte in the config file is rejected" {
  printf 'S3_PREFIX=a\0b\n' >>"$VAULT_HOME/etc/vault.conf"
  run plan
  [ "$status" -eq 2 ]
  [[ $output == *"NUL"* ]]
}

@test "non-numeric and out-of-range numbers are rejected" {
  local bad
  for bad in "S3_CONNECTIONS=abc" "S3_CONNECTIONS=0" "RETRIES=11" "KEEP_DAILY=-1" "BACKUP_MAIL=maybe" "CHECK_SUBSET=lots" "ACCOUNT_TIMEOUT=forever"; do
    conf_with "$bad"
    run plan
    [ "$status" -eq 2 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "bucket and prefix charset is enforced" {
  conf_with "S3_BUCKET=Bad_Bucket"
  run plan
  [ "$status" -eq 2 ]
  conf_with "S3_PREFIX=../escape/"
  run plan
  [ "$status" -eq 2 ]
}

@test "missing endpoint is a config error" {
  printf 'S3_BUCKET=example-backups\n' >"$VAULT_HOME/etc/vault.conf"
  chmod 640 "$VAULT_HOME/etc/vault.conf"
  run plan
  [ "$status" -eq 2 ]
}

@test "world-writable vault.conf is refused" {
  chmod 666 "$VAULT_HOME/etc/vault.conf"
  run plan
  [ "$status" -eq 2 ]
  [[ $output == *"too open"* ]]
}

@test "group/world-readable secrets.env is refused" {
  chmod 644 "$VAULT_HOME/etc/secrets.env"
  run plan
  [ "$status" -eq 2 ]
  [[ $output == *"too open"* ]]
}

@test "secrets.env missing a required key is a config error" {
  printf 'AWS_ACCESS_KEY_ID=%s\n' "$SECRET_KEY_ID" >"$VAULT_HOME/etc/secrets.env"
  chmod 600 "$VAULT_HOME/etc/secrets.env"
  run plan
  [ "$status" -eq 2 ]
}

@test "secrets.env value with a command substitution is not executed" {
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nRESTIC_PASSWORD=$(touch %s/pwned4)\n' "$SECRET_KEY_ID" "$SECRET_KEY" "$T" >"$VAULT_HOME/etc/secrets.env"
  chmod 600 "$VAULT_HOME/etc/secrets.env"
  run plan
  [ ! -e "$T/pwned4" ]
}

@test "config set validates every pair before writing anything" {
  before=$(cksum <"$VAULT_HOME/etc/vault.conf")
  run vault config set KEEP_DAILY=9 S3_CONNECTIONS=abc
  [ "$status" -eq 2 ]
  [ "$(cksum <"$VAULT_HOME/etc/vault.conf")" = "$before" ]
}

@test "config set rejects unknown keys, quotes and secret keys" {
  run vault config set NOPE=1
  [ "$status" -eq 2 ]
  run vault config set 'ALERT_EMAIL="a@example.com"'
  [ "$status" -eq 2 ]
  run vault config set RESTIC_PASSWORD=x
  [ "$status" -eq 2 ]
}

@test "config set writes the value and reports what changed" {
  need_python
  run vout config set KEEP_DAILY=9 KEEP_WEEKLY=4
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["changed"]')" = "['KEEP_DAILY']" ]
  grep -q '^KEEP_DAILY=9$' "$VAULT_HOME/etc/vault.conf"
  grep -q '^S3_BUCKET=example-backups$' "$VAULT_HOME/etc/vault.conf"
}
