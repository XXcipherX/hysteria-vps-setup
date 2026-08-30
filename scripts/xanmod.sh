#!/usr/bin/env bash

set -euo pipefail

STATE_DIR="${HVS_STATE_DIR:-/var/lib/hysteria-vps-setup}"
STATE_FILE="$STATE_DIR/xanmod.state"
KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
SOURCE_FILE="/etc/apt/sources.list.d/xanmod-release.sources"
XANMOD_FP="D38D7D1DA1349567ADED882D86F7D09EE734E623"
XANMOD_BRANCH="${HVS_XANMOD_BRANCH:-lts}"
XANMOD_PACKAGE="${HVS_XANMOD_PACKAGE:-}"
INSTALL_DKMS_TOOLS="${HVS_XANMOD_DKMS_TOOLS:-0}"

info() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Please run as root"
  fi
}

arch() {
  uname -m
}

dpkg_arch() {
  dpkg --print-architecture 2>/dev/null || echo unknown
}

detect_virt() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    printf '%s\n' "${virt:-none}"
  else
    echo unknown
  fi
}

is_container() {
  case "$(detect_virt)" in
    openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|wsl|rkt) return 0 ;;
    *) return 1 ;;
  esac
}

codename() {
  local code=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    code="${VERSION_CODENAME:-}"
  fi
  if [[ -z "$code" ]] && command -v lsb_release >/dev/null 2>&1; then
    code="$(lsb_release -sc 2>/dev/null || true)"
  fi
  printf '%s\n' "$code"
}

is_supported_codename() {
  case "$1" in
    focal|jammy|bookworm|trixie|forky|sid|noble|plucky|questing|resolute|stonking|faye|gigi|wilma|xia|zara|zena) return 0 ;;
    *) return 1 ;;
  esac
}

xanmod_suite() {
  case "$1" in
    focal|jammy) echo "bookworm" ;;
    *) echo "$1" ;;
  esac
}

normalize_repo_selection() {
  local code="$1" suite
  suite="$(xanmod_suite "$code")"
  if [[ "$suite" != "$code" ]]; then
    warn "XanMod repo no longer publishes suite '$code'; using '$suite' with the LTS branch"
    XANMOD_BRANCH="lts"
  fi
}

cpu_psabi_level() {
  local flags lvl=1
  flags=" $(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2) "
  has_all() {
    local feature
    for feature in "$@"; do
      [[ "$flags" == *" $feature "* ]] || return 1
    done
    return 0
  }
  has_all cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 && lvl=2
  [[ "$lvl" -eq 2 ]] && has_all avx avx2 bmi1 bmi2 f16c fma abm movbe xsave && lvl=3
  [[ "$lvl" -eq 3 ]] && has_all avx512f avx512bw avx512cd avx512dq avx512vl && lvl=4
  echo "$lvl"
}

package_candidates() {
  local level="$1" branch="$2" prefix
  [[ -n "$XANMOD_PACKAGE" ]] && { echo "$XANMOD_PACKAGE"; return 0; }
  (( level > 3 )) && level=3

  case "$branch" in
    lts) prefix="linux-xanmod-lts" ;;
    main) prefix="linux-xanmod" ;;
    edge) prefix="linux-xanmod-edge" ;;
    rt) prefix="linux-xanmod-rt" ;;
    *) die "Unsupported HVS_XANMOD_BRANCH='$branch' (use lts, main, edge, or rt)" ;;
  esac

  case "$branch:$level" in
    lts:3) echo "$prefix-x64v3 $prefix-x64v2 $prefix-x64v1" ;;
    lts:2) echo "$prefix-x64v2 $prefix-x64v1" ;;
    lts:1) echo "$prefix-x64v1" ;;
    *:3) echo "$prefix-x64v3 $prefix-x64v2" ;;
    *:2) echo "$prefix-x64v2" ;;
    *:1) die "CPU level x86-64-v1 is only supported by the XanMod LTS package family" ;;
  esac
}

preflight() {
  local code darch
  [[ "$(arch)" == "x86_64" ]] || die "XanMod APT packages require x86_64; current arch is $(arch)"
  darch="$(dpkg_arch)"
  [[ "$darch" == "amd64" ]] || die "XanMod APT packages require amd64; dpkg architecture is $darch"
  if is_container; then
    die "Detected container virtualization ($(detect_virt)); a VPS container shares the host kernel and cannot install XanMod"
  fi
  code="$(codename)"
  [[ -n "$code" ]] || die "Could not detect distribution codename"
  is_supported_codename "$code" || die "Unsupported codename '$code' for XanMod repo"
  normalize_repo_selection "$code"
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg apt-transport-https >/dev/null
}

import_key() {
  local tmp_in tmp_out url
  local urls=(
    "https://gitlab.com/afrd.gpg"
    "https://dl.xanmod.org/archive.key"
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${XANMOD_FP: -16}"
  )

  install -d -m 0755 /etc/apt/keyrings
  tmp_in="$(mktemp)"
  tmp_out="$(mktemp)"

  for url in "${urls[@]}"; do
    info "Fetching XanMod key from $url"

    if ! curl -fsSL --connect-timeout 5 --max-time 20 "$url" -o "$tmp_in"; then
      warn "Failed to fetch key from $url"
      continue
    fi

    if ! gpg --yes --dearmor -o "$tmp_out" "$tmp_in" 2>/dev/null; then
      warn "Failed to dearmor key from $url"
      continue
    fi

    if gpg --show-keys --with-colons "$tmp_out" 2>/dev/null \
      | awk -F: '/^fpr:/{print $10}' \
      | grep -qx "$XANMOD_FP"; then
      install -m 0644 "$tmp_out" "$KEYRING"
      rm -f "$tmp_in" "$tmp_out"
      ok "XanMod key installed and fingerprint verified"
      return 0
    fi

    warn "XanMod key fingerprint from $url did not match $XANMOD_FP"
  done

  rm -f "$tmp_in" "$tmp_out"
  die "Could not fetch a valid XanMod key"
}

write_source() {
  local code suite
  code="$(codename)"
  suite="$(xanmod_suite "$code")"
  cat > "$SOURCE_FILE" <<EOF
Types: deb
URIs: https://deb.xanmod.org
Suites: $suite
Components: main
Architectures: amd64
Signed-By: $KEYRING
EOF
  ok "XanMod APT source written for $suite"
}

resolve_package() {
  local candidates pkg
  candidates="$(package_candidates "$(cpu_psabi_level)" "$XANMOD_BRANCH")"
  for pkg in $candidates; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      echo "$pkg"
      return 0
    fi
  done
  die "No XanMod package candidate is available. Tried: $candidates"
}

probe() {
  preflight
  local level candidates first_candidate
  level="$(cpu_psabi_level)"
  candidates="$(package_candidates "$level" "$XANMOD_BRANCH")"
  first_candidate="${candidates%% *}"
  ok "Compatible host: codename=$(codename), arch=$(dpkg_arch), cpu=x86-64-v$level, branch=$XANMOD_BRANCH"
  info "Package candidates: $candidates"
  if [[ -f "$SOURCE_FILE" ]]; then
    if apt-cache show "$first_candidate" >/dev/null 2>&1; then
      ok "APT can see at least the first candidate"
    else
      warn "APT does not see the first candidate yet; run install to add/update the repo"
    fi
  else
    info "XanMod repo is not configured yet"
  fi
}

install_xanmod() {
  require_root
  preflight
  [[ "$INSTALL_DKMS_TOOLS" =~ ^[01]$ ]] || die "HVS_XANMOD_DKMS_TOOLS must be 0 or 1"

  if uname -r | grep -qi xanmod; then
    ok "Already running a XanMod kernel: $(uname -r)"
  fi

  install_dependencies
  import_key
  write_source
  apt-get update -qq

  local pkg
  pkg="$(resolve_package)"
  info "Installing $pkg"
  apt-get install -y "$pkg"

  if [[ "$INSTALL_DKMS_TOOLS" == "1" ]]; then
    info "Installing minimal DKMS toolchain for out-of-tree kernel modules"
    apt-get install -y --no-install-recommends dkms libelf-dev clang lld llvm
  fi

  install -d -m 0755 "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
installed_at=$(date -Is)
codename=$(codename)
xanmod_suite=$(xanmod_suite "$(codename)")
cpu_psabi=x86-64-v$(cpu_psabi_level)
branch=$XANMOD_BRANCH
package=$pkg
keyring=$KEYRING
source_file=$SOURCE_FILE
reboot_required=1
EOF
  ok "XanMod package installed: $pkg"
  warn "Reboot is required before the XanMod kernel becomes active"
}

status() {
  local active repo_configured
  if uname -r | grep -qi xanmod; then
    active=yes
  else
    active=no
  fi
  if [[ -f "$SOURCE_FILE" ]]; then
    repo_configured=yes
  else
    repo_configured=no
  fi

  printf 'kernel=%s\n' "$(uname -r)"
  printf 'xanmod_active=%s\n' "$active"
  printf 'tcp_congestion_control=%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
  printf 'repo_configured=%s\n' "$repo_configured"
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  fi
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W 'linux-xanmod*' 'linux-image*-xanmod*' 'linux-headers*-xanmod*' 2>/dev/null || true
  fi
}

remove_xanmod() {
  require_root
  if uname -r | grep -qi xanmod; then
    die "Refusing to purge XanMod while booted into $(uname -r). Boot a stock kernel first, then rerun remove."
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y 'linux-xanmod-*' 'linux-image-*-xanmod*' 'linux-headers-*-xanmod*' || true
  rm -f "$SOURCE_FILE" "$KEYRING" "$STATE_FILE"
  apt-get update -qq || true
  ok "XanMod packages and repository config removed"
  info "Review 'apt autoremove' separately if you also want to remove unused dependencies"
}

usage() {
  cat <<EOF
Usage: sudo bash scripts/xanmod.sh [probe|install|status|remove]

Defaults:
  HVS_XANMOD_BRANCH=lts
  HVS_XANMOD_DKMS_TOOLS=0

Advanced:
  HVS_XANMOD_BRANCH=main|edge|rt
  HVS_XANMOD_PACKAGE=linux-xanmod-lts-x64v3
EOF
}

case "${1:-status}" in
  probe) probe ;;
  install) install_xanmod ;;
  status) status ;;
  remove) remove_xanmod ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
