#!/usr/bin/env bats
load helpers/common

setup() { vault_setup; }
teardown() { vault_teardown; }

@test "files and mail go in one restic call with excludes and tag files" {
  run vault backup --account alice
  [ "$status" -eq 0 ]
  [ "$(count_lines 'tag files,alice' "$STUB_LOG/restic.log")" -eq 1 ]
  line=$(grep 'tag files,alice' "$STUB_LOG/restic.log")
  [[ $line == */vault/alice\ \|\ * ]]
  [[ $line == *"--one-file-system"* ]]
  [[ $line == *"$T/home/alice"* ]]
  [[ $line == *"$T/vmail/example.com"* ]]
  [[ $line == *"--exclude=*/cache/*"* && $line == *"--exclude=*/.cache/*"* && $line == *"--exclude=*/tmp/*"* ]]
  [[ $line == *"--exclude=*/.trash/*"* && $line == *"--exclude=*/error_log"* && $line == *"--exclude=*/core.[0-9]*"* ]]
}

@test "extra EXCLUDES are appended" {
  conf_with "EXCLUDES=*.iso */node_modules/*"
  run vault backup --account alice
  [ "$status" -eq 0 ]
  line=$(grep 'tag files,alice' "$STUB_LOG/restic.log")
  [[ $line == *"--exclude=*.iso"* && $line == *"--exclude=*/node_modules/*"* ]]
}

@test "BACKUP_MAIL=no leaves out mail dirs and the mailauth snapshot" {
  conf_with "BACKUP_MAIL=no"
  run vault backup --account alice
  [ "$status" -eq 0 ]
  ! grep -q "$T/vmail" "$STUB_LOG/restic.log"
  [ ! -e "$STUB_LOG/stdin/meta_mailauth.json" ]
}

@test "each database is streamed with --stdin and filename db/<db>.sql" {
  run vault backup --account alice
  [ "$status" -eq 0 ]
  grep -q -- '--stdin --stdin-filename db/alice_wp.sql --tag db,alice,db:alice_wp' "$STUB_LOG/restic.log" ||
    grep -q -- '--stdin-filename db/alice_wp.sql' "$STUB_LOG/restic.log"
  grep -q -- '--stdin-filename db/alice_shop.sql' "$STUB_LOG/restic.log"
  [ "$(count_lines 'stdin-filename db/' "$STUB_LOG/restic.log")" -eq 2 ]
  grep -q 'CREATE TABLE' "$STUB_LOG/stdin/db_alice_wp.sql"
  grep -q -- 'alice_wp$' "$STUB_LOG/mysqldump.log"
  grep -q -- '--single-transaction --quick --routines --events --triggers --hex-blob' "$STUB_LOG/mysqldump.log"
}

@test "BACKUP_DATABASES=no skips dumps" {
  conf_with "BACKUP_DATABASES=no"
  run vault backup --account alice
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_LOG/mysqldump.log" ]
}

@test "DEFINER clauses never reach restic" {
  run vault backup --account alice
  [ "$status" -eq 0 ]
  grep -q 'DEFINER' <(printf '%s' 'CREATE DEFINER=x') # sanity: the pattern itself matches
  ! grep -rq 'DEFINER=' "$STUB_LOG/stdin"
  grep -q 'TRIGGER trg' "$STUB_LOG/stdin/db_alice_wp.sql"   # the rest of the dump is intact
}

@test "MyISAM databases are dumped with --lock-tables instead of --single-transaction" {
  export STUB_MYISAM=2
  run vault backup --account alice
  [ "$status" -eq 0 ]
  grep -q -- '--lock-tables' "$STUB_LOG/mysqldump.log"
  ! grep -q -- '--single-transaction' "$STUB_LOG/mysqldump.log"
}

@test "a failing mysqldump fails that DB only, snapshot is forgotten, exit 1" {
  export STUB_DUMP_FAIL=alice_wp
  run vault backup --account alice
  [ "$status" -eq 1 ]
  need_python
  s=$(status_file alice)
  cat "$s" | json_valid
  [ "$(jget 'd["result"]' <"$s")" = failed ]
  [[ $(jget 'd["error"]' <"$s") == *"db:alice_wp failed"* ]]
  [[ $(jget 'd["snapshots"]' <"$s") == *"db:alice_shop"* ]]
  [[ $(jget 'd["snapshots"]' <"$s") != *"db:alice_wp"* ]]
  grep -q ' forget ' "$STUB_LOG/restic.log"
}

@test "a failing account does not stop the others" {
  export STUB_DUMP_FAIL=alice_wp
  run vault backup --all
  [ "$status" -eq 1 ]
  need_python
  [ "$(jget 'd["result"]' <"$(status_file alice)")" = failed ]
  [ "$(jget 'd["result"]' <"$(status_file bob)")" = ok ]
  grep -q '/vault/bob | .*backup' "$STUB_LOG/restic.log"
}

@test "a failing upload of a stream marks it failed" {
  export STUB_STREAM_FAIL=db/alice_shop.sql
  run vault backup --account alice
  [ "$status" -eq 1 ]
  need_python
  [[ $(jget 'd["error"]' <"$(status_file alice)") == *"db:alice_shop failed"* ]]
}

@test "a failing file backup is recorded and DBs are still attempted" {
  export STUB_FAIL_FILES=1
  run vault backup --account alice
  [ "$status" -eq 1 ]
  [ -e "$STUB_LOG/stdin/db_alice_wp.sql" ]
}

@test "status JSON has the required fields and is valid" {
  need_python
  run vault backup --account alice
  [ "$status" -eq 0 ]
  s=$(status_file alice)
  json_valid <"$s"
  [ "$(jget 'sorted(d.keys())' <"$s")" = "['account', 'bytes_added', 'duration_s', 'error', 'files_changed', 'files_new', 'finished', 'result', 'snapshots', 'started']" ]
  [ "$(jget 'd["account"]' <"$s")" = alice ]
  [ "$(jget 'd["result"]' <"$s")" = ok ]
  [ "$(jget 'd["error"]' <"$s")" = "" ]
  [ "$(jget 'len(d["snapshots"])' <"$s")" -eq 5 ]   # files, 2 dbs, meta, mailauth
  [ "$(jget 'd["files_new"]' <"$s")" -eq 2 ]
  [ "$(jget 'type(d["duration_s"]).__name__' <"$s")" = int ]
  [[ $(jget 'd["started"]' <"$s") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
}

@test "meta/account.json is valid JSON without password hashes; mailauth is separate" {
  need_python
  run vault backup --account alice
  [ "$status" -eq 0 ]
  json_valid <"$STUB_LOG/stdin/meta_account.json"
  json_valid <"$STUB_LOG/stdin/meta_mailauth.json"
  ! grep -qi 'password\|HASHSECRET' "$STUB_LOG/stdin/meta_account.json"
  grep -q 'HASHSECRET' "$STUB_LOG/stdin/meta_mailauth.json"
  grep -q -- '--stdin-filename meta/account.json --tag meta,alice' "$STUB_LOG/restic.log"
  grep -q -- '--stdin-filename meta/mailauth.json --tag mailauth,alice' "$STUB_LOG/restic.log"
  [ "$(jget 'd["account"]' <"$STUB_LOG/stdin/meta_account.json")" = alice ]
}

@test "secrets reach restic through the environment, never argv" {
  run vault backup --account alice
  [ "$status" -eq 0 ]
  grep -q 'pw_in_env=yes key_in_env=yes' "$STUB_LOG/restic.env.log"
  ! grep -rqF -e "$SECRET_PW" -e "$SECRET_KEY" -e "$SECRET_KEY_ID" "$STUB_LOG/restic.log" "$STUB_LOG/mysql.log" "$STUB_LOG/mysqldump.log"
}

@test "restic gets the connection count and upload limit" {
  conf_with "S3_CONNECTIONS=7" "LIMIT_UPLOAD_KIB=500"
  run vault backup --account alice
  [ "$status" -eq 0 ]
  grep -q -- '-o s3.connections=7 --limit-upload 500 ' "$STUB_LOG/restic.log"
}

@test "repository URL is s3:endpoint/bucket/prefix/vault/account" {
  run vault backup --account alice
  grep -q '^s3:https://s3.example.com/example-backups/srv1/vault/alice | ' "$STUB_LOG/restic.log"
}

@test "repository is created when missing, then used" {
  export STUB_NOREPO=1
  run vault backup --account alice
  grep -q ' init$' "$STUB_LOG/restic.log"
}

@test "backup of the _server repo covers dumps of root_cwp and postfix" {
  conf_with "BACKUP_SERVER=yes"
  run vault backup --account _server
  # no server files exist in CI, so the files part fails, but both dumps are attempted
  grep -q -- '--stdin-filename db/root_cwp.sql' "$STUB_LOG/restic.log"
  grep -q -- '--stdin-filename db/postfix.sql' "$STUB_LOG/restic.log"
}

@test "backup needs exactly one of --account and --all" {
  run vault backup
  [ "$status" -eq 2 ]
  run vault backup --all --account alice
  [ "$status" -eq 2 ]
}
