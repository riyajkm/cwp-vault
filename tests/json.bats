#!/usr/bin/env bats
load helpers/common

setup() { vault_setup; need_python; }
teardown() { vault_teardown; }

@test "status --json on a fresh install" {
  run vout status --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'sorted(d.keys())')" = "['accounts', 'configured', 'immutable', 'last_verify', 'now_epoch', 'running', 'schedule', 'server', 'version']" ]
  [ "$(printf '%s' "$output" | jget 'd["version"]')" = 0.2.0 ]
  [ "$(printf '%s' "$output" | jget 'd["configured"]')" = True ]
  # every discovered account is listed; none has run yet
  [ "$(printf '%s' "$output" | jget 'all(a["result"] == "never" for a in d["accounts"])')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["server"]')" = None ]
  [ "$(printf '%s' "$output" | jget 'd["running"]')" = "[]" ]
}

@test "status --json says configured false without a config" {
  rm "$VAULT_HOME/etc/vault.conf"
  run vout status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["configured"]')" = False ]
}

@test "status --json after backups lists accounts and the server entry" {
  conf_with "BACKUP_SERVER=yes"
  mkdir -p "$T/etc-fake"
  run vault backup --all
  run vout status --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'sorted(a["account"] for a in d["accounts"])')" = "['alice', 'bob']" ]
  [ "$(printf '%s' "$output" | jget 'sorted(d["accounts"][0].keys())')" = "['account', 'bytes_added', 'duration_s', 'error', 'finished', 'result', 'snapshots', 'started']" ]
  [ "$(printf '%s' "$output" | jget 'd["server"]["account"]')" = _server ]
  [ "$(printf '%s' "$output" | jget 'type(d["accounts"][0]["snapshots"]).__name__')" = int ]
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["snapshots"]')" -eq 5 ]
  [ "$(printf '%s' "$output" | jget 'd["accounts"][0]["bytes_added"]')" -gt 0 ]
}

@test "status --json escapes a hostile error text" {
  mkdir -p "$VAULT_HOME/var/status"
  printf '{\n  "account": "zed",\n  "started": "s",\n  "finished": "f",\n  "duration_s": 1,\n  "result": "failed",\n  "snapshots": [],\n  "files_new": 0,\n  "files_changed": 0,\n  "bytes_added": 0,\n  "error": "bad \\"quote\\" and \\\\ slash"\n}\n' >"$VAULT_HOME/var/status/zed.json"
  run vout status --json
  json_valid <<<"$output"
}

@test "status without --json prints a table or a hint" {
  run vault status
  [ "$status" -eq 0 ]
  [[ $output == *"No backups recorded"* ]]
  vault backup --account alice >/dev/null 2>&1
  run vault status
  [[ $output == *ACCOUNT* && $output == *alice* ]]
}

@test "snapshots --json has the specified fields and kinds" {
  run vout snapshots --account alice --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'sorted(d[0].keys())')" = "['db', 'id', 'kind', 'paths', 'short_id', 'size', 'tags', 'time']" ]
  [ "$(printf '%s' "$output" | jget '[s["kind"] for s in d]')" = "['files', 'db', 'meta']" ]
  [ "$(printf '%s' "$output" | jget '[s["db"] for s in d]')" = "[None, 'alice_wp', None]" ]
  [ "$(printf '%s' "$output" | jget 'd[0]["size"]')" -eq 1000 ]
  [ "$(printf '%s' "$output" | jget 'd[1]["size"]')" = None ]
  [ "$(printf '%s' "$output" | jget 'd[0]["short_id"]')" = aaaaaaaa ]
}

@test "snapshots for an invalid account gives the JSON error contract" {
  run vout snapshots --account 'x;y' --json
  [ "$status" -eq 2 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'd["code"]')" -eq 2 ]
  [ "$(printf '%s' "$output" | jget 'type(d["error"]).__name__')" = str ]
}

@test "snapshots with unreachable storage gives code 4 and exit 4" {
  export STUB_CAT_RC=1
  # snapshots goes through restic_run; make that fail too
  cat >"$T/bin/restic" <<'WRAP'
#!/usr/bin/env bash
echo "Fatal: unable to open repository" >&2
exit 1
WRAP
  run vout snapshots --account alice --json
  [ "$status" -eq 4 ]
  [ "$(printf '%s' "$output" | jget 'd["code"]')" -eq 4 ]
}

@test "snapshots needs --account" {
  run vout snapshots --json
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jget 'd["code"]')" -eq 2 ]
}

@test "ls --json lists one directory level" {
  run vout ls --account alice --snapshot latest --path /home/alice --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget '[e["name"] for e in d]')" = "['index.php']" ]
  [ "$(printf '%s' "$output" | jget 'sorted(d[0].keys())')" = "['mtime', 'name', 'path', 'size', 'type']" ]
}

@test "ls refuses a path with .." {
  run vout ls --account alice --path /home/alice/../bob --json
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jget 'd["code"]')" -eq 2 ]
}

@test "config get --json returns every non-secret key and no secrets" {
  run vout config get --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'd["S3_BUCKET"]')" = example-backups ]
  [ "$(printf '%s' "$output" | jget 'd["KEEP_DAILY"]')" = 7 ]
  [ "$(printf '%s' "$output" | jget 'd["S3_ENDPOINT"]')" = https://s3.example.com ]
  [ "$(printf '%s' "$output" | jget '[k for k in d if "AWS" in k or "RESTIC" in k]')" = "[]" ]
  [[ $output != *"$SECRET_KEY"* && $output != *"$SECRET_PW"* ]]
  for k in S3_ENDPOINT S3_BUCKET S3_PREFIX ACCOUNTS EXCLUDE_ACCOUNTS EXCLUDES BACKUP_MAIL BACKUP_DATABASES BACKUP_SERVER S3_CONNECTIONS LIMIT_UPLOAD_KIB KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY CHECK_SUBSET ALERT_EMAIL ALERT_WEBHOOK HEARTBEAT_URL RETRIES; do
    [ "$(printf '%s' "$output" | jget "'$k' in d")" = True ] || { echo "missing $k"; return 1; }
  done
}

@test "config get --json works with an invalid config (it only reads)" {
  conf_with "S3_ENDPOINT=http://insecure.example.com"
  run vout config get --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
}

@test "log --tail N --json returns at most N lines" {
  vault backup --all >/dev/null 2>&1
  run vout log --tail 3 --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'len(d["lines"])')" -eq 3 ]
  [[ $(printf '%s' "$output" | jget 'd["lines"][0]') =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ (INFO|WARN|ERROR)\  ]]
}

@test "log --tail json with no log file is an empty list" {
  rm -f "$VAULT_HOME/var/log/vault.log"
  # vault_dirs recreates an empty file; either way the result is an empty list
  run vout log --tail 5 --json
  [ "$(printf '%s' "$output" | jget 'd["lines"]')" = "[]" ]
}

@test "log --tail rejects non-numbers with the JSON error contract" {
  run vout log --tail abc --json
  [ "$status" -eq 2 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'd["code"]')" -eq 2 ]
}

@test "log --tail without --json prints plain lines" {
  vault backup --account alice >/dev/null 2>&1
  run vault log --tail 2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "test-storage --json reports ok with timings" {
  run vout test-storage --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'sorted(d.keys())')" = "['delete_ms', 'error', 'ok', 'read_ms', 'write_ms']" ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["error"]')" = "" ]
  grep -q ' forget deadbeef.* --prune' "$STUB_LOG/restic.log"
}

@test "test-storage --json with unreachable storage is ok false, exit 4" {
  export STUB_CAT_RC=1
  run vout test-storage --json
  [ "$status" -eq 4 ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
}

@test "init --json reports created and existing repos" {
  export STUB_NOREPO=1
  run vout init --json
  [ "$status" -eq 0 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'sorted(d["created"])')" = "['alice', 'bob']" ]
}

@test "usage errors with --json print {error, code 2} on stdout" {
  run vout restore --json
  [ "$status" -eq 2 ]
  json_valid <<<"$output"
  [ "$(printf '%s' "$output" | jget 'd["code"]')" -eq 2 ]
}
