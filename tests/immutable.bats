#!/usr/bin/env bats
load helpers/common

setup() {
  vault_setup
  need_python
  unset STUB_LOCK_MISSING STUB_LOCK_ENABLED STUB_LOCK_MODE STUB_LOCK_DAYS STUB_LIFECYCLE_FILE STUB_DELETE_FAIL STUB_DELETE_ERRORS STUB_MARKERS
  export STUB_LOG
}
teardown() { vault_teardown; }

aws_log() { cat "$STUB_LOG/aws.log" 2>/dev/null || true; }

@test "config: immutable keys default to no, COMPLIANCE, 14" {
  run vout config get --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["IMMUTABLE"] + d["LOCK_MODE"] + d["LOCK_DAYS"]')" = noCOMPLIANCE14 ]
}

@test "config: bad IMMUTABLE, LOCK_MODE and LOCK_DAYS are refused with exit 2" {
  local bad
  for bad in IMMUTABLE=maybe LOCK_MODE=FOO LOCK_MODE=compliance LOCK_DAYS=0 LOCK_DAYS=3651 LOCK_DAYS=abc LOCK_DAYS=; do
    conf_with "$bad"
    run vault init
    [ "$status" -eq 2 ]
  done
  conf_with LOCK_DAYS=3650 LOCK_MODE=GOVERNANCE IMMUTABLE=no
  run vault snapshots --account alice
  [ "$status" -eq 0 ]
}

@test "recover refuses when IMMUTABLE=no" {
  run vault recover --account alice --yes
  [ "$status" -eq 2 ]
  [[ $output == *"immutable mode"* ]]
  [ ! -e "$STUB_LOG/aws.log" ]
  [ ! -e "$STUB_LOG/restic.log" ]
}

@test "recover needs --account or --all" {
  conf_with IMMUTABLE=yes
  run vault recover
  [ "$status" -eq 2 ]
}

@test "init without immutable mode never calls aws" {
  run vault init
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_LOG/aws.log" ]
}

@test "immutable init without the aws CLI exits 2 and says so" {
  rm "$T/bin/aws"
  command -v aws >/dev/null 2>&1 && skip "a real aws CLI is installed"
  conf_with IMMUTABLE=yes
  run vault init
  [ "$status" -eq 2 ]
  [[ $output == *"aws CLI"* ]]
  [ ! -e "$STUB_LOG/restic.log" ]
}

@test "immutable init refuses a bucket without object lock" {
  conf_with IMMUTABLE=yes
  STUB_LOCK_MISSING=1 run vault init
  [ "$status" -eq 2 ]
  [[ $output == *"Object Lock"* ]]
  [ ! -e "$STUB_LOG/restic.log" ]
  STUB_LOCK_ENABLED=Disabled run vault init
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_LOG/restic.log" ]
}

@test "immutable init refuses a weaker mode or shorter retention" {
  conf_with IMMUTABLE=yes
  STUB_LOCK_MODE=GOVERNANCE run vault init
  [ "$status" -eq 2 ]
  [[ $output == *"GOVERNANCE"* ]]
  STUB_LOCK_DAYS=7 run vault init
  [ "$status" -eq 2 ]
  [[ $output == *"7 days"* ]]
  [ ! -e "$STUB_LOG/restic.log" ]
  ! aws_log | grep -q put-bucket-lifecycle
}

@test "immutable init accepts a longer retention, creates repos and sets the lifecycle rule" {
  conf_with IMMUTABLE=yes
  STUB_NOREPO=1 STUB_LOCK_DAYS=30 run vault init
  [ "$status" -eq 0 ]
  grep -q 'vault/alice | .*init' "$STUB_LOG/restic.log"
  [ "$(count_lines put-bucket-lifecycle "$STUB_LOG/aws.log")" -eq 1 ]
  aws_log | grep -q -- '--endpoint-url https://s3.example.com'
  [ "$(jget 'd["Rules"][0]["ID"]' <"$STUB_LOG/lifecycle.json")" = cwp-vault-noncurrent ]
  [ "$(jget 'd["Rules"][0]["NoncurrentVersionExpiration"]["NoncurrentDays"]' <"$STUB_LOG/lifecycle.json")" = 21 ]
  [ "$(jget 'd["Rules"][0]["Filter"]["Prefix"]' <"$STUB_LOG/lifecycle.json")" = srv1/vault/ ]
  # credentials reach aws through the environment only
  ! aws_log | grep -q "$SECRET_KEY"
  grep -q 'key_in_env=yes' "$STUB_LOG/aws.env.log"
}

@test "lifecycle merge keeps foreign rules and replaces only our own" {
  conf_with IMMUTABLE=yes LOCK_DAYS=10
  cat >"$T/rules.json" <<'JSON'
{"Rules":[{"ID":"foreign-logs","Status":"Enabled","Filter":{"Prefix":"logs/"},"Expiration":{"Days":30}},
          {"ID":"cwp-vault-noncurrent","Status":"Enabled","Filter":{"Prefix":"old/"},"NoncurrentVersionExpiration":{"NoncurrentDays":99}}]}
JSON
  STUB_LIFECYCLE_FILE=$T/rules.json run vault init
  [ "$status" -eq 0 ]
  [ "$(jget 'sorted(r["ID"] for r in d["Rules"])' <"$STUB_LOG/lifecycle.json")" = "['cwp-vault-noncurrent', 'foreign-logs']" ]
  [ "$(jget '[r for r in d["Rules"] if r["ID"] == "foreign-logs"][0]["Expiration"]["Days"]' <"$STUB_LOG/lifecycle.json")" = 30 ]
  [ "$(jget '[r for r in d["Rules"] if r["ID"] != "foreign-logs"][0]["NoncurrentVersionExpiration"]["NoncurrentDays"]' <"$STUB_LOG/lifecycle.json")" = 17 ]
  # a second init finds our rule unchanged and does not write again
  run vault init
  [ "$status" -eq 0 ]
  [ "$(count_lines put-bucket-lifecycle "$STUB_LOG/aws.log")" -eq 1 ]
}

@test "recover dry run lists counts and changes nothing" {
  conf_with IMMUTABLE=yes
  run vault recover --all
  [ "$status" -eq 0 ]
  [[ $output == *"alice: 3 delete markers, removed 0"* ]]
  [[ $output == *"bob: 0 delete markers"* ]]
  [[ $output == *"Dry run"* ]]
  ! aws_log | grep -q delete-objects
  [ ! -e "$STUB_LOG/restic.log" ]
  aws_log | grep -q -- '--prefix srv1/vault/alice/'
}

@test "recover --before only counts newer delete markers" {
  conf_with IMMUTABLE=yes
  run vout recover --account alice --before 2026-10-28T00:00:00Z --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["delete_markers"]')" -eq 2 ]
  run vault recover --account alice --before "not a time"
  [ "$status" -eq 2 ]
}

@test "recover --yes removes each delete marker, then unlocks and checks" {
  conf_with IMMUTABLE=yes
  run vout recover --account alice --yes --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["removed"]')" -eq 3 ]
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["check"]')" = ok ]
  [ "$(count_lines delete-objects "$STUB_LOG/aws.log")" -eq 1 ]
  ! aws_log | grep -q 'delete-object --'
  grep -q '"Quiet":true' "$STUB_LOG/aws.delete.json"
  grep -q '{"Key":"srv1/vault/alice/locks/bb","VersionId":"m2"}' "$STUB_LOG/aws.delete.json"
  local u c
  u=$(grep -n 'vault/alice | .*unlock --remove-all' "$STUB_LOG/restic.log" | head -n1 | cut -d: -f1)
  c=$(grep -n 'vault/alice | .*check' "$STUB_LOG/restic.log" | head -n1 | cut -d: -f1)
  [ -n "$u" ] && [ -n "$c" ] && [ "$u" -lt "$c" ]
  ! grep -q 'vault/bob' "$STUB_LOG/restic.log"
  grep -q ' recover accounts=alice before=all removed=3 result=ok' "$VAULT_HOME/var/log/audit.log"
}

@test "recover --yes stops and skips the check when a marker cannot be removed" {
  conf_with IMMUTABLE=yes
  STUB_DELETE_FAIL=1 run vout recover --account alice --yes --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["removed"]')" -eq 0 ]
  [ ! -e "$STUB_LOG/restic.log" ]
}

@test "recover --yes removes markers in batches of at most 1000" {
  need_python
  conf_with IMMUTABLE=yes
  STUB_MARKERS=2497 run vout recover --account alice --yes --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["delete_markers"]')" -eq 2500 ]
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["removed"]')" -eq 2500 ]
  [ "$(count_lines delete-objects "$STUB_LOG/aws.log")" -eq 3 ]
  [ "$(grep -o '"VersionId"' "$STUB_LOG/aws.delete.json" | wc -l)" -eq 2500 ]
  [ "$(grep -c '^{"Objects"' "$STUB_LOG/aws.delete.json")" -eq 3 ]
}

@test "recover --yes fails when S3 reports errors in the delete-objects answer" {
  need_python
  conf_with IMMUTABLE=yes
  STUB_DELETE_ERRORS=1 run vout recover --account alice --yes --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["removed"]')" -eq 2 ]
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["check"]')" = skipped ]
  [ ! -e "$STUB_LOG/restic.log" ]
}

@test "status --json reports the immutable settings" {
  run vout status --json
  [ "$(printf '%s' "$output" | jget 'd["immutable"]')" = "{'enabled': False, 'mode': 'COMPLIANCE', 'days': 14}" ]
  conf_with IMMUTABLE=yes LOCK_MODE=GOVERNANCE LOCK_DAYS=30
  run vout status --json
  [ "$(printf '%s' "$output" | jget 'd["immutable"]')" = "{'enabled': True, 'mode': 'GOVERNANCE', 'days': 30}" ]
  rm "$VAULT_HOME/etc/vault.conf"
  run vout status --json
  [ "$(printf '%s' "$output" | jget 'd["immutable"]["enabled"]')" = False ]
}
