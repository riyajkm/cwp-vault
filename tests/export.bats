#!/usr/bin/env bats
load helpers/common

PW='correct horse staple 42'

setup() { vault_setup; }
teardown() { vault_teardown; }

wait_job() {
  local i
  for i in $(seq 1 300); do
    if grep -q '"state":"\(done\|failed\)"' "$(status_file "restore-$1")" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
}

ex() { vault export --account alice --snapshot deadbeef01 "$@"; }

@test "a files export writes a private tar.gz, a record and a job result" {
  need_python
  run vout export --account alice --what files --snapshot deadbeef01 --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'sorted(d.keys())')" = "['bytes', 'encrypted', 'error', 'expires', 'file', 'job', 'ok', 'sha256']" ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["encrypted"]')" = False ]
  job=$(printf '%s' "$output" | jget 'd["job"]')
  f=$(printf '%s' "$output" | jget 'd["file"]')
  [ "$f" = "$job.tar.gz" ]
  [ "$(stat -c %a "$VAULT_EXPORT_ROOT")" = 700 ]
  [ "$(stat -c %a "$VAULT_EXPORT_ROOT/$f")" = 600 ]
  [ "$(printf '%s' "$output" | jget 'd["bytes"]')" = "$(stat -c %s "$VAULT_EXPORT_ROOT/$f")" ]
  [ "$(printf '%s' "$output" | jget 'd["sha256"]')" = "$(sha256sum "$VAULT_EXPORT_ROOT/$f" | cut -d' ' -f1)" ]
  gzip -t "$VAULT_EXPORT_ROOT/$f"
  grep -q "dump --archive tar deadbeef01 $T/home/alice" "$STUB_LOG/restic.log"
  grep -q "export job=$job" "$VAULT_HOME/var/log/audit.log"
  run vout job --id "$job"
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = True ]
}

@test "a db export streams /db/<name>.sql into a .sql.gz" {
  need_python
  run vout export --account alice --what db --db alice_wp --snapshot deadbeef01 --json
  [ "$status" -eq 0 ]
  f=$(printf '%s' "$output" | jget 'd["file"]')
  [[ $f == *.sql.gz ]]
  gunzip -c "$VAULT_EXPORT_ROOT/$f" | grep -q 'CREATE TABLE'
  grep -q 'dump deadbeef01 /db/alice_wp.sql' "$STUB_LOG/restic.log"
}

@test "a mail export dumps one mailbox folder" {
  run vout export --account alice --what mail --mailbox info@example.com --snapshot deadbeef01 --json
  [ "$status" -eq 0 ]
  grep -q "dump --archive tar deadbeef01 $T/vmail/example.com/info" "$STUB_LOG/restic.log"
}

@test "latest picks the snapshot by tag" {
  run vout export --account alice --what files --json
  [ "$status" -eq 0 ]
  grep -q 'dump --archive tar --tag files,alice latest' "$STUB_LOG/restic.log"
}

@test "export refuses bad input and writes nothing" {
  run ex --what db --db bob_wp
  [ "$status" -eq 2 ]
  run ex --what db --db 'alice_x; drop'
  [ "$status" -eq 2 ]
  run ex --what db
  [ "$status" -eq 2 ]
  run ex --what files --path /etc
  [ "$status" -eq 2 ]
  run ex --what files --path "$T/home/alice/../bob"
  [ "$status" -eq 2 ]
  run ex --what files --path "$T/home/alice/a" --path "$T/home/alice/b"
  [ "$status" -eq 2 ]
  run ex --what mail
  [ "$status" -eq 2 ]
  run ex --what mail --mailbox info@example.org
  [ "$status" -eq 2 ]
  run ex --what files --db alice_wp
  [ "$status" -eq 2 ]
  run ex --what nothing
  [ "$status" -eq 2 ]
  run vault export --account 'Bad Name' --what files
  [ "$status" -eq 2 ]
  run vault export --account alice --what files --snapshot 'zz;rm'
  [ "$status" -eq 2 ]
  ! grep -q ' dump ' "$STUB_LOG/restic.log" 2>/dev/null
  [ -z "$(ls -A "$VAULT_EXPORT_ROOT" 2>/dev/null)" ]
}

@test "a failing restic dump ends as a failed export and leaves no partial file" {
  need_python
  export STUB_DUMP_FAIL=1
  run vout export --account alice --what files --snapshot deadbeef01 --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
  [ -z "$(ls -A "$VAULT_EXPORT_ROOT")" ]
}

@test "--encrypt takes the passphrase on stdin, never in argv, and writes a .gpg" {
  need_python
  out=$(printf '%s\n' "$PW" | vout export --account alice --what files --snapshot deadbeef01 --encrypt --json)
  [ "$(printf '%s' "$out" | jget 'd["ok"]')" = True ]
  [ "$(printf '%s' "$out" | jget 'd["encrypted"]')" = True ]
  f=$(printf '%s' "$out" | jget 'd["file"]')
  [[ $f == *.tar.gz.gpg ]]
  [ "$(head -n 1 "$VAULT_EXPORT_ROOT/$f")" = GPGSTUB ]
  grep -q -- '--symmetric' "$STUB_LOG/gpg.log"
  grep -q -- '--cipher-algo AES256' "$STUB_LOG/gpg.log"
  grep -q -- '--pinentry-mode loopback' "$STUB_LOG/gpg.log"
  grep -q -- '--passphrase-fd' "$STUB_LOG/gpg.log"
  ! grep -qF -- "$PW" "$STUB_LOG/gpg.log"
  ! grep -rqF -- "$PW" "$STUB_LOG/restic.log" "$VAULT_HOME/var/log" "$VAULT_HOME/var/status"
  [ "$(cat "$STUB_LOG/gpg.pass")" = "len=${#PW}" ]
}

@test "--encrypt refuses a short or missing passphrase and a missing gpg" {
  run bash -c "printf 'short\n' | '$VAULT' export --account alice --what files --snapshot deadbeef01 --encrypt"
  [ "$status" -eq 2 ]
  run bash -c "'$VAULT' export --account alice --what files --snapshot deadbeef01 --encrypt </dev/null"
  [ "$status" -eq 2 ]
  run bash -c "printf '%s\n' '$PW' | VAULT_GPG=/nonexistent/gpg '$VAULT' export --account alice --what files --snapshot deadbeef01 --encrypt"
  [ "$status" -eq 2 ]
  [[ $output == *"gpg not installed"* ]]
  [ ! -e "$STUB_LOG/gpg.log" ]
}

@test "a detached encrypted export hands the passphrase to the worker on stdin" {
  need_python
  out=$(printf '%s\n' "$PW" | vout export --account alice --what db --db alice_wp --snapshot deadbeef01 --encrypt --detach --json)
  job=$(printf '%s' "$out" | jget 'd["job"]')
  wait_job "$job"
  run vout job --id "$job"
  [ "$(printf '%s' "$output" | jget 'd["state"]')" = done ]
  [ "$(printf '%s' "$output" | jget 'd["kind"]')" = export ]
  [ "$(printf '%s' "$output" | jget 'd["encrypted"]')" = True ]
  [ "$(cat "$STUB_LOG/gpg.pass")" = "len=${#PW}" ]
  ! grep -qF -- "$PW" "$STUB_LOG/gpg.log"
}

@test "exports lists live exports with their expiry" {
  need_python
  run vout exports --json
  [ "$output" = "[]" ]
  vout export --account alice --what files --snapshot deadbeef01 --json
  run vout exports --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'len(d)')" = 1 ]
  [ "$(printf '%s' "$output" | jget 'sorted(d[0].keys())')" = "['account', 'bytes', 'created', 'encrypted', 'expires', 'file', 'job', 'what']" ]
  [ "$(printf '%s' "$output" | jget 'd[0]["what"]')" = files ]
}

@test "the default expiry is 24 hours and EXPORT_KEEP_HOURS changes it" {
  need_python
  run vout export --account alice --what files --snapshot deadbeef01 --json
  [ "$(printf '%s' "$output" | jget 'abs(__import__("calendar").timegm(__import__("time").strptime(d["expires"],"%Y-%m-%dT%H:%M:%SZ"))-__import__("time").time()-86400) < 120')" = True ]
  conf_with EXPORT_KEEP_HOURS=2
  run vout export --account alice --what files --snapshot deadbeef01 --json
  [ "$(printf '%s' "$output" | jget 'abs(__import__("calendar").timegm(__import__("time").strptime(d["expires"],"%Y-%m-%dT%H:%M:%SZ"))-__import__("time").time()-7200) < 120')" = True ]
}

@test "EXPORT_KEEP_HOURS must be 1 to 720" {
  for v in 0 721 abc -1; do
    conf_with "EXPORT_KEEP_HOURS=$v"
    run vault export --account alice --what files --snapshot deadbeef01
    [ "$status" -eq 2 ]
  done
  conf_with EXPORT_KEEP_HOURS=720
  run vault export --account alice --what files --snapshot deadbeef01
  [ "$status" -eq 0 ]
}

@test "export-clean removes expired exports and keeps live ones" {
  need_python
  a=$(vout export --account alice --what files --snapshot deadbeef01 --json)
  sleep 1
  b=$(vout export --account alice --what db --db alice_wp --snapshot deadbeef01 --json)
  ja=$(printf '%s' "$a" | jget 'd["job"]')
  fa=$(printf '%s' "$a" | jget 'd["file"]')
  fb=$(printf '%s' "$b" | jget 'd["file"]')
  sed -i 's/"expires":"[^"]*"/"expires":"2020-01-01T00:00:00Z"/' "$VAULT_EXPORT_ROOT/$ja.json"
  run vault export-clean --quiet
  [ "$status" -eq 0 ]
  [ ! -e "$VAULT_EXPORT_ROOT/$fa" ]
  [ ! -e "$VAULT_EXPORT_ROOT/$ja.json" ]
  [ -e "$VAULT_EXPORT_ROOT/$fb" ]
  run vout exports --json
  [ "$(printf '%s' "$output" | jget 'len(d)')" = 1 ]
}

@test "export-clean removes old leftovers without a record and keeps fresh ones" {
  mkdir -p "$VAULT_EXPORT_ROOT"
  touch -d '3 days ago' "$VAULT_EXPORT_ROOT/20260101T000000Z-alice.tar.gz.part"
  touch "$VAULT_EXPORT_ROOT/20260102T000000Z-alice.tar.gz.part"
  run vault export-clean --quiet
  [ "$status" -eq 0 ]
  [ ! -e "$VAULT_EXPORT_ROOT/20260101T000000Z-alice.tar.gz.part" ]
  [ -e "$VAULT_EXPORT_ROOT/20260102T000000Z-alice.tar.gz.part" ]
}

@test "export-path prints the file path of a live export" {
  need_python
  out=$(vout export --account alice --what files --snapshot deadbeef01 --json)
  job=$(printf '%s' "$out" | jget 'd["job"]')
  f=$(printf '%s' "$out" | jget 'd["file"]')
  run vout export-path --job "$job"
  [ "$status" -eq 0 ]
  [ "$output" = "$VAULT_EXPORT_ROOT/$f" ]
}

@test "export-path refuses traversal, unknown jobs, damaged records and expired exports" {
  need_python
  out=$(vout export --account alice --what files --snapshot deadbeef01 --json)
  job=$(printf '%s' "$out" | jget 'd["job"]')
  for j in ../etc/passwd "$job/../x" '20260101T000000Z-alice/../..' '' 'x' "$job;id"; do
    run vault export-path --job "$j"
    [ "$status" -eq 2 ]
  done
  run vault export-path --job 20260101T000000Z-nobody
  [ "$status" -eq 2 ]
  printf 'secret\n' >"$T/outside"
  sed -i 's#"file":"[^"]*"#"file":"../outside"#' "$VAULT_EXPORT_ROOT/$job.json"
  run vault export-path --job "$job"
  [ "$status" -eq 2 ]
  sed -i 's#"file":"[^"]*"#"file":"/etc/passwd"#' "$VAULT_EXPORT_ROOT/$job.json"
  run vault export-path --job "$job"
  [ "$status" -eq 2 ]
  sed -i "s#\"file\":\"[^\"]*\"#\"file\":\"$job.tar.gz\"#; s/\"expires\":\"[^\"]*\"/\"expires\":\"2020-01-01T00:00:00Z\"/" "$VAULT_EXPORT_ROOT/$job.json"
  run vault export-path --job "$job"
  [ "$status" -eq 2 ]
}

@test "export-path refuses a symlinked export file" {
  need_python
  out=$(vout export --account alice --what files --snapshot deadbeef01 --json)
  job=$(printf '%s' "$out" | jget 'd["job"]')
  printf 'secret\n' >"$T/outside"
  rm -f "${VAULT_EXPORT_ROOT:?}/${job:?}.tar.gz"
  ln -s "$T/outside" "$VAULT_EXPORT_ROOT/$job.tar.gz" 2>/dev/null || skip "symlinks not available"
  run vault export-path --job "$job"
  [ "$status" -eq 2 ]
}

@test "audit-download records the download in the audit log" {
  need_python
  out=$(vout export --account alice --what files --snapshot deadbeef01 --json)
  job=$(printf '%s' "$out" | jget 'd["job"]')
  run vault audit-download --job "$job"
  [ "$status" -eq 0 ]
  grep -q "download job=$job" "$VAULT_HOME/var/log/audit.log"
  run vault audit-download --job '../x'
  [ "$status" -eq 2 ]
}

@test "the cron template carries the hourly export-clean line" {
  grep -q '^7  \* \* \* \*  root /usr/local/bin/vault export-clean --quiet$' "$REPO_ROOT/contrib/cron.d/cwp-vault"
}
