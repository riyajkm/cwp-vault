#!/usr/bin/env bats
load helpers/common

setup() {
  vault_setup
  # runuser needs root; the stub just runs the command
  printf '#!/usr/bin/env bash\nshift 3\nexec "$@"\n' >"$T/bin/runuser"
  chmod +x "$T/bin/runuser"
  # restic stub that stages <INPLACE_SRC>/new.txt inside a restore, then behaves like the common stub
  cp "$T/bin/restic" "$T/bin/restic.real"
  cat >"$T/bin/restic" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" restore "* && -n ${INPLACE_SRC:-} ]]; then
  prev=''
  for a in "$@"; do
    if [[ $prev == --target ]]; then mkdir -p "$a$INPLACE_SRC"; echo staged >"$a$INPLACE_SRC/new.txt"; fi
    prev=$a
  done
fi
exec "$(dirname "$0")/restic.real" "$@"
STUB
  chmod +x "$T/bin/restic"
  mkdir -p "$T/home/alice/site"
}
teardown() { vault_teardown; }

need_rsync() { command -v rsync >/dev/null 2>&1 || skip "rsync not available"; }
ip() { vault restore --account alice --in-place --confirm alice --snapshot deadbeef01 "$@"; }
no_restore_call() { ! grep -q ' restore ' "$STUB_LOG/restic.log" 2>/dev/null; }
no_backup_call() { ! grep -q ' backup ' "$STUB_LOG/restic.log" 2>/dev/null; }

@test "--in-place without a matching --confirm is refused before anything runs" {
  run vault restore --account alice --what files --in-place --snapshot deadbeef01
  [ "$status" -eq 2 ]
  run vault restore --account alice --what files --in-place --snapshot deadbeef01 --confirm bob
  [ "$status" -eq 2 ]
  run vault restore --account alice --what files --in-place --snapshot deadbeef01 --confirm ALICE
  [ "$status" -eq 2 ]
  no_restore_call
  no_backup_call
}

@test "--confirm without --in-place, --in-place with latest, a target or meta are refused" {
  run vault restore --account alice --what files --confirm alice --target "$T/out"
  [ "$status" -eq 2 ]
  run vault restore --account alice --what files --in-place --confirm alice
  [ "$status" -eq 2 ]
  run ip --what files --target "$T/out"
  [ "$status" -eq 2 ]
  run ip --what meta
  [ "$status" -eq 2 ]
  no_restore_call
  no_backup_call
}

@test "an in-place files restore takes a safety backup first, then copies over the live files" {
  need_rsync
  export INPLACE_SRC=$T/home/alice/site
  echo old >"$T/home/alice/site/new.txt"
  run ip --what files --path "$T/home/alice/site" --json
  [ "$status" -eq 0 ]
  [ "$(cat "$T/home/alice/site/new.txt")" = staged ]
  [[ $output == *'"in_place":true'* ]]
  [[ $output == *'"safety_snapshots":["deadbeef'* ]]
  b=$(grep -n ' backup ' "$STUB_LOG/restic.log" | head -n1 | cut -d: -f1)
  r=$(grep -n ' restore ' "$STUB_LOG/restic.log" | head -n1 | cut -d: -f1)
  [ -n "$b" ] && [ -n "$r" ] && [ "$b" -lt "$r" ]
  grep -q 'in-place safety=deadbeef' "$VAULT_HOME/var/log/audit.log"
  [ -z "$(ls -A "$VAULT_RESTORE_ROOT")" ] # the staging copy is removed
}

@test "if the safety backup fails nothing is restored" {
  export STUB_FAIL_FILES=1 INPLACE_SRC=$T/home/alice/site
  run ip --what files --path "$T/home/alice/site"
  [ "$status" -eq 1 ]
  [[ $output == *"safety backup"* ]]
  no_restore_call
  [ ! -e "$T/home/alice/site/new.txt" ]
  grep -q 'safety backup FAILED' "$VAULT_HOME/var/log/audit.log"
}

@test "an in-place destination with a symlink on its path is refused" {
  ln -s "$T/home/bob" "$T/home/alice/lnk" 2>/dev/null || skip "symlinks not available"
  run ip --what files --path "$T/home/alice/lnk/x"
  [ "$status" -eq 2 ]
  no_backup_call
  no_restore_call
}

@test "in-place paths outside the account are refused" {
  run ip --what files --path "$T/home/bob/x"
  [ "$status" -eq 2 ]
  no_backup_call
}

@test "an in-place db restore refuses databases the account does not own" {
  run ip --what db --db bob_main
  [ "$status" -eq 2 ]
  run ip --what db --db alice_ghost
  [ "$status" -eq 2 ]
  no_backup_call
  [ ! -e "$STUB_LOG/mysql_import.sql" ]
}

@test "an in-place db restore imports the DEFINER-free dump into the live database" {
  run ip --what db --db alice_wp
  [ "$status" -eq 0 ]
  grep -q 'CREATE TABLE' "$STUB_LOG/mysql_import.sql"
  ! grep -q 'DEFINER' "$STUB_LOG/mysql_import.sql"
  ! grep -q 'CREATE DATABASE' "$STUB_LOG/mysql.log"
  b=$(grep -n ' backup ' "$STUB_LOG/restic.log" | head -n1 | cut -d: -f1)
  d=$(grep -n ' dump ' "$STUB_LOG/restic.log" | head -n1 | cut -d: -f1)
  [ "$b" -lt "$d" ]
}

@test "--mailbox is validated and the domain must belong to the account" {
  local m
  for m in '../x@example.com' 'a b@example.com' '@example.com' 'info' 'info@' 'info@other.net' 'info@example.org' '.hid@example.com' 'a/b@example.com'; do
    run vault restore --account alice --what mail --mailbox "$m" --snapshot deadbeef01 --target "$T/out"
    [ "$status" -eq 2 ] || { echo "accepted: $m"; return 1; }
  done
  run vault restore --account alice --what files --mailbox info@example.com
  [ "$status" -eq 2 ]
  run vault restore --account alice --what mail --mailbox info@example.com --path "$T/vmail/example.com/info"
  [ "$status" -eq 2 ]
  no_restore_call
}

@test "a mailbox restore to staging includes only that mailbox folder" {
  run vault restore --account alice --what mail --mailbox info@example.com --snapshot deadbeef01 --target "$T/out"
  [ "$status" -eq 0 ]
  grep -qF -- "--include=$T/vmail/example.com/info" "$STUB_LOG/restic.log"
}

@test "an in-place mail restore needs a mailbox and keeps the owner of the domain folder" {
  run ip --what mail
  [ "$status" -eq 2 ]
  need_rsync
  export INPLACE_SRC=$T/vmail/example.com/info
  run ip --what mail --mailbox info@example.com
  [ "$status" -eq 0 ]
  [ "$(cat "$T/vmail/example.com/info/new.txt")" = staged ]
  [ "$(stat -c %u:%g "$T/vmail/example.com/info")" = "$(stat -c %u:%g "$T/vmail/example.com")" ]
}
