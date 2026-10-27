#!/usr/bin/env bats
load helpers/common

setup() {
  vault_setup
  need_python
  unset STUB_REPOS STUB_SNAP_DAY STUB_USERS STUB_DELETE_FAIL
}
teardown() { vault_teardown; }

aws_log() { cat "$STUB_LOG/aws.log" 2>/dev/null || true; }
today() { date -u +%Y-%m-%d; }

@test "orphans lists repositories whose account is gone, never _server or live accounts" {
  run vout orphans --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'len(d["orphans"])')" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["orphans"][0]["account"]')" = ghost ]
  [ "$(printf '%s' "$output" | jget 'd["orphans"][0]["last_snapshot"]')" = 2026-01-01T01:32:00Z ]
  [ "$(printf '%s' "$output" | jget 'd["orphans"][0]["purge_due"]')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["keep_days"]')" -eq 30 ]
  aws_log | grep -q -- 'list-objects-v2 --bucket example-backups --prefix srv1/vault/ --delimiter /'
  ! grep -q 'vault/alice \|vault/bob \|vault/_server ' "$STUB_LOG/restic.log"
}

@test "orphans without --purge changes nothing" {
  run vault orphans
  [ "$status" -eq 0 ]
  [[ $output == *"ghost: newest snapshot 2026-01-01T01:32:00Z"* ]]
  [[ $output == *"purge due"* ]]
  ! grep -q ' forget ' "$STUB_LOG/restic.log"
}

@test "orphans reports none when every repository has an account" {
  STUB_REPOS="alice bob _server" run vault orphans
  [ "$status" -eq 0 ]
  [[ $output == *"No orphan repositories."* ]]
}

@test "an account that is excluded from backups is not an orphan" {
  conf_with EXCLUDE_ACCOUNTS=bob
  STUB_REPOS="alice bob _server" run vault orphans
  [[ $output == *"No orphan repositories."* ]]
}

@test "orphans --purge without --yes is a dry run" {
  run vault orphans --purge
  [ "$status" -eq 0 ]
  [[ $output == *"Dry run"* ]]
  ! grep -q ' forget ' "$STUB_LOG/restic.log"
}

@test "orphans --yes without --purge is a usage error" {
  run vault orphans --yes
  [ "$status" -eq 2 ]
}

@test "orphans --purge --yes forgets with --keep-within and prune, only on due orphans" {
  run vout orphans --purge --yes --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["orphans"][0]["purged"]')" = True ]
  grep -q 'vault/ghost | .* forget --keep-within 30d --prune' "$STUB_LOG/restic.log"
  [ "$(count_lines ' forget ' "$STUB_LOG/restic.log")" -eq 1 ]
  ! grep -q ' init\| rewrite\| key ' "$STUB_LOG/restic.log"
  grep -q ' orphans-purge account=ghost keep_days=30 result=ok' "$VAULT_HOME/var/log/audit.log"
}

@test "a recent orphan is not purged" {
  STUB_SNAP_DAY=$(today) run vout orphans --purge --yes --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["orphans"][0]["purge_due"]')" = False ]
  [ "$(printf '%s' "$output" | jget 'd["orphans"][0]["purged"]')" = False ]
  ! grep -q ' forget ' "$STUB_LOG/restic.log"
}

@test "ORPHAN_KEEP_DAYS=0 never purges" {
  conf_with ORPHAN_KEEP_DAYS=0
  run vault orphans --purge --yes
  [ "$status" -eq 2 ]
  run vout orphans --json
  [ "$(printf '%s' "$output" | jget 'd["orphans"][0]["purge_due"]')" = False ]
  ! grep -q ' forget ' "$STUB_LOG/restic.log"
}

@test "ORPHAN_KEEP_DAYS is validated" {
  conf_with ORPHAN_KEEP_DAYS=soon
  run vault orphans
  [ "$status" -eq 2 ]
  conf_with ORPHAN_KEEP_DAYS=08
  run vault orphans
  [ "$status" -eq 0 ]
}

@test "a failing forget exits 1 and reports the error" {
  need_python
  cat >"$T/bin/restic" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" forget "*) echo "Fatal: boom" >&2; exit 1 ;;
  *" snapshots "*) echo '[{"id":"aa","time":"2026-01-01T01:30:00Z","tags":["files"]}]' ;;
esac
exit 0
EOF
  chmod +x "$T/bin/restic"
  run vout orphans --purge --yes --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
  [[ $(printf '%s' "$output" | jget 'd["orphans"][0]["error"]') == *"boom"* ]]
}

@test "immutable mode adds a note that the objects stay until the lock expires" {
  conf_with IMMUTABLE=yes LOCK_DAYS=14
  run vout orphans --purge --yes --json
  [ "$status" -eq 0 ]
  [[ $(printf '%s' "$output" | jget 'd["note"]') == *"object lock"*"21 days"* ]]
}

@test "without the aws CLI orphans warns and skips; purge refuses" {
  rm "$T/bin/aws"
  command -v aws >/dev/null 2>&1 && skip "a real aws CLI is installed"
  run vault orphans
  [ "$status" -eq 0 ]
  [[ $output == *"aws CLI"* ]]
  run vault orphans --purge --yes
  [ "$status" -eq 2 ]
}

@test "an empty CWP account list is never read as 'everything is an orphan'" {
  STUB_USERS="" run vault orphans --purge --yes
  [ "$status" -ne 0 ]
  ! grep -q ' forget ' "$STUB_LOG/restic.log" 2>/dev/null
}

@test "prune --all reports orphans but never purges them" {
  run vault prune --all
  [ "$status" -eq 0 ]
  [[ $output == *"orphan: ghost"* ]]
  ! grep -q 'vault/ghost | .* forget' "$STUB_LOG/restic.log"
}

@test "prune --all --quiet prints no orphan line, and prune of one account does not look" {
  run vault prune --all --quiet
  [ "$status" -eq 0 ]
  [[ $output != *"orphan"* ]]
  rm -f "$STUB_LOG/aws.log"
  run vault prune --account alice
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_LOG/aws.log" ]
}
