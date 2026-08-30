#!/usr/bin/env bash

set -euo pipefail

STATE_DIR="${HVS_STATE_DIR:-/var/lib/hysteria-vps-setup}"
SYSCTL_FILE="/etc/sysctl.d/90-hysteria-vps-setup.conf"
STATE_FILE="$STATE_DIR/optimize.state"
DRY_RUN="${HVS_DRY_RUN:-0}"
UDP_BUFFER_BYTES="${HVS_UDP_BUFFER_BYTES:-16777216}"
UDP_MIN_BYTES="${HVS_UDP_MIN_BYTES:-16384}"
NETDEV_MAX_BACKLOG="${HVS_NETDEV_MAX_BACKLOG:-250000}"
NETDEV_BUDGET="${HVS_NETDEV_BUDGET:-600}"
OPTMEM_MAX="${HVS_OPTMEM_MAX:-65536}"

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
  local value_name
  for value_name in UDP_BUFFER_BYTES UDP_MIN_BYTES NETDEV_MAX_BACKLOG NETDEV_BUDGET OPTMEM_MAX; do
    is_uint "${!value_name}" || die "$value_name must be an integer"
  done
  if (( 10#$UDP_BUFFER_BYTES < 1048576 || 10#$UDP_BUFFER_BYTES > 1073741824 )); then
    die "HVS_UDP_BUFFER_BYTES must be between 1048576 and 1073741824"
  fi
  if (( 10#$UDP_MIN_BYTES < 4096 || 10#$UDP_MIN_BYTES > 1048576 )); then
    die "HVS_UDP_MIN_BYTES must be between 4096 and 1048576"
  fi
  (( 10#$NETDEV_MAX_BACKLOG >= 1000 && 10#$NETDEV_MAX_BACKLOG <= 1000000 )) \
    || die "HVS_NETDEV_MAX_BACKLOG must be between 1000 and 1000000"
  (( 10#$NETDEV_BUDGET >= 64 && 10#$NETDEV_BUDGET <= 10000 )) \
    || die "HVS_NETDEV_BUDGET must be between 64 and 10000"
  (( 10#$OPTMEM_MAX >= 20480 && 10#$OPTMEM_MAX <= 1048576 )) \
    || die "HVS_OPTMEM_MAX must be between 20480 and 1048576"
}

profile_sysctls() {
  cat <<EOF
net.core.rmem_max=$UDP_BUFFER_BYTES
net.core.wmem_max=$UDP_BUFFER_BYTES
net.core.netdev_max_backlog=$NETDEV_MAX_BACKLOG
net.core.netdev_budget=$NETDEV_BUDGET
net.core.optmem_max=$OPTMEM_MAX
net.ipv4.udp_rmem_min=$UDP_MIN_BYTES
net.ipv4.udp_wmem_min=$UDP_MIN_BYTES
EOF
}

write_sysctl_file() {
  cat > "$SYSCTL_FILE" <<EOF
# hysteria-vps-setup UDP/QUIC network profile
# Hysteria 2 performance guide recommends at least 16 MiB socket maxima on Linux.

net.core.rmem_max = $UDP_BUFFER_BYTES
net.core.wmem_max = $UDP_BUFFER_BYTES
net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG
net.core.netdev_budget = $NETDEV_BUDGET
net.core.optmem_max = $OPTMEM_MAX
net.ipv4.udp_rmem_min = $UDP_MIN_BYTES
net.ipv4.udp_wmem_min = $UDP_MIN_BYTES
EOF
}

verify_profile() {
  local key expected failed=0
  while IFS='=' read -r key expected; do
    if [[ "$(current_sysctl "$key")" != "$expected" ]]; then
      warn "$key is '$(current_sysctl "$key")', expected '$expected'"
      failed=1
    fi
  done < <(profile_sysctls)
  (( failed == 0 ))
}

apply_profile() {
  local previous_rmem previous_wmem previous_backlog previous_budget
  local previous_optmem previous_udp_rmem_min previous_udp_wmem_min

  require_root
  validate_settings

  previous_rmem="$(read_state_value previous_rmem_max 2>/dev/null || current_sysctl net.core.rmem_max)"
  previous_wmem="$(read_state_value previous_wmem_max 2>/dev/null || current_sysctl net.core.wmem_max)"
  previous_backlog="$(read_state_value previous_netdev_max_backlog 2>/dev/null || current_sysctl net.core.netdev_max_backlog)"
  previous_budget="$(read_state_value previous_netdev_budget 2>/dev/null || current_sysctl net.core.netdev_budget)"
  previous_optmem="$(read_state_value previous_optmem_max 2>/dev/null || current_sysctl net.core.optmem_max)"
  previous_udp_rmem_min="$(read_state_value previous_udp_rmem_min 2>/dev/null || current_sysctl net.ipv4.udp_rmem_min)"
  previous_udp_wmem_min="$(read_state_value previous_udp_wmem_min 2>/dev/null || current_sysctl net.ipv4.udp_wmem_min)"

  if [[ "$DRY_RUN" == "1" ]]; then
    info "Dry run: net.core.rmem_max=$UDP_BUFFER_BYTES"
    info "Dry run: net.core.wmem_max=$UDP_BUFFER_BYTES"
    info "Dry run: net.core.netdev_max_backlog=$NETDEV_MAX_BACKLOG"
    info "Dry run: net.core.netdev_budget=$NETDEV_BUDGET"
    info "Dry run: net.core.optmem_max=$OPTMEM_MAX"
    info "Dry run: net.ipv4.udp_rmem_min=$UDP_MIN_BYTES"
    info "Dry run: net.ipv4.udp_wmem_min=$UDP_MIN_BYTES"
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
udp_min_bytes=$UDP_MIN_BYTES
netdev_max_backlog=$NETDEV_MAX_BACKLOG
netdev_budget=$NETDEV_BUDGET
optmem_max=$OPTMEM_MAX
previous_rmem_max=$previous_rmem
previous_wmem_max=$previous_wmem
previous_netdev_max_backlog=$previous_backlog
previous_netdev_budget=$previous_budget
previous_optmem_max=$previous_optmem
previous_udp_rmem_min=$previous_udp_rmem_min
previous_udp_wmem_min=$previous_udp_wmem_min
sysctl_file=$SYSCTL_FILE
EOF
  chmod 0600 "$STATE_FILE"

  ok "Hysteria UDP buffer profile applied"
  info "net.core.rmem_max=$(current_sysctl net.core.rmem_max)"
  info "net.core.wmem_max=$(current_sysctl net.core.wmem_max)"
  info "net.core.netdev_max_backlog=$(current_sysctl net.core.netdev_max_backlog)"
}

restore_sysctl() {
  local key="$1" state_key="$2" value
  value="$(read_state_value "$state_key" 2>/dev/null || true)"
  if is_uint "$value"; then
    sysctl -w "$key=$value" >/dev/null || warn "Could not restore $key"
  fi
}

delete_profile() {
  require_root
  rm -f "$SYSCTL_FILE"
  restore_sysctl net.core.rmem_max previous_rmem_max
  restore_sysctl net.core.wmem_max previous_wmem_max
  restore_sysctl net.core.netdev_max_backlog previous_netdev_max_backlog
  restore_sysctl net.core.netdev_budget previous_netdev_budget
  restore_sysctl net.core.optmem_max previous_optmem_max
  restore_sysctl net.ipv4.udp_rmem_min previous_udp_rmem_min
  restore_sysctl net.ipv4.udp_wmem_min previous_udp_wmem_min
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
  printf 'net.core.netdev_max_backlog=%s\n' "$(current_sysctl net.core.netdev_max_backlog)"
  printf 'net.core.netdev_budget=%s\n' "$(current_sysctl net.core.netdev_budget)"
  printf 'net.core.optmem_max=%s\n' "$(current_sysctl net.core.optmem_max)"
  printf 'net.ipv4.udp_rmem_min=%s\n' "$(current_sysctl net.ipv4.udp_rmem_min)"
  printf 'net.ipv4.udp_wmem_min=%s\n' "$(current_sysctl net.ipv4.udp_wmem_min)"
}

case "${1:-apply}" in
  apply) apply_profile ;;
  delete) delete_profile ;;
  status) status_profile ;;
  *) die "Usage: $0 [apply|delete|status]" ;;
esac
