#!/usr/bin/env bats
load helpers/common

# Run a lib function in a clean shell: v <function> args...
v() { bash -c 'source "$1/log.sh"; source "$1/accounts.sh"; shift; "$@"' _ "$LIB" "$@"; }

@test "valid_account accepts lowercase usernames" {
  local a
  for a in alice a user_1 a_b_c abcdefghijklmnopqrstuvwxyz012345; do v valid_account "$a"; done
}

@test "valid_account rejects bad usernames" {
  local a
  for a in "" Alice 1abc _abc a-b "a b" "a;b" 'a$(x)' "abcdefghijklmnopqrstuvwxyz0123456" $'alice\n' $'alice\nbob' ../x; do
    ! v valid_account "$a" || { echo "accepted: [$a]"; return 1; }
  done
}

@test "valid_db requires the account prefix" {
  v valid_db alice alice_wp
  v valid_db alice alice_Shop_2
  ! v valid_db alice bob_wp
  ! v valid_db alice alice
  ! v valid_db alice alice_
  ! v valid_db alice alicex_wp
  ! v valid_db alice "alice_a-b"
  ! v valid_db alice 'alice_x;DROP'
  ! v valid_db alice $'alice_x\ny'
  ! v valid_db "Bad" Bad_x
}

@test "valid_db limits the suffix to 56 characters" {
  v valid_db alice "alice_$(head -c 56 /dev/zero | tr '\0' a)"
  ! v valid_db alice "alice_$(head -c 57 /dev/zero | tr '\0' a)"
}

@test "valid_domain accepts hostnames" {
  v valid_domain example.com
  v valid_domain mail.sub.example.co.uk
  v valid_domain xn--bcher-kva.example
}

@test "valid_domain rejects traversal and junk" {
  local d
  for d in "" ../etc "a/../b.com" "../../etc/passwd" "example.com/" "/example.com" "-a.com" "a-.com" localhost "Example.COM" "a b.com" $'a.com\nb.com' "a..com" ".com" "a.com;x"; do
    ! v valid_domain "$d" || { echo "accepted: [$d]"; return 1; }
  done
}

@test "valid_restore_path accepts plain absolute paths" {
  v valid_restore_path /home/alice/public_html/index.php
  v valid_restore_path /home/alice/a..b
}

@test "valid_restore_path rejects .., newline, relative and dot segments" {
  local p
  for p in relative/path "" "/home/alice/../bob" "/home/alice/.." "/.." "/home/alice/./x" $'/home/alice/a\nb' $'/home/a\tb' $'/x\r'; do
    ! v valid_restore_path "$p" || { echo "accepted: [$p]"; return 1; }
  done
}

@test "valid_snapshot accepts hex ids and latest only" {
  v valid_snapshot latest
  v valid_snapshot deadbeef
  ! v valid_snapshot "abc"
  ! v valid_snapshot "latest;rm"
  ! v valid_snapshot "-rf"
  ! v valid_snapshot ""
}

@test "glob_escape escapes restic glob characters" {
  run v glob_escape '/home/a/[x]*?.txt'
  [ "$output" = '/home/a/\[x]\*\?.txt' ]
}

@test "strip_definer removes DEFINER clauses" {
  out=$(printf 'CREATE DEFINER=`root`@`localhost` VIEW v AS select 1;\n/*!50017 DEFINER=`a`@`%%`*/ x\n' | v strip_definer)
  [[ $out != *DEFINER* ]]
  [[ $out == *"VIEW v AS"* ]]
}
