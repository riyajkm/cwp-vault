#!/usr/bin/env bats
# install.sh is sourced (main guard) so its functions can be tested; nothing here touches the system.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  # shellcheck source=/dev/null
  source "$REPO_ROOT/install.sh"
  T=$(mktemp -d)
}
teardown() { rm -rf -- "${T:?}"; }

@test "sourcing install.sh runs nothing and defines the functions" {
  [ "$(type -t main)" = function ]
  [ "$(type -t cron_missing_lines)" = function ]
}

@test "parse_args sets the mode flags" {
  parse_args --dry-run --strict --force --no-module --enable-cron
  [ "$DRY" = 1 ] && [ "$STRICT" = 1 ] && [ "$FORCE" = 1 ] && [ "$NO_MODULE" = 1 ] && [ "$ENABLE_CRON" = 1 ]
  [ "$UPGRADE" = 0 ] && [ "$CHECK" = 0 ]
}

@test "parse_args accepts --upgrade and --check" {
  parse_args --upgrade
  [ "$UPGRADE" = 1 ]
  UPGRADE=0
  parse_args --check
  [ "$CHECK" = 1 ]
}

@test "--upgrade and --check together are rejected" {
  run bash "$REPO_ROOT/install.sh" --upgrade --check
  [ "$status" -ne 0 ]
  [[ $output == *"cannot be combined"* ]]
}

@test "unknown option fails with usage" {
  run bash "$REPO_ROOT/install.sh" --nope
  [ "$status" -ne 0 ]
  [[ $output == *"unknown option: --nope"* ]]
  [[ $output == *"--upgrade"* ]]
}

@test "--version prints the installer version" {
  run bash "$REPO_ROOT/install.sh" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$INSTALLER_VERSION" ]
}

@test "--dry-run prints the plan and changes nothing" {
  run bash "$REPO_ROOT/install.sh" --dry-run --no-module
  [ "$status" -eq 0 ]
  [[ $output == *"Installing engine"* ]]
  [[ $output == *"Dry run finished; nothing was changed"* ]]
}

@test "--dry-run --upgrade without an install stops with a hint" {
  VAULT_HOME=$T/none run parse_and_prepare
  [ "$status" -ne 0 ]
  [[ $output == *"without --upgrade"* ]]
}

parse_and_prepare() { UPGRADE=1; upgrade_prepare; }

@test "ver_gt compares versions numerically" {
  ver_gt 0.10.0 0.9.0
  ver_gt 1.0.0 0.99.9
  [ "$(ver_gt 0.2.0 0.2.0 && echo y || echo n)" = n ]
  [ "$(ver_gt 0.2.0 0.10.0 && echo y || echo n)" = n ]
}

@test "src_version reads the engine version" {
  [ "$(src_version)" = "$(sed -n 's/^VAULT_VERSION=//p' "$REPO_ROOT/engine/bin/vault")" ]
}

@test "upgrade refuses a downgrade unless --force" {
  mkdir -p "$T/bin"
  : >"$T/bin/vault"
  chmod +x "$T/bin/vault"
  echo 99.0.0 >"$T/VERSION"
  VAULT_HOME=$T run parse_and_prepare
  [ "$status" -ne 0 ]
  [[ $output == *"refusing to downgrade 99.0.0"* ]]
  FORCE=1 VAULT_HOME=$T run parse_and_prepare
  [ "$status" -eq 0 ]
}

@test "cron merge appends only missing commands" {
  printf '%s\n' 'SHELL=/bin/bash' '30 1 * * *  root /usr/local/bin/vault backup --all --quiet' >"$T/cur"
  printf '%s\n' 'SHELL=/bin/bash' '30 1 * * *  root /usr/local/bin/vault backup --all --quiet' \
    '0 5 1 * *  root /usr/local/bin/vault verify-restore --quiet' >"$T/new"
  run cron_missing_lines "$T/new" "$T/cur"
  [ "$status" -eq 0 ]
  [ "$output" = '0 5 1 * *  root /usr/local/bin/vault verify-restore --quiet' ]
}

@test "cron merge keeps a disabled backup line and a changed schedule" {
  printf '%s\n' '#30 1 * * *  root /usr/local/bin/vault backup --all --quiet' \
    '15 2 * * 0  root /usr/local/bin/vault prune --all --quiet' >"$T/cur"
  printf '%s\n' '30 1 * * *  root /usr/local/bin/vault backup --all --quiet' \
    '0 4 * * 0  root /usr/local/bin/vault prune --all --quiet' >"$T/new"
  run cron_missing_lines "$T/new" "$T/cur"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cron merge on the shipped file is a no-op against itself" {
  run cron_missing_lines "$REPO_ROOT/contrib/cron.d/cwp-vault" "$REPO_ROOT/contrib/cron.d/cwp-vault"
  [ -z "$output" ]
}
