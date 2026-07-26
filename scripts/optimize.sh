#!/usr/bin/env bash

set -euo pipefail

STATE_DIR="${HVS_STATE_DIR:-/var/lib/hysteria-vps-setup}"
SYSCTL_FILE="/etc/sysctl.d/90-hysteria-vps-setup.conf"
STATE_FILE="$STATE_DIR/optimize.state"
DRY_RUN="${HVS_DRY_RUN:-0}"
UDP_BUFFER_BYTES="${HVS_UDP_BUFFER_BYTES:-16777216}"

info() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Please run as root"
  fi
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

read_state_value() {
  local key="$1"
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      print substr($0, index($0, "=") + 1)
      found=1
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$STATE_FILE"
}

current_sysctl() {
  sysctl -n "$1" 2>/dev/null || echo n/a
}

validate_settings() {
  [[ "$DRY_RUN" =~ ^[01]$ ]] || die "HVS_DRY_RUN must be 0 or 1"
  is_uint "$UDP_BUFFER_BYTES" || die "HVS_UDP_BUFFER_BYTES must be an integer"
  if (( 10#$UDP_BUFFER_BYTES < 1048576 || 10#$UDP_BUFFER_BYTES > 1073741824 )); then
    die "HVS_UDP_BUFFER_BYTES must be between 1048576 and 1073741824"
  fi
}

write_sysctl_file() {
  cat > "$SYSCTL_FILE" <<EOF
# hysteria-vps-setup UDP buffers
# Hysteria 2 performance guide recommends at least 16 MiB on Linux.

net.core.rmem_max = $UDP_BUFFER_BYTES
net.core.wmem_max = $UDP_BUFFER_BYTES
EOF
}

verify_profile() {
  local rmem wmem
  rmem="$(current_sysctl net.core.rmem_max)"
  wmem="$(current_sysctl net.core.wmem_max)"
  [[ "$rmem" == "$UDP_BUFFER_BYTES" && "$wmem" == "$UDP_BUFFER_BYTES" ]]
}

apply_profile() {
  local previous_rmem previous_wmem

  require_root
  validate_settings

  previous_rmem="$(read_state_value previous_rmem_max 2>/dev/null || current_sysctl net.core.rmem_max)"
  previous_wmem="$(read_state_value previous_wmem_max 2>/dev/null || current_sysctl net.core.wmem_max)"

  if [[ "$DRY_RUN" == "1" ]]; then
    info "Dry run: net.core.rmem_max=$UDP_BUFFER_BYTES"
    info "Dry run: net.core.wmem_max=$UDP_BUFFER_BYTES"
    return 0
  fi

  install -d -m 0755 "$STATE_DIR"
  write_sysctl_file
  sysctl -p "$SYSCTL_FILE" >/dev/null

  if ! verify_profile; then
    die "UDP buffer profile was not fully applied"
  fi

  cat > "$STATE_FILE" <<EOF
installed_at=$(date -Is)
udp_buffer_bytes=$UDP_BUFFER_BYTES
previous_rmem_max=$previous_rmem
previous_wmem_max=$previous_wmem
sysctl_file=$SYSCTL_FILE
EOF
  chmod 0600 "$STATE_FILE"

  ok "Hysteria UDP buffer profile applied"
  info "net.core.rmem_max=$(current_sysctl net.core.rmem_max)"
  info "net.core.wmem_max=$(current_sysctl net.core.wmem_max)"
}

delete_profile() {
  local previous_rmem previous_wmem

  require_root
  previous_rmem="$(read_state_value previous_rmem_max 2>/dev/null || true)"
  previous_wmem="$(read_state_value previous_wmem_max 2>/dev/null || true)"

  rm -f "$SYSCTL_FILE"
  if is_uint "$previous_rmem"; then
    sysctl -w "net.core.rmem_max=$previous_rmem" >/dev/null || warn "Could not restore net.core.rmem_max"
  fi
  if is_uint "$previous_wmem"; then
    sysctl -w "net.core.wmem_max=$previous_wmem" >/dev/null || warn "Could not restore net.core.wmem_max"
  fi
  rm -f "$STATE_FILE"
  ok "Hysteria UDP buffer profile removed"
}

status_profile() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    warn "UDP buffer profile is not marked as installed"
  fi
  printf 'net.core.rmem_max=%s\n' "$(current_sysctl net.core.rmem_max)"
  printf 'net.core.wmem_max=%s\n' "$(current_sysctl net.core.wmem_max)"
}

case "${1:-apply}" in
  apply) apply_profile ;;
  delete) delete_profile ;;
  status) status_profile ;;
  *) die "Usage: $0 [apply|delete|status]" ;;
esac
