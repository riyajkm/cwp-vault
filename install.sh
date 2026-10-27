#!/usr/bin/env bash
# CWP Vault installer. Run as root from a checkout or release tarball: sudo ./install.sh
# Idempotent; never overwrites existing config or secrets. See docs/INSTALL.md.
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

INSTALLER_VERSION=0.2.0
VAULT_HOME=/usr/local/cwp-vault
CWP_RES=/usr/local/cwpsrv/htdocs/resources/admin
CRON_FILE=/etc/cron.d/cwp-vault
LOGROTATE_FILE=/etc/logrotate.d/cwp-vault

# restic is pinned: the hash below is compared against the downloaded file, never against a
# hash fetched alongside it. Planned (v0.3): also verify the GPG signature on SHA256SUMS.
RESTIC_MIN=0.17.0
RESTIC_VERSION=0.19.1
RESTIC_SHA256_AMD64=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
RESTIC_SHA256_ARM64=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRY=0 ENABLE_CRON=0 FORCE=0 NO_MODULE=0
TMP=

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# Hard error normally; in --dry-run only a warning so the plan can still be printed.
need() { if ((DRY)); then warn "$* (would fail)"; else die "$*"; fi; }
run() { if ((DRY)); then (IFS=' '; printf '+ %s\n' "$*"); else "$@"; fi; }
cleanup() { [[ -z $TMP ]] || rm -rf -- "${TMP:?}"; }
trap cleanup EXIT
trap 'die "failed at line $LINENO (command: $BASH_COMMAND)"' ERR

usage() {
  cat <<USAGE
CWP Vault installer $INSTALLER_VERSION
Usage: sudo ./install.sh [options]
  --dry-run       print the actions, change nothing
  --enable-cron   enable the nightly backup line in $CRON_FILE
                  (default: shipped commented out until 'vault init' succeeds)
  --force         continue on an unsupported OS
  --no-module     engine only; skip the CWP admin module and menu entry
  --version       print the installer version
  -h, --help      this text
USAGE
}

while (($#)); do
  case $1 in
    --dry-run) DRY=1 ;;
    --enable-cron) ENABLE_CRON=1 ;;
    --force) FORCE=1 ;;
    --no-module) NO_MODULE=1 ;;
    --version) echo "$INSTALLER_VERSION"; exit 0 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

preflight() {
  info "Preflight"
  ((EUID == 0)) || need "must run as root (use sudo)"

  local id='' ver='' major
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091 # system file, present on every supported OS
    id=$(. /etc/os-release && echo "${ID:-}")
    # shellcheck disable=SC1091
    ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
  fi
  major=${ver%%.*}
  case "$id:$major" in
    almalinux:8 | almalinux:9 | rocky:8 | rocky:9 | centos:8 | centos:9) ;;
    *)
      if ((FORCE)); then
        warn "unsupported OS '${id:-unknown} ${ver}', continuing (--force)"
      else
        need "unsupported OS '${id:-unknown} ${ver}' (AlmaLinux/Rocky/CentOS 8-9 only; --force to continue)"
      fi
      ;;
  esac

  if [[ ! -d $CWP_RES ]] && ((!NO_MODULE)); then
    need "CWP not found ($CWP_RES missing); use --no-module for engine only"
  fi

  local t missing=()
  for t in curl bzip2 sha256sum mysql mysqldump flock setsid timeout install; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  ((${#missing[@]} == 0)) || need "missing tools: $(IFS=" "; echo "${missing[*]}")"

  local p
  for p in engine/bin/vault engine/lib engine/etc/vault.conf.example \
    contrib/cron.d/cwp-vault contrib/logrotate.d/cwp-vault; do
    [[ -e $SRC/$p ]] || die "incomplete source tree: $p missing (run from the repository root)"
  done
  if ((!NO_MODULE)) && [[ ! -d $SRC/cwp-module/admin ]]; then
    die "incomplete source tree: cwp-module/admin missing"
  fi
}

restic_ok() {
  local v
  command -v restic >/dev/null 2>&1 || return 1
  v=$(restic version 2>/dev/null | awk '{print $2; exit}') || return 1
  [[ -n $v ]] || return 1
  [[ $(printf '%s\n%s\n' "$RESTIC_MIN" "$v" | sort -V | head -n1) == "$RESTIC_MIN" ]]
}

install_restic() {
  if restic_ok; then
    info "restic present ($(restic version | awk '{print $2; exit}')), keeping it"
    return
  fi
  local arch sha url
  case $(uname -m) in
    x86_64) arch=amd64 sha=$RESTIC_SHA256_AMD64 ;;
    aarch64) arch=arm64 sha=$RESTIC_SHA256_ARM64 ;;
    *) die "unsupported CPU $(uname -m) for the bundled restic download; install restic >= $RESTIC_MIN yourself" ;;
  esac
  url=https://github.com/restic/restic/releases/download/v$RESTIC_VERSION/restic_${RESTIC_VERSION}_linux_$arch.bz2
  info "Installing restic $RESTIC_VERSION ($arch) from $url"
  if ((DRY)); then
    echo "+ download, verify pinned sha256 $sha, install /usr/local/bin/restic"
    return
  fi
  TMP=$(mktemp -d)
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$TMP/restic.bz2" "$url"
  printf '%s  %s\n' "$sha" "$TMP/restic.bz2" | sha256sum -c --status - \
    || die "restic download failed the pinned sha256 check; nothing installed"
  bzip2 -dc "$TMP/restic.bz2" >"$TMP/restic"
  chmod 0755 "$TMP/restic"
  "$TMP/restic" version >/dev/null || die "downloaded restic does not run"
  install -m 0755 -o root -g root "$TMP/restic" /usr/local/bin/restic
}

install_engine() {
  info "Installing engine to $VAULT_HOME"
  run install -d -m 0755 -o root -g root "$VAULT_HOME"
  # bin/ and lib/ are replaced wholesale (an upgrade drops removed files); etc/ and var/ are never touched.
  run rm -rf -- "${VAULT_HOME:?}/bin" "${VAULT_HOME:?}/lib"
  run install -d -m 0755 -o root -g root "$VAULT_HOME/bin" "$VAULT_HOME/lib"
  local f rel
  while IFS= read -r -d '' f; do
    rel=${f#"$SRC/engine/lib/"}
    run install -D -m 0644 -o root -g root "$f" "$VAULT_HOME/lib/$rel"
  done < <(find "$SRC/engine/lib" -type f -print0)
  while IFS= read -r -d '' f; do
    run install -m 0755 -o root -g root "$f" "$VAULT_HOME/bin/${f##*/}"
  done < <(find "$SRC/engine/bin" -type f -print0)

  run install -d -m 0750 -o root -g root "$VAULT_HOME/etc" "$VAULT_HOME/var" \
    "$VAULT_HOME/var/status" "$VAULT_HOME/var/log" "$VAULT_HOME/var/lock" "$VAULT_HOME/var/cache"
  run install -d -m 0700 -o root -g root /var/lib/cwp-vault /var/lib/cwp-vault/restore

  if [[ -e $VAULT_HOME/etc/vault.conf ]]; then
    info "vault.conf exists, left untouched"
  else
    run install -m 0640 -o root -g root "$SRC/engine/etc/vault.conf.example" "$VAULT_HOME/etc/vault.conf"
  fi
  if [[ -e $VAULT_HOME/etc/secrets.env ]]; then
    info "secrets.env exists, left untouched"
  else
    run install -m 0600 -o root -g root /dev/null "$VAULT_HOME/etc/secrets.env"
  fi

  if [[ -e /usr/local/bin/vault && ! -L /usr/local/bin/vault ]]; then
    die "/usr/local/bin/vault exists and is not a symlink; move it away and re-run"
  fi
  run ln -sfn "$VAULT_HOME/bin/vault" /usr/local/bin/vault
}

# fix-menu is the single implementation of "put the module files + menu line into CWP and keep
# immutability as found". The installer, the daily cron and uninstall.sh (--remove) all use it.
write_fix_menu() {
  info "Installing $VAULT_HOME/bin/fix-menu"
  if ((DRY)); then
    echo "+ write $VAULT_HOME/bin/fix-menu"
    return
  fi
  cat >"$VAULT_HOME/bin/fix-menu" <<'FIXMENU'
#!/usr/bin/env bash
# Re-applies the CWP Vault admin module and menu line from module-copy/ (e.g. after a CWP update
# removed them). Immutable flags are restored to what they were. --remove undoes it. --quiet: errors only.
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

MODE=add QUIET=0
COPY=/usr/local/cwp-vault/module-copy
RES=/usr/local/cwpsrv/htdocs/resources/admin
LOCKDIRS=(/usr/local/cwpsrv/htdocs/admin "$RES")
MENU=$RES/include/3rdparty.php
MARK='module=cwp_vault'
RELOCK=()

say() { ((QUIET)) || printf '%s\n' "$*"; }
die() { printf 'fix-menu: %s\n' "$*" >&2; exit 1; }

for a in "$@"; do
  case $a in
    --remove) MODE=remove ;;
    --quiet) QUIET=1 ;;
    -h | --help) echo "usage: fix-menu [--remove] [--quiet]"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done
((EUID == 0)) || die "must run as root"
[[ -d $RES ]] || die "CWP not found ($RES missing)"
[[ -d $COPY ]] || die "$COPY missing (reinstall CWP Vault)"

is_immutable() {
  local a
  a=$(lsattr -d -- "$1" 2>/dev/null | awk '{print $1}') || return 1
  [[ $a == *i* ]]
}
relock() {
  local d
  for d in ${RELOCK[@]+"${RELOCK[@]}"}; do
    chattr -R +i -- "$d" || echo "fix-menu: could not restore the immutable flag on $d" >&2
  done
  RELOCK=()
}
# EXIT also fires on ERR failures (set -E -e) and, via the INT/TERM trap, on signals.
trap relock EXIT
trap 'exit 130' INT TERM

for d in "${LOCKDIRS[@]}"; do
  if [[ -d $d ]] && is_immutable "$d"; then
    RELOCK+=("$d")
    chattr -R -i -- "$d"
  fi
done

changed=0
while IFS= read -r -d '' f; do
  rel=${f#./}
  if [[ $MODE == add ]]; then
    if ! cmp -s -- "$COPY/$rel" "$RES/$rel" 2>/dev/null; then
      install -D -m 0644 -o root -g root -- "$COPY/$rel" "$RES/$rel"
      changed=1
    fi
  else
    rm -f -- "${RES:?}/${rel:?}"
  fi
done < <(cd "$COPY" && find . -type f ! -name '*.snippet' -print0)

if [[ $MODE == add ]]; then
  [[ -f $COPY/include/3rdparty.php.snippet ]] || die "menu snippet missing in $COPY"
  if ! grep -qF -- "$MARK" "$MENU" 2>/dev/null; then
    install -d -m 0755 -o root -g root -- "${MENU%/*}"
    [[ -f $MENU ]] || install -m 0644 -o root -g root /dev/null "$MENU"
    [[ ! -s $MENU || -z $(tail -c1 "$MENU") ]] || echo >>"$MENU"
    cat -- "$COPY/include/3rdparty.php.snippet" >>"$MENU"
    changed=1
  fi
  if ((changed)); then say "CWP Vault module (re)applied"; else say "CWP Vault module already in place"; fi
else
  if grep -qF -- "$MARK" "$MENU" 2>/dev/null; then
    tmp=$(grep -vF -- "$MARK" "$MENU" || true)
    if [[ -n $tmp ]]; then printf '%s\n' "$tmp" >"$MENU"; else : >"$MENU"; fi
  fi
  rmdir --ignore-fail-on-non-empty -- "$RES/modules/cwp_vault" 2>/dev/null || true
  say "CWP Vault module removed"
fi
FIXMENU
  chmod 0755 "$VAULT_HOME/bin/fix-menu"
}

install_module() {
  if ((NO_MODULE)); then
    info "Skipping CWP module (--no-module)"
    return
  fi
  info "Installing CWP module"
  run rm -rf -- "${VAULT_HOME:?}/module-copy"
  run install -d -m 0755 -o root -g root "$VAULT_HOME/module-copy"
  run cp -a -- "$SRC/cwp-module/admin/." "$VAULT_HOME/module-copy/"
  write_fix_menu
  run "$VAULT_HOME/bin/fix-menu"
}

install_cron_and_logrotate() {
  info "Installing logrotate and cron"
  run install -m 0644 -o root -g root "$SRC/contrib/logrotate.d/cwp-vault" "$LOGROTATE_FILE"
  if ((DRY)); then
    echo "+ install $CRON_FILE if absent (backup line commented unless --enable-cron)"
    return
  fi
  if [[ ! -e $CRON_FILE ]]; then
    if ((ENABLE_CRON)); then
      install -m 0644 -o root -g root "$SRC/contrib/cron.d/cwp-vault" "$CRON_FILE"
    else
      {
        echo "# Nightly backup is DISABLED: enable after 'vault init' succeeds (uncomment the backup line,"
        echo "# or re-run ./install.sh --enable-cron)."
        sed -E 's|^([^#[:space:]].*vault backup)|#\1|' "$SRC/contrib/cron.d/cwp-vault"
      } >"$CRON_FILE"
      chmod 0644 "$CRON_FILE"
    fi
  elif ((ENABLE_CRON)); then
    sed -i -E 's|^#+[[:space:]]*([0-9*].*vault backup)|\1|' "$CRON_FILE"
    info "backup line enabled in existing $CRON_FILE"
  else
    info "$CRON_FILE exists, left untouched"
  fi
  if ((!NO_MODULE)) && ! grep -qF fix-menu "$CRON_FILE"; then
    printf '%s\n' "17 5 * * *  root $VAULT_HOME/bin/fix-menu --quiet" >>"$CRON_FILE"
  fi
}

next_steps() {
  cat <<EOF

CWP Vault $INSTALLER_VERSION installed.

Next steps
  Web:  CWP admin -> CWP Vault -> setup wizard
  CLI:  1. edit $VAULT_HOME/etc/vault.conf   (S3_ENDPOINT, S3_BUCKET, ...)
        2. vault secrets set                  (KEY=VALUE lines on stdin)
        3. vault init
        4. vault test-storage
        5. vault backup --account <one-account>
        6. enable nightly backups: ./install.sh --enable-cron

Store your restic password OFFLINE (password manager + printed copy). If it is lost,
every backup is unreadable and nobody can recover it.
EOF
}

preflight
install_restic
install_engine
install_module
install_cron_and_logrotate
if ((DRY)); then info "Dry run finished; nothing was changed"; else next_steps; fi
