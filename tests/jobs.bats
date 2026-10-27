#!/usr/bin/env bats
load helpers/common

setup() { vault_setup; }
teardown() { vault_teardown; }

# wait_job ID : until the job file says done or failed (the worker is detached).
wait_job() {
  local i
  for i in $(seq 1 300); do
    if grep -q '"state":"\(done\|failed\)"' "$(status_file "restore-$1")" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
}

@test "restore --detach queues a job, prints its id and the worker finishes it" {
  need_python
  run vout restore --account alice --what files --detach --json
  [ "$status" -eq 0 ]
  job=$(printf '%s' "$output" | jget 'd["job"]')
  [[ $job =~ ^[0-9]{8}T[0-9]{6}Z-alice$ ]]
  wait_job "$job"
  run vout job --id "$job" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["state"]')" = done ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = True ]
  [ "$(printf '%s' "$output" | jget 'd["percent"]')" = 100 ]
  [ -e "$VAULT_RESTORE_ROOT/$job/restored.txt" ]
}

@test "a detached restore that fails ends as failed with the error" {
  need_python
  export STUB_RESTORE_FAIL=1
  run vout restore --account alice --what files --detach --json
  job=$(printf '%s' "$output" | jget 'd["job"]')
  wait_job "$job"
  run vout job --id "$job" --json
  [ "$(printf '%s' "$output" | jget 'd["state"]')" = failed ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
}

@test "a worker that dies without a result is marked failed" {
  need_python
  export STUB_CAT_RC=1
  id=20260101T000000Z-alice
  printf '{"job":"%s","state":"queued"}\n' "$id" >"$(status_file "restore-$id")" 2>/dev/null || { mkdir -p "$VAULT_HOME/var/status"; printf '{"job":"%s","state":"queued"}\n' "$id" >"$(status_file "restore-$id")"; }
  run vault restore --account alice --what files --job "$id"
  [ "$status" -eq 4 ]
  run vout job --id "$id"
  [ "$(printf '%s' "$output" | jget 'd["state"]')" = failed ]
}

@test "--job must name an existing queued job of the same account" {
  run vault restore --account alice --what files --job 20260101T000000Z-alice
  [ "$status" -eq 2 ]
  run vault restore --account alice --what files --job '../x'
  [ "$status" -eq 2 ]
  [ "$(ls "$VAULT_HOME"/var/status/restore-* 2>/dev/null | wc -l)" -eq 0 ]
}

@test "a detach with bad arguments queues nothing" {
  run vault restore --account alice --what bogus --detach
  [ "$status" -eq 2 ]
  run vault restore --account alice --what files --detach --path /etc/passwd
  [ "$status" -eq 2 ]
  [ "$(ls "$VAULT_HOME"/var/status/restore-* 2>/dev/null | wc -l)" -eq 0 ]
}

@test "vault job rejects bad and unknown ids" {
  run vault job --id '../etc'
  [ "$status" -eq 2 ]
  run vault job --id 20260101T000000Z-nobody
  [ "$status" -eq 2 ]
  run vault job
  [ "$status" -eq 2 ]
}

@test "vault jobs lists the newest 20, newest first, as a JSON array" {
  need_python
  mkdir -p "$VAULT_HOME/var/status"
  for n in $(seq -w 1 25); do
    printf '{"job":"202601%s","state":"done"}\n' "$n" >"$VAULT_HOME/var/status/restore-202601${n}T000000Z-alice.json"
  done
  run vout jobs --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'len(d)')" = 20 ]
  [ "$(printf '%s' "$output" | jget 'd[0]["job"]')" = 20260125 ]
  [ "$(vout status --json | jget 'len(d["accounts"])')" = 2 ] # job files are not accounts
}

@test "vault jobs with no jobs prints an empty array" {
  need_python
  run vout jobs --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a running job whose worker pid is gone is reported as failed" {
  need_python
  mkdir -p "$VAULT_HOME/var/status"
  id=20260101T000000Z-alice
  printf '{"job":"%s","state":"running","account":"alice","what":"files","percent":40,"bytes_done":5,"pid":2999999,"kind":"restore"}\n' "$id" >"$(status_file "restore-$id")"
  run vout job --id "$id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jget 'd["state"]')" = failed ]
  [ "$(printf '%s' "$output" | jget 'd["ok"]')" = False ]
  [ "$(printf '%s' "$output" | jget 'd["percent"]')" = 40 ]
  run vout jobs --json
  [ "$(printf '%s' "$output" | jget 'd[0]["state"]')" = failed ]
}

@test "a running job whose worker is alive stays running" {
  need_python
  mkdir -p "$VAULT_HOME/var/status"
  id=20260101T000000Z-alice
  sleep 30 &
  HOLDER_PID=$!
  printf '{"job":"%s","state":"running","account":"alice","what":"files","percent":40,"bytes_done":5,"pid":%d,"kind":"restore"}\n' "$id" "$HOLDER_PID" >"$(status_file "restore-$id")"
  run vout job --id "$id"
  [ "$(printf '%s' "$output" | jget 'd["state"]')" = running ]
}

@test "restic runs with the slower progress rate in a job worker only" {
  need_python
  run vout restore --account alice --what files --detach --json
  job=$(printf '%s' "$output" | jget 'd["job"]')
  wait_job "$job"
  grep -q 'fps=0.5' "$STUB_LOG/restic.env.log"
  run vout restore --account alice --what files --json
  [ "$status" -eq 0 ]
  tail -n 1 "$STUB_LOG/restic.env.log" | grep -q 'fps=0.016'
}
