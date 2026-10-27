# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared between modules
# Orphans: repositories under vault/ whose account no longer exists in CWP.
# Listing needs the aws CLI (restic cannot list the repositories of a prefix).

declare -a OR_NAMES=() OR_LAST=() OR_AGE=() OR_DUE=() OR_DONE=() OR_ERR=()
OR_WHY=''

# orphan_last NAME : prints the newest snapshot time of the repository as "ISO<space>epoch" (nothing when unknown).
orphan_last() {
  local t e best=0 best_t='' rc=0
  restic_run "$1" snapshots --json --group-by '' --latest 1 || rc=$?
  ((rc == 0)) || return 1
  while IFS= read -r t; do
    [[ $t =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:?[0-9]{2})$ ]] || continue
    e=$(date -d "$t" +%s 2>/dev/null) || continue
    if ((e > best)); then
      best=$e
      best_t=$t
    fi
  done < <(grep -o '"time":"[^"]*"' <<<"$RESTIC_OUT" | sed -e 's/^"time":"//' -e 's/"$//' || true)
  if ((best > 0)); then printf '%s %s' "$best_t" "$best"; fi
}

# orphans_scan : fills OR_*. Returns 0 ok, 1 failed (OR_WHY set), 3 when the aws CLI is missing.
orphans_scan() {
  local prefix="${S3_PREFIX}vault/" line n now info last epoch age due
  local -a found=() active=()
  OR_NAMES=() OR_LAST=() OR_AGE=() OR_DUE=() OR_DONE=() OR_ERR=()
  OR_WHY=''
  if ! command -v aws >/dev/null 2>&1; then
    OR_WHY="the aws CLI is not installed"
    return 3
  fi
  mapfile -t active < <(acct_discover nofilter) || true
  if [[ -z ${active[0]:-} ]]; then
    OR_WHY="cannot read the CWP account list (or it is empty); not treating every repository as an orphan"
    return 1
  fi
  if ! aws_s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$prefix" --delimiter /; then
    OR_WHY="cannot list the repositories: ${AWS_ERR:-no answer}"
    return 1
  fi
  mapfile -t found < <(grep -o '"Prefix": *"[^"]*"' <<<"$AWS_OUT" | sed -e 's/^"Prefix": *"//' -e 's/"$//' || true)
  now=$(date +%s)
  for line in "${found[@]}"; do
    [[ $line == "$prefix"* ]] || continue
    n=${line#"$prefix"}
    n=${n%/}
    [[ -n $n && $n != */* && $n != _server ]] || continue
    valid_account "$n" || continue
    if in_list "$n" "${active[@]}"; then continue; fi
    last='' epoch='' age='' due=0
    if info=$(orphan_last "$n") && [[ -n $info ]]; then
      last=${info% *}
      epoch=${info#* }
      age=$(((now - epoch) / 86400))
      if ((ORPHAN_KEEP_DAYS > 0 && now - epoch > ORPHAN_KEEP_DAYS * 86400)); then due=1; fi
    fi
    OR_NAMES+=("$n") OR_LAST+=("$last") OR_AGE+=("$age") OR_DUE+=("$due") OR_DONE+=(0) OR_ERR+=("")
  done
}

orphans_json() { # OK ERROR NOTE
  local i first=1 last age
  printf '{"ok":%s,"keep_days":%d,"immutable":%s,"orphans":[' "$1" "$ORPHAN_KEEP_DAYS" "$([[ $IMMUTABLE == yes ]] && echo true || echo false)"
  for i in "${!OR_NAMES[@]}"; do
    if ((first)); then first=0; else printf ','; fi
    last=null age=null
    if [[ -n ${OR_LAST[i]} ]]; then
      last=$(json_str "${OR_LAST[i]}")
      age=${OR_AGE[i]}
    fi
    printf '{"account":%s,"last_snapshot":%s,"age_days":%s,"purge_due":%s,"purged":%s,"error":%s}' "$(json_str "${OR_NAMES[i]}")" \
      "$last" "$age" "$([[ ${OR_DUE[i]} == 1 ]] && echo true || echo false)" "$([[ ${OR_DONE[i]} == 1 ]] && echo true || echo false)" \
      "$(json_str "${OR_ERR[i]}")"
  done
  printf '],"error":%s,"note":%s}\n' "$(json_str "$2")" "$(json_str "$3")"
}

cmd_orphans() {
  local rc=0 i fail=0 err='' note='' purge=$ARG_PURGE n=0
  [[ $purge == 1 || $ARG_YES != 1 ]] || usage_err "--yes only goes with --purge"
  if [[ $purge == 1 ]]; then
    ((ORPHAN_KEEP_DAYS > 0)) || die 2 "ORPHAN_KEEP_DAYS=0 means orphan repositories are never purged"
    lock_take "$VAULT_LOCK/vault.lock" x || die 3 "a backup or another maintenance run is active"
  else
    lock_take "$VAULT_LOCK/vault.lock" s || die 3 "prune/check/unlock is running"
  fi
  orphans_scan || rc=$?
  if ((rc == 3)); then
    if [[ $purge == 1 ]]; then die 2 "orphans --purge needs the aws CLI (to list the repositories)"; fi
    log_warn "orphan check skipped: $OR_WHY"
    if [[ $ARG_JSON == 1 ]]; then orphans_json true "" "skipped: $OR_WHY"; fi
    return 0
  fi
  ((rc == 0)) || die 1 "$OR_WHY"

  if [[ $purge == 1 && $ARG_YES == 1 ]]; then
    for i in "${!OR_NAMES[@]}"; do
      [[ ${OR_DUE[i]} == 1 ]] || continue
      rc=0
      restic_run "${OR_NAMES[i]}" forget --keep-within "${ORPHAN_KEEP_DAYS}d" --prune || rc=$?
      if ((rc == 0)); then
        OR_DONE[i]=1
        n=$((n + 1))
      else
        OR_ERR[i]="restic rc $rc: ${RESTIC_ERR:-no message}"
        err="${OR_NAMES[i]}: ${OR_ERR[i]}"
        log_error "orphans purge $err"
        fail=1
      fi
      printf '%s orphans-purge account=%s keep_days=%d result=%s\n' "$(log_ts)" "${OR_NAMES[i]}" "$ORPHAN_KEEP_DAYS" \
        "$([[ ${OR_DONE[i]} == 1 ]] && echo ok || echo failed)" >>"$VAULT_AUDIT"
    done
    note="Snapshots made within ${ORPHAN_KEEP_DAYS} days of each repository's newest snapshot are kept; the repository itself (config, keys) is never deleted."
    if [[ $IMMUTABLE == yes ]]; then
      note+=" Immutable mode: the storage keeps the pruned objects until their object lock and the lifecycle rule expire (about $((LOCK_DAYS + 7)) days)."
    fi
  fi

  if [[ $ARG_JSON == 1 ]]; then
    orphans_json "$([[ $fail == 0 ]] && echo true || echo false)" "$err" "$note"
  else
    if ((${#OR_NAMES[@]} == 0)); then echo "No orphan repositories."; fi
    for i in "${!OR_NAMES[@]}"; do
      if [[ -z ${OR_LAST[i]} ]]; then
        printf '%s: no snapshots found\n' "${OR_NAMES[i]}"
      else
        printf '%s: newest snapshot %s (%s days ago)%s%s\n' "${OR_NAMES[i]}" "${OR_LAST[i]}" "${OR_AGE[i]}" \
          "$([[ ${OR_DUE[i]} == 1 ]] && echo ', purge due')" "$([[ ${OR_DONE[i]} == 1 ]] && echo ', purged')"
      fi
    done
    if [[ -n $note ]]; then echo "$note"; fi
    if [[ $purge == 1 && $ARG_YES != 1 ]]; then echo "Dry run: nothing was changed. Run again with --purge --yes to purge the ones marked due."; fi
  fi
  return "$fail"
}

# orphans_note : used by "prune --all". Reports only; never purges, never fails the run.
orphans_note() {
  local rc=0 i
  orphans_scan || rc=$?
  if ((rc == 3)); then
    log_info "orphan check skipped: $OR_WHY"
    return 0
  fi
  if ((rc != 0)); then
    log_warn "orphan check failed: $OR_WHY"
    return 0
  fi
  for i in "${!OR_NAMES[@]}"; do
    log_info "orphan repository ${OR_NAMES[i]}: newest snapshot ${OR_LAST[i]:-unknown}$([[ ${OR_DUE[i]} == 1 ]] && echo ', purge due')"
    if [[ $ARG_QUIET != 1 ]]; then printf 'orphan: %s (newest snapshot %s)\n' "${OR_NAMES[i]}" "${OR_LAST[i]:-unknown}"; fi
  done
  if ((${#OR_NAMES[@]} > 0)); then log_info "run: vault orphans   (and vault orphans --purge --yes to purge)"; fi
}
