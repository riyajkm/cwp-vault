#!/usr/bin/env bash
# CWP Vault installer. Run as root from a checkout or release tarball: sudo ./install.sh
# Idempotent; never overwrites existing config or secrets. See docs/INSTALL.md.
# Modes: install (default), --upgrade (newer checkout over an install), --check (read-only report).
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

INSTALLER_VERSION=0.5.0
VAULT_HOME=/usr/local/cwp-vault
CWP_RES=/usr/local/cwpsrv/htdocs/resources/admin
CRON_FILE=/etc/cron.d/cwp-vault
LOGROTATE_FILE=/etc/logrotate.d/cwp-vault

# restic is pinned: the hash below is compared against the downloaded file, never against a
# hash fetched alongside it. On top of that, SHA256SUMS is verified with gpg against restic's
# release signing key, whose fingerprint is pinned here (not trusted from the download).
# Fingerprint source: https://restic.readthedocs.io/en/stable/020_installation.html (verifying
# releases) and the key file https://restic.net/gpg-key-alex.asc (Alexander Neumann).
RESTIC_GPG_FPR=CF8F18F2844575973F79D4E191A6868BD3F7A907
RESTIC_GPG_KEY_URL=https://restic.net/gpg-key-alex.asc
RESTIC_MIN=0.17.0
RESTIC_VERSION=0.19.1
RESTIC_SHA256_AMD64=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
RESTIC_SHA256_ARM64=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRY=0 ENABLE_CRON=0 FORCE=0 NO_MODULE=0 UPGRADE=0 CHECK=0 STRICT=0
TMP='' OLD_VERSION='' NEW_VERSION=''

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# Hard error normally; in --dry-run only a warning so the plan can still be printed.
need() { if ((DRY)); then warn "$* (would fail)"; else die "$*"; fi; }
act() { if ((DRY)); then (IFS=' '; printf '+ %s\n' "$*"); else "$@"; fi; }
cleanup() { [[ -z $TMP ]] || rm -rf -- "${TMP:?}"; }

usage() {
  cat <<USAGE
CWP Vault installer $INSTALLER_VERSION
Usage: sudo ./install.sh [options]
  --dry-run       print the actions, change nothing
  --enable-cron   enable the nightly backup line in $CRON_FILE
                  (default: shipped commented out until 'vault init' succeeds)
  --force         continue on an unsupported OS; with --upgrade, allow a downgrade
  --no-module     engine only; skip the CWP admin module and menu entry
  --upgrade       update an existing install from this checkout: engine, module, missing
                  cron lines. Config, secrets and existing cron lines are kept
  --check         read-only health report of the installed system (non-zero on problems)
  --strict        fail instead of warn when gpg is missing for the restic signature check
  --version       print the installer version
  -h, --help      this text
USAGE
}

parse_args() {
  while (($#)); do
    case $1 in
      --dry-run) DRY=1 ;;
      --enable-cron) ENABLE_CRON=1 ;;
      --force) FORCE=1 ;;
      --no-module) NO_MODULE=1 ;;
      --upgrade) UPGRADE=1 ;;
      --check) CHECK=1 ;;
      --strict) STRICT=1 ;;
      --version) echo "$INSTALLER_VERSION"; exit 0 ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done
  if ((UPGRADE && CHECK)); then die "--upgrade and --check cannot be combined"; fi
}

# ver_gt A B: true when version A is strictly newer than B.
ver_gt() { [[ $1 != "$2" && $(printf '%s
%s
' "$1" "$2" | sort -V | tail -n1) == "$1" ]]; }

src_version() { sed -n 's/^VAULT_VERSION=//p' "$SRC/engine/bin/vault" | head -n1; }
installed_version() {
  local v=
  [[ -r $VAULT_HOME/VERSION ]] && v=$(head -n1 "$VAULT_HOME/VERSION")
  if [[ -z $v && -x $VAULT_HOME/bin/vault ]]; then v=$("$VAULT_HOME/bin/vault" version 2>/dev/null | awk '{print $2; exit}') || v=; fi
  printf '%s' "$v"
}

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

# verify_restic_signature DIR FILE: SHA256SUMS + .asc for the pinned release are checked with gpg in a
# throw-away 0700 GNUPGHOME against the pinned key fingerprint, then FILE's line must match the pinned
# hash. Bad signature or mismatch: die. gpg or key/sums unobtainable: die with --strict, else warn
# (the pinned sha256 check still runs).
verify_restic_signature() {
  local dir=$1 file=$2 pinned=$3 base gh st sig_fpr line
  base=https://github.com/restic/restic/releases/download/v$RESTIC_VERSION
  if ! command -v gpg >/dev/null 2>&1; then
    if ((STRICT)); then die "gpg not found and --strict was given; install gnupg2 or drop --strict"; fi
    warn "gpg not found: skipping the restic signature check (pinned sha256 still verified; --strict makes this fatal)"
    return 0
  fi
  gh=$dir/gnupg
  mkdir "$gh" && chmod 0700 "$gh"
  if ! { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$dir/SHA256SUMS" "$base/SHA256SUMS"     && curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$dir/SHA256SUMS.asc" "$base/SHA256SUMS.asc"     && curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$dir/restic-key.asc" "$RESTIC_GPG_KEY_URL"; }; then
    if ((STRICT)); then die "could not download restic SHA256SUMS/signature/key and --strict was given"; fi
    warn "could not download the restic signature files: skipping the signature check (pinned sha256 still verified)"
    return 0
  fi
  gpg --homedir "$gh" --batch --quiet --import "$dir/restic-key.asc" 2>/dev/null || die "could not import the restic signing key"
  # Trust only the pinned fingerprint: it must be in the imported keyring before anything is verified.
  gpg --homedir "$gh" --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="fpr"{print $10}'     | grep -qx -- "$RESTIC_GPG_FPR" || die "downloaded restic key does not contain the pinned fingerprint $RESTIC_GPG_FPR"
  st=$(gpg --homedir "$gh" --batch --status-fd 1 --verify "$dir/SHA256SUMS.asc" "$dir/SHA256SUMS" 2>/dev/null) || true
  # VALIDSIG's last field is the primary key fingerprint of the signer.
  sig_fpr=$(awk '$2=="VALIDSIG"{print $NF}' <<<"$st")
  [[ $sig_fpr == "$RESTIC_GPG_FPR" ]] || die "restic SHA256SUMS signature is not valid for the pinned key $RESTIC_GPG_FPR; nothing installed"
  line=$(awk -v f="$file" '$2==f{print $1}' "$dir/SHA256SUMS")
  [[ $line == "$pinned" ]] || die "signed SHA256SUMS does not list the pinned hash for $file; nothing installed"
  info "restic signature OK (key $RESTIC_GPG_FPR)"
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
    echo "+ download, verify gpg signature (key $RESTIC_GPG_FPR) and pinned sha256 $sha, install /usr/local/bin/restic"
    return
  fi
  TMP=$(mktemp -d)
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$TMP/restic.bz2" "$url"
  verify_restic_signature "$TMP" "restic_${RESTIC_VERSION}_linux_$arch.bz2" "$sha"
  printf '%s  %s\n' "$sha" "$TMP/restic.bz2" | sha256sum -c --status - \
    || die "restic download failed the pinned sha256 check; nothing installed"
  bzip2 -dc "$TMP/restic.bz2" >"$TMP/restic"
  chmod 0755 "$TMP/restic"
  "$TMP/restic" version >/dev/null || die "downloaded restic does not run"
  install -m 0755 -o root -g root "$TMP/restic" /usr/local/bin/restic
}

install_engine() {
  info "Installing engine to $VAULT_HOME"
  act install -d -m 0755 -o root -g root "$VAULT_HOME"
  # bin/ and lib/ are replaced wholesale (an upgrade drops removed files); etc/ and var/ are never touched.
  act rm -rf -- "${VAULT_HOME:?}/bin" "${VAULT_HOME:?}/lib"
  act install -d -m 0755 -o root -g root "$VAULT_HOME/bin" "$VAULT_HOME/lib"
  local f rel
  while IFS= read -r -d '' f; do
    rel=${f#"$SRC/engine/lib/"}
    act install -D -m 0644 -o root -g root "$f" "$VAULT_HOME/lib/$rel"
  done < <(find "$SRC/engine/lib" -type f -print0)
  while IFS= read -r -d '' f; do
    act install -m 0755 -o root -g root "$f" "$VAULT_HOME/bin/${f##*/}"
  done < <(find "$SRC/engine/bin" -type f -print0)

  act install -d -m 0750 -o root -g root "$VAULT_HOME/etc" "$VAULT_HOME/var" \
    "$VAULT_HOME/var/status" "$VAULT_HOME/var/log" "$VAULT_HOME/var/lock" "$VAULT_HOME/var/cache"
  act install -d -m 0700 -o root -g root /var/lib/cwp-vault /var/lib/cwp-vault/restore

  if [[ -e $VAULT_HOME/etc/vault.conf ]]; then
    info "vault.conf exists, left untouched"
  else
    act install -m 0640 -o root -g root "$SRC/engine/etc/vault.conf.example" "$VAULT_HOME/etc/vault.conf"
  fi
  if [[ -e $VAULT_HOME/etc/secrets.env ]]; then
    info "secrets.env exists, left untouched"
  else
    act install -m 0600 -o root -g root /dev/null "$VAULT_HOME/etc/secrets.env"
  fi

  if ((DRY)); then echo "+ write $VAULT_HOME/VERSION ($(src_version))"; else src_version >"$VAULT_HOME/VERSION"; fi

  if [[ -e /usr/local/bin/vault && ! -L /usr/local/bin/vault ]]; then
    die "/usr/local/bin/vault exists and is not a symlink; move it away and re-run"
  fi
  act ln -sfn "$VAULT_HOME/bin/vault" /usr/local/bin/vault
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
# Only the tree the module is written into. CWP's own htdocs/admin is never touched.
LOCKDIRS=("$RES")
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
    # chattr can't set flags on symlinks (CWP has some), so skip them instead of failing.
    find "$d" -xdev ! -type l -exec chattr +i -- {} + || echo "fix-menu: could not restore the immutable flag on $d" >&2
  done
  RELOCK=()
}
# EXIT also fires on ERR failures (set -E -e) and, via the INT/TERM trap, on signals.
trap relock EXIT
trap 'exit 130' INT TERM

for d in "${LOCKDIRS[@]}"; do
  if [[ -d $d ]] && is_immutable "$d"; then
    RELOCK+=("$d")
    find "$d" -xdev ! -type l -exec chattr -i -- {} +
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
  act rm -rf -- "${VAULT_HOME:?}/module-copy"
  act install -d -m 0755 -o root -g root "$VAULT_HOME/module-copy"
  act cp -a -- "$SRC/cwp-module/admin/." "$VAULT_HOME/module-copy/"
  write_fix_menu
  act "$VAULT_HOME/bin/fix-menu"
}

# cron_missing_lines SHIPPED EXISTING: prints the active lines of SHIPPED whose command is not
# present in EXISTING, either live or commented out (so a disabled backup line stays disabled and
# a changed schedule stays as the admin set it). Environment lines (VAR=value) are not merged.
cron_missing_lines() {
  local shipped=$1 existing=$2 line cmd have
  have=$(awk '{ sub(/^#+[ 	]*/, ""); if (NF >= 7) { c = $7; for (i = 8; i <= NF; i++) c = c " " $i; print c } }' "$existing")
  while IFS= read -r line; do
    [[ $line =~ ^[0-9*] ]] || continue
    cmd=$(awk '{ if (NF >= 7) { c = $7; for (i = 8; i <= NF; i++) c = c " " $i; print c } }' <<<"$line")
    [[ -n $cmd ]] || continue
    grep -qxF -- "$cmd" <<<"$have" || printf '%s
' "$line"
  done <"$shipped"
}

upgrade_cron_and_logrotate() {
  info "Updating logrotate and cron"
  act install -m 0644 -o root -g root "$SRC/contrib/logrotate.d/cwp-vault" "$LOGROTATE_FILE"
  if [[ ! -e $CRON_FILE ]]; then
    warn "$CRON_FILE missing; installing it with the backup line disabled"
    ENABLE_CRON=0 install_cron_and_logrotate
    return
  fi
  local add
  add=$(cron_missing_lines "$SRC/contrib/cron.d/cwp-vault" "$CRON_FILE")
  if [[ -z $add ]]; then
    info "cron file already has every shipped line"
  elif ((DRY)); then
    printf '+ append to %s:
%s
' "$CRON_FILE" "$add"
  else
    [[ ! -s $CRON_FILE || -z $(tail -c1 "$CRON_FILE") ]] || echo >>"$CRON_FILE"
    printf '%s
' "$add" >>"$CRON_FILE"
    info "added missing cron line(s) to $CRON_FILE"
  fi
  if ((ENABLE_CRON)); then
    act sed -i -E 's|^#+[[:space:]]*([0-9*].*vault backup)||' "$CRON_FILE"
  fi
}

install_cron_and_logrotate() {
  info "Installing logrotate and cron"
  act install -m 0644 -o root -g root "$SRC/contrib/logrotate.d/cwp-vault" "$LOGROTATE_FILE"
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

upgrade_prepare() {
  [[ -e $VAULT_HOME/bin/vault ]] || die "no CWP Vault install found in $VAULT_HOME; run ./install.sh without --upgrade"
  OLD_VERSION=$(installed_version)
  NEW_VERSION=$(src_version)
  [[ -n $NEW_VERSION ]] || die "cannot read the version from $SRC/engine/bin/vault"
  if [[ -n $OLD_VERSION ]] && ver_gt "$OLD_VERSION" "$NEW_VERSION" && ((!FORCE)); then
    die "refusing to downgrade $OLD_VERSION -> $NEW_VERSION (this checkout is older; use --force to override)"
  fi
  info "Upgrading CWP Vault ${OLD_VERSION:-unknown} -> $NEW_VERSION"
  # A module-less install has no fix-menu to keep; do not (re)create CWP files it never had.
  [[ -d $VAULT_HOME/module-copy ]] || NO_MODULE=1
}

# check_install: read-only health report. Never prints config or secret values.
check_install() {
  local problems=0 v f rel menu=$CWP_RES/include/3rdparty.php vbin=$VAULT_HOME/bin/vault js res
  ok() { printf 'ok    %s\n' "$*"; }
  bad() { printf 'FAIL  %s\n' "$*"; problems=$((problems + 1)); }
  ((EUID == 0)) || die "--check needs root to read $VAULT_HOME/etc (use sudo)"

  if restic_ok; then ok "restic $(restic version | awk '{print $2; exit}') (>= $RESTIC_MIN)"; else bad "restic missing or older than $RESTIC_MIN (re-run ./install.sh)"; fi

  v=$(installed_version)
  if [[ -x $vbin && -n $v ]]; then ok "vault $v"; else bad "vault engine not installed in $VAULT_HOME (run ./install.sh)"; fi
  [[ ! -x $vbin ]] || [[ $(readlink /usr/local/bin/vault 2>/dev/null) == "$vbin" ]] || bad "/usr/local/bin/vault is not a link to $vbin"

  if [[ -f $VAULT_HOME/etc/vault.conf ]]; then ok "config present"; else bad "$VAULT_HOME/etc/vault.conf missing"; fi
  if [[ ! -f $VAULT_HOME/etc/secrets.env ]]; then
    bad "$VAULT_HOME/etc/secrets.env missing"
  elif [[ ! -s $VAULT_HOME/etc/secrets.env ]]; then
    bad "secrets.env is empty (run: vault secrets set)"
  elif [[ $(stat -c %a "$VAULT_HOME/etc/secrets.env") != 600 ]]; then
    bad "secrets.env permissions are $(stat -c %a "$VAULT_HOME/etc/secrets.env"), expected 600"
  else
    ok "secrets present (mode 600)"
  fi

  if [[ ! -f $CRON_FILE ]]; then
    bad "$CRON_FILE missing"
  elif grep -Eq '^[0-9*].*vault backup' "$CRON_FILE"; then
    ok "nightly backup cron line enabled"
  else
    bad "nightly backup cron line is disabled in $CRON_FILE (enable after 'vault init': ./install.sh --enable-cron)"
  fi

  if [[ -d $VAULT_HOME/module-copy ]]; then
    local miss=0
    while IFS= read -r -d '' f; do
      rel=${f#"$VAULT_HOME/module-copy/"}
      cmp -s -- "$f" "$CWP_RES/$rel" || miss=1
    done < <(find "$VAULT_HOME/module-copy" -type f ! -name '*.snippet' -print0)
    if ((miss)); then bad "CWP module files missing or changed in $CWP_RES (run: $VAULT_HOME/bin/fix-menu)"; else ok "CWP module files in place"; fi
    if grep -qF -- 'module=cwp_vault' "$menu" 2>/dev/null; then ok "CWP menu line present"; else bad "CWP menu line missing (run: $VAULT_HOME/bin/fix-menu)"; fi
  else
    ok "CWP module not installed (engine only)"
  fi

  if [[ -x $vbin ]] && js=$("$vbin" status --json 2>/dev/null); then
    res=$(grep -Eo '"result": *"[^"]*"' <<<"$js" | sed -E 's/.*"([^"]*)"$/\1/' | sort | uniq -c | awk '{printf "%s%s=%s", (n++ ? " " : ""), $2, $1}') || res=
    if [[ -z $res || $res == never=* && $res != *" "* ]]; then
      ok "last backup: none recorded yet (${res:-no accounts})"
    elif grep -Eo '"result": *"[^"]*"' <<<"$js" | grep -Evq '"(ok|never)"'; then
      bad "last backup results include failures: $res (see: vault status)"
    else
      ok "last backup results: $res"
    fi
  else
    bad "'vault status --json' failed"
  fi

  if ((problems)); then printf '%d problem(s) found\n' "$problems" >&2; return 1; fi
  echo "All checks passed"
}

main() {
  parse_args "$@"
  trap cleanup EXIT
  trap 'die "failed at line $LINENO (command: $BASH_COMMAND)"' ERR
  if ((CHECK)); then check_install; return; fi
  ((!UPGRADE)) || upgrade_prepare
  preflight
  install_restic
  install_engine
  install_module
  if ((UPGRADE)); then upgrade_cron_and_logrotate; else install_cron_and_logrotate; fi
  if ((DRY)); then
    info "Dry run finished; nothing was changed"
  elif ((UPGRADE)); then
    info "CWP Vault upgraded: ${OLD_VERSION:-unknown} -> $NEW_VERSION (config, secrets and existing cron lines kept)"
  else
    next_steps
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
