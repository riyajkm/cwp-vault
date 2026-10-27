#!/usr/bin/env bats
load helpers/common

setup() { vault_setup; }
teardown() { vault_teardown; }

rs() { vault restore --account alice --what files "$@"; }
no_restore_call() { ! grep -q ' restore ' "$STUB_LOG/restic.log" 2>/dev/null; }

@test "restore refuses targets under /home, /etc, /root, /usr and /var/lib/mysql" {
  local t
  for t in /home/alice/restore /home /etc/cron.d /etc /root/x /usr/local/x /var/lib/mysql/x; do
    run rs --target "$t"
    [ "$status" -eq 2 ] || { echo "accepted: $t"; return 1; }
  done
  no_restore_call
}

@test "restore refuses / and an empty-looking target" {
  run rs --target /
  [ "$status" -eq 2 ]
  run rs --target //
  [ "$status" -eq 2 ]
  no_restore_call
}

@test "restore refuses relative targets and .. components" {
  run rs --target relative/dir
  [ "$status" -eq 2 ]
  run rs --target "$T/a/../b"
  [ "$status" -eq 2 ]
  run rs --target "$T/x"$'\n'"y"
  [ "$status" -eq 2 ]
  no_restore_call
}

@test "restore refuses an existing non-empty directory" {
  mkdir "$T/full"
  touch "$T/full/keep"
  run rs --target "$T/full"
  [ "$status" -eq 2 ]
  [[ $output == *"not empty"* ]]
  no_restore_call
  [ -e "$T/full/keep" ]
}

@test "restore refuses an existing file as target" {
  touch "$T/afile"
  run rs --target "$T/afile"
  [ "$status" -eq 2 ]
  no_restore_call
}

@test "restore accepts an existing empty directory" {
  mkdir "$T/empty"
  run rs --target "$T/empty"
  [ "$status" -eq 0 ]
  [ -e "$T/empty/restored.txt" ]
}

@test "restore refuses a target with a symlinked component" {
  mkdir "$T/real"
  ln -s "$T/real" "$T/link" 2>/dev/null || skip "symlinks not available"
  run rs --target "$T/link/sub"
  [ "$status" -eq 2 ]
  no_restore_call
}

@test "restore refuses a target that is itself a symlink to a forbidden place" {
  ln -s /etc "$T/etclink" 2>/dev/null || skip "symlinks not available"
  run rs --target "$T/etclink"
  [ "$status" -eq 2 ]
  no_restore_call
}

@test "default target is a fresh 0700 directory under the restore root" {
  need_python
  run vout restore --account alice --what files --json
  [ "$status" -eq 0 ]
  target=$(printf '%s' "$output" | jget 'd["target"]')
  [[ $target == "$VAULT_RESTORE_ROOT"/*-alice ]]
  [ -d "$target" ]
  [ "$(stat -c %a "$target")" = 700 ]
  [ "$(printf '%s' "$output" | jget 'sorted(d.keys())')" = "['bytes', 'duration_s', 'error', 'files', 'job', 'ok', 'target']" ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = True ]
  job=$(printf '%s' "$output" | jget 'd["job"]')
  json_valid <"$VAULT_HOME/var/status/restore-$job.json"
}

@test "restore result files do not show up in the status list" {
  need_python
  run vault restore --account alice --what files
  [ "$status" -eq 0 ]
  run vout status --json
  [ "$(printf '%s' "$output" | jget 'len(d["accounts"])')" -eq 0 ]
}

@test "restore goes to restic with the tag, snapshot, target and include" {
  run rs --target "$T/out"
  [ "$status" -eq 0 ]
  grep -q " restore latest --tag files,alice --target $T/out --include=$T/home/alice\$" "$STUB_LOG/restic.log"
}

@test "an explicit snapshot id is passed and no tag filter is added" {
  run rs --target "$T/out" --snapshot deadbeef01
  [ "$status" -eq 0 ]
  grep -q " restore deadbeef01 --target $T/out " "$STUB_LOG/restic.log"
  ! grep -q -- '--tag' <(grep ' restore ' "$STUB_LOG/restic.log")
}

@test "repeated --path become repeated --include" {
  run rs --target "$T/out" --path "$T/home/alice/a" --path "$T/home/alice/b c"
  [ "$status" -eq 0 ]
  line=$(grep ' restore ' "$STUB_LOG/restic.log")
  [[ $line == *"--include=$T/home/alice/a "* || $line == *"--include=$T/home/alice/a" ]]
  [[ $line == *"--include=$T/home/alice/b c"* ]]
  [ "$(printf '%s' "$line" | grep -o -- '--include=' | wc -l)" -eq 2 ]
}

@test "glob characters in a --path are escaped" {
  run rs --target "$T/out" --path "$T/home/alice/we*ird[1]"
  [ "$status" -eq 0 ]
  grep -qF -- '--include='"$T"'/home/alice/we\*ird\[1]' "$STUB_LOG/restic.log"
}

@test "--path with .., a newline, a relative path or outside the account is refused" {
  local p
  for p in "$T/home/alice/../bob/secret" "$T/home/alice/.." $'/x\ny' "relative" "$T/home/bob/file" "/etc/passwd"; do
    run rs --target "$T/out" --path "$p"
    [ "$status" -eq 2 ] || { echo "accepted: $p"; return 1; }
  done
  no_restore_call
}

@test "--path is refused for meta" {
  run vault restore --account alice --what meta --target "$T/out" --path /meta/account.json
  [ "$status" -eq 2 ]
}

@test "dry run restores nothing and writes no audit line" {
  run rs --target "$T/out" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"Would restore"* ]]
  no_restore_call
  [ ! -e "$T/out" ]
  [ ! -s "$VAULT_HOME/var/log/audit.log" ]
}

@test "a restore appends one audit line" {
  run rs --target "$T/out"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$VAULT_HOME/var/log/audit.log")" -eq 1 ]
  line=$(cat "$VAULT_HOME/var/log/audit.log")
  [[ $line =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\ account=alice\ snapshot=latest\ what=files\ src= ]]
  [[ $line == *"target=$T/out"* ]]
}

@test "setuid and setgid bits are stripped after a files restore" {
  run rs --target "$T/out"
  [ "$status" -eq 0 ]
  [ $((8#$(stat -c %a "$T/out/suid.bin") & 8#6000)) -eq 0 ]
}

@test "a failed restic restore exits 1 and reports ok false" {
  need_python
  export STUB_RESTORE_FAIL=1
  run vout restore --account alice --what files --target "$T/out" --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
  grep -q '(failed)' "$VAULT_HOME/var/log/audit.log"
}

@test "restore for an account with no repository is refused (no repo is created)" {
  export STUB_NOREPO=1
  run rs --target "$T/out"
  [ "$status" -eq 2 ]
  ! grep -q ' init' "$STUB_LOG/restic.log"
}

@test "restore with an unreachable repository exits 4" {
  export STUB_CAT_RC=1
  run rs --target "$T/out"
  [ "$status" -eq 4 ]
}

@test "restore validates account, snapshot and --what" {
  run vault restore --account '../x' --what files
  [ "$status" -eq 2 ]
  run rs --snapshot 'abc;rm' --target "$T/out"
  [ "$status" -eq 2 ]
  run vault restore --account alice --what bogus
  [ "$status" -eq 2 ]
  run vault restore --what files
  [ "$status" -eq 2 ]
}

# ---- database restore ----

dbrs() { vault restore --account alice --what db "$@"; }

@test "db restore refuses a database that already exists" {
  export STUB_DB_EXISTS=1
  run dbrs --db alice_wp --target-db alice_wp_copy
  [ "$status" -eq 2 ]
  [[ $output == *"already exists"* ]]
  ! grep -q ' dump ' "$STUB_LOG/restic.log"
  ! grep -q 'CREATE DATABASE' "$STUB_LOG/mysql.log"
}

@test "db restore creates the new database and imports a DEFINER-free dump" {
  run dbrs --db alice_wp --target-db alice_wp_copy
  [ "$status" -eq 0 ]
  grep -qF 'CREATE DATABASE `alice_wp_copy`' "$STUB_LOG/mysql.log"
  grep -q ' dump --tag db:alice_wp latest /db/alice_wp.sql' "$STUB_LOG/restic.log"
  grep -q 'CREATE TABLE' "$STUB_LOG/mysql_import.sql"
  ! grep -q 'DEFINER' "$STUB_LOG/mysql_import.sql"
  grep -q 'what=db .*target=db:alice_wp_copy' "$VAULT_HOME/var/log/audit.log"
}

@test "a failed db import exits 1 and says the database was left in place" {
  export STUB_IMPORT_FAIL=1
  run dbrs --db alice_wp --target-db alice_wp_copy
  [ "$status" -eq 1 ]
  [[ $output == *"left in place"* ]]
}

@test "db restore validates database names" {
  run dbrs --db bob_main --target-db alice_copy
  [ "$status" -eq 2 ]
  run dbrs --db alice_wp --target-db other_copy
  [ "$status" -eq 2 ]
  run dbrs --db alice_wp --target-db 'alice_x;DROP'
  [ "$status" -eq 2 ]
  run dbrs --db alice_wp
  [ "$status" -eq 2 ]
  run dbrs --db alice_wp --target-db alice_c --target "$T/out"
  [ "$status" -eq 2 ]
  ! grep -q 'CREATE DATABASE' "$STUB_LOG/mysql.log" 2>/dev/null
}

@test "--db is refused for a files restore" {
  run rs --target "$T/out" --db alice_wp
  [ "$status" -eq 2 ]
}
