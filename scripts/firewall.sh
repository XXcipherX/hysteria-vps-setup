#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TABLE_NAME="hysteria_vps_filter"
CONF_DIR="${HVS_CONF_DIR:-/etc/hysteria-vps-setup}"
STATE_DIR="${HVS_STATE_DIR:-/var/lib/hysteria-vps-setup}"
NFT_FILE="$CONF_DIR/firewall.nft"
SERVICE_FILE="/etc/systemd/system/hysteria-vps-firewall.service"
SAFETY_UNIT="hysteria-vps-fw-safety"
BLOCKLIST_FILE="${HVS_BLOCKLIST_FILE:-$SCRIPT_DIR/../lists/cyberok-skipa-v4.txt}"
MANUAL_BLOCKLIST_FILE="$CONF_DIR/manual-blocklist.txt"
SCANNER_LOG_TAG="[scanners-activity]"

read_state_value() {
  local file="$1" key="$2"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      print substr($0, index($0, "=") + 1)
      found=1
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

default_ssh_port() {
  local file value
  for file in "$STATE_DIR/firewall.state" "$STATE_DIR/install.env"; do
    value="$(read_state_value "$file" ssh_port 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  printf '22\n'
}

default_service_ports() {
  local key="$1" fallback="$2" value
  value="$(read_state_value "$STATE_DIR/firewall.state" "$key" 2>/dev/null || true)"
  printf '%s\n' "${value:-$fallback}"
}

SSH_PORT="${SSH_PORT:-$(default_ssh_port)}"
TCP_PORTS="${HVS_TCP_PORTS:-$(default_service_ports tcp_ports 80,443,46002)}"
UDP_PORTS="${HVS_UDP_PORTS:-$(default_service_ports udp_ports 443,56000,46000)}"
WHITELIST="${HVS_WHITELIST:-}"
SYN_RATE="${HVS_SYN_RATE:-200}"
SYN_BURST="${HVS_SYN_BURST:-400}"
UDP_RATE="${HVS_UDP_RATE:-200}"
UDP_BURST="${HVS_UDP_BURST:-400}"
SSH_RATE="${HVS_SSH_RATE:-6}"
SSH_BURST="${HVS_SSH_BURST:-5}"
ICMP_RATE="${HVS_ICMP_RATE:-10}"
ICMP_BURST="${HVS_ICMP_BURST:-20}"
ICMP_TIMEOUT="${HVS_ICMP_TIMEOUT:-5m}"
SSH_TIMEOUT="${HVS_SSH_TIMEOUT:-15m}"
SVC_TIMEOUT="${HVS_SVC_TIMEOUT:-5m}"
SCANNER_LOG_GLOBAL_RATE="${HVS_SCANNER_LOG_GLOBAL_RATE:-30}"
SCANNER_LOG_GLOBAL_BURST="${HVS_SCANNER_LOG_GLOBAL_BURST:-50}"
SCANNER_LOG_TIMEOUT="${HVS_SCANNER_LOG_TIMEOUT:-1h}"
SCANNER_LOG_SET_SIZE="${HVS_SCANNER_LOG_SET_SIZE:-16384}"
SAFETY_DELAY="${HVS_SAFETY_DELAY:-300}"
SAFETY_CONFIRM_MARGIN=5
DRY_RUN="${HVS_DRY_RUN:-0}"
ASSUME_FIREWALL_OK="${HVS_ASSUME_FIREWALL_OK:-0}"
APPLY_FILE=""
ROLLBACK_FILE=""
PENDING_MANUAL_FILE=""

info() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup_apply_file() {
  if [[ -n "${APPLY_FILE:-}" ]]; then rm -f -- "$APPLY_FILE"; fi
  if [[ -n "${PENDING_MANUAL_FILE:-}" ]]; then rm -f -- "$PENDING_MANUAL_FILE"; fi
}

trap cleanup_apply_file EXIT

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Please run as root"
  fi
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_uint() {
  is_uint "$1" && (( 10#$1 > 0 ))
}

is_port() {
  is_uint "$1" && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_timeout() {
  [[ "$1" =~ ^[1-9][0-9]*(ms|s|m|h|d)$ ]]
}

validate_port_list() {
  local ports="$1" name="$2" port
  [[ -n "$ports" ]] || die "$name cannot be empty"
  [[ "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "$name must be a comma-separated list of ports"
  for port in ${ports//,/ }; do
    is_port "$port" || die "$name contains invalid port: $port"
  done
}

validate_settings() {
  local value_name
  is_port "$SSH_PORT" || die "SSH_PORT is invalid: $SSH_PORT"
  validate_port_list "$TCP_PORTS" HVS_TCP_PORTS
  validate_port_list "$UDP_PORTS" HVS_UDP_PORTS
  for value_name in SYN_RATE SYN_BURST UDP_RATE UDP_BURST SSH_RATE SSH_BURST ICMP_RATE ICMP_BURST SCANNER_LOG_GLOBAL_RATE SCANNER_LOG_GLOBAL_BURST SCANNER_LOG_SET_SIZE SAFETY_DELAY; do
    is_positive_uint "${!value_name}" || die "$value_name must be a positive integer"
  done
  (( 10#$SAFETY_DELAY > SAFETY_CONFIRM_MARGIN )) \
    || die "HVS_SAFETY_DELAY must be greater than ${SAFETY_CONFIRM_MARGIN}s"
  for value_name in ICMP_TIMEOUT SSH_TIMEOUT SVC_TIMEOUT SCANNER_LOG_TIMEOUT; do
    is_timeout "${!value_name}" || die "$value_name must use nft timeout format like 30s, 1h, or 1d"
  done
  [[ "$DRY_RUN" =~ ^[01]$ ]] || die "HVS_DRY_RUN must be 0 or 1"
  [[ "$ASSUME_FIREWALL_OK" =~ ^[01]$ ]] || die "HVS_ASSUME_FIREWALL_OK must be 0 or 1"
}

ssh_client_ip() {
  local ip="${SSH_CONNECTION:-}"
  ip="${ip%% *}"
  if [[ -z "$ip" ]]; then
    ip="${SSH_CLIENT:-}"
    ip="${ip%% *}"
  fi
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$ip" == *:* ]]; then
    [[ "$ip" != "127.0.0.1" && "$ip" != "::1" ]] && printf '%s\n' "$ip"
  fi
}

append_whitelist_item() {
  local item="$1"
  [[ -n "$item" ]] || return 0

  if [[ "$item" == *:* ]]; then
    [[ "$item" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] || die "Invalid IPv6/CIDR whitelist item: $item"
    WL6+=("${item}")
  elif [[ "$item" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
    WL4+=("${item}")
  else
    die "Invalid IPv4/IPv6 whitelist item: $item"
  fi
}

collect_whitelist() {
  local item admin_ip
  WL4=()
  WL6=()
  for item in ${WHITELIST//,/ }; do
    append_whitelist_item "$item"
  done
  admin_ip="$(ssh_client_ip || true)"
  if [[ -n "$admin_ip" ]]; then
    append_whitelist_item "$admin_ip"
    info "Auto-whitelisted current SSH client IP: $admin_ip"
  fi
}

append_blocklist_item() {
  local item="$1"
  [[ "$item" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
    || die "Invalid IPv4/CIDR blocklist item: $item"
  BL4+=("$item")
}

collect_blocklist() {
  local line
  BL4=()
  [[ -f "$BLOCKLIST_FILE" && ! -L "$BLOCKLIST_FILE" && -r "$BLOCKLIST_FILE" ]] \
    || die "Blocklist file is missing, unreadable, or a symlink: $BLOCKLIST_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    [[ "$line" != *[[:space:]]* ]] || die "Blocklist entries must contain one IPv4/CIDR per line: $line"
    append_blocklist_item "$line"
  done < "$BLOCKLIST_FILE"

  ((${#BL4[@]} > 0)) || die "Blocklist file contains no IPv4/CIDR entries: $BLOCKLIST_FILE"
}

is_manual_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:]+$ ]]
}

collect_manual_blocklist() {
  local line
  MANUAL4=()
  MANUAL6=()
  [[ -e "$MANUAL_BLOCKLIST_FILE" || -L "$MANUAL_BLOCKLIST_FILE" ]] || return 0
  [[ -f "$MANUAL_BLOCKLIST_FILE" && ! -L "$MANUAL_BLOCKLIST_FILE" && -r "$MANUAL_BLOCKLIST_FILE" ]] \
    || die "Manual blocklist is unreadable or a symlink: $MANUAL_BLOCKLIST_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    is_manual_ip "$line" || die "Invalid manual blocklist IP: $line"
    if [[ "$line" == *:* ]]; then MANUAL6+=("$line"); else MANUAL4+=("$line"); fi
  done < "$MANUAL_BLOCKLIST_FILE"
}

join_by_comma() {
  local item out=""
  for item in "$@"; do
    out="${out:+$out, }$item"
  done
  printf '%s' "$out"
}

format_ports_for_nft() {
  local ports="$1" port out=""
  for port in ${ports//,/ }; do
    out="${out:+$out, }$port"
  done
  printf '%s' "$out"
}

set_elements_block() {
  local values="$1"
  if [[ -n "$values" ]]; then
    printf '        elements = { %s }\n' "$values"
  fi
}

ensure_ruleset_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || install -d -m 0755 "$dir"
}

generate_ruleset() {
  local replace_table="${3:-0}" ruleset_dir ruleset_file="${1:-$NFT_FILE}" table_name="${2:-$TABLE_NAME}" tcp_ports udp_ports wl4 wl6 bl4 manual4 manual6
  tcp_ports="$(format_ports_for_nft "$TCP_PORTS")"
  udp_ports="$(format_ports_for_nft "$UDP_PORTS")"
  wl4="$(join_by_comma "${WL4[@]}")"
  wl6="$(join_by_comma "${WL6[@]}")"
  bl4="$(join_by_comma "${BL4[@]}")"
  manual4="$(join_by_comma "${MANUAL4[@]}")"
  manual6="$(join_by_comma "${MANUAL6[@]}")"

  ruleset_dir="$(dirname -- "$ruleset_file")"
  ensure_ruleset_dir "$ruleset_dir"
  cat > "$ruleset_file" <<EOF
#!/usr/sbin/nft -f

$(if [[ "$replace_table" == "1" ]]; then printf 'delete table inet %s' "$table_name"; fi)
table inet $table_name {
    set whitelist_v4 {
        type ipv4_addr
        flags interval
        auto-merge
$(set_elements_block "$wl4")
    }

    set whitelist_v6 {
        type ipv6_addr
        flags interval
        auto-merge
$(set_elements_block "$wl6")
    }

    set scanner_blocklist_v4 {
        type ipv4_addr
        flags interval
        auto-merge
$(set_elements_block "$bl4")
    }

    set manual_blocklist_v4 {
        type ipv4_addr
$(set_elements_block "$manual4")
    }

    set manual_blocklist_v6 {
        type ipv6_addr
$(set_elements_block "$manual6")
    }

    set scanner_port4 {
        type ipv4_addr . inet_proto . inet_service
        size $SCANNER_LOG_SET_SIZE
        flags dynamic,timeout
        timeout $SCANNER_LOG_TIMEOUT
    }

    set scanner_proto4 {
        type ipv4_addr . inet_proto
        size $SCANNER_LOG_SET_SIZE
        flags dynamic,timeout
        timeout $SCANNER_LOG_TIMEOUT
    }

    limit scanner_log_all {
        rate $SCANNER_LOG_GLOBAL_RATE/minute burst $SCANNER_LOG_GLOBAL_BURST packets
    }

    chain bad_tcp_flags {
        limit rate 5/second log prefix "[hysteria-vps badflags] " level info
        counter drop
    }

    chain prerouting {
        type filter hook prerouting priority raw; policy accept;

        ip saddr @scanner_blocklist_v4 meta l4proto { tcp, udp } ip saddr . meta l4proto . th dport != @scanner_port4 limit name "scanner_log_all" add @scanner_port4 { ip saddr . meta l4proto . th dport timeout $SCANNER_LOG_TIMEOUT } log prefix "$SCANNER_LOG_TAG " level info
        ip saddr @scanner_blocklist_v4 meta l4proto { tcp, udp } ip saddr . meta l4proto . th dport @scanner_port4 update @scanner_port4 { ip saddr . meta l4proto . th dport timeout $SCANNER_LOG_TIMEOUT }
        ip saddr @scanner_blocklist_v4 meta l4proto != { tcp, udp } ip saddr . meta l4proto != @scanner_proto4 limit name "scanner_log_all" add @scanner_proto4 { ip saddr . meta l4proto timeout $SCANNER_LOG_TIMEOUT } log prefix "$SCANNER_LOG_TAG " level info
        ip saddr @scanner_blocklist_v4 meta l4proto != { tcp, udp } ip saddr . meta l4proto @scanner_proto4 update @scanner_proto4 { ip saddr . meta l4proto timeout $SCANNER_LOG_TIMEOUT }
        ip saddr @scanner_blocklist_v4 counter drop
        ip saddr @manual_blocklist_v4 counter drop
        ip6 saddr @manual_blocklist_v6 counter drop
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept
        iifname "csqtt1" ip saddr 10.66.67.0/24 accept

        meta nfproto ipv4 udp sport 67 udp dport 68 accept
        meta nfproto ipv6 udp sport 547 udp dport 546 accept

        ct state established,related accept
        ct state invalid drop

        ip saddr @whitelist_v4 accept
        ip6 saddr @whitelist_v6 accept

        tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 jump bad_tcp_flags
        tcp flags & (fin|syn|rst|psh|ack|urg) == (fin|syn|rst|psh|ack|urg) jump bad_tcp_flags
        tcp flags & (fin|psh|urg) == (fin|psh|urg) jump bad_tcp_flags
        tcp flags & (syn|fin) == (syn|fin) jump bad_tcp_flags
        tcp flags & (syn|rst) == (syn|rst) jump bad_tcp_flags
        tcp flags & (fin|rst) == (fin|rst) jump bad_tcp_flags
        tcp flags & (fin|ack) == fin jump bad_tcp_flags
        tcp flags & (psh|ack) == psh jump bad_tcp_flags
        tcp flags & (ack|urg) == urg jump bad_tcp_flags

        ip protocol icmp icmp type echo-request meter icmp4 { ip saddr timeout $ICMP_TIMEOUT limit rate $ICMP_RATE/second burst $ICMP_BURST packets } accept
        ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        ip protocol icmp drop
        icmpv6 type echo-request meter icmp6 { ip6 saddr timeout $ICMP_TIMEOUT limit rate $ICMP_RATE/second burst $ICMP_BURST packets } accept
        icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, packet-too-big, time-exceeded, parameter-problem, destination-unreachable, mld-listener-query, mld-listener-report, mld-listener-done } accept
        meta l4proto ipv6-icmp drop

        tcp dport $SSH_PORT tcp flags & (fin|syn|rst|ack) == syn ct state new meter ssh4 { ip saddr timeout $SSH_TIMEOUT limit rate $SSH_RATE/minute burst $SSH_BURST packets } accept
        tcp dport $SSH_PORT tcp flags & (fin|syn|rst|ack) == syn ct state new meter ssh6 { ip6 saddr timeout $SSH_TIMEOUT limit rate $SSH_RATE/minute burst $SSH_BURST packets } accept
        tcp dport $SSH_PORT ct state new limit rate 5/second log prefix "[hysteria-vps ssh-flood] " level warn
        tcp dport $SSH_PORT ct state new drop

        tcp dport { $tcp_ports } tcp flags & (fin|syn|rst|ack) == syn ct state new meter svc4 { ip saddr timeout $SVC_TIMEOUT limit rate $SYN_RATE/second burst $SYN_BURST packets } accept
        tcp dport { $tcp_ports } tcp flags & (fin|syn|rst|ack) == syn ct state new meter svc6 { ip6 saddr timeout $SVC_TIMEOUT limit rate $SYN_RATE/second burst $SYN_BURST packets } accept
        tcp dport { $tcp_ports } ct state new limit rate 5/second log prefix "[hysteria-vps synflood] " level info
        tcp dport { $tcp_ports } ct state new drop

        udp dport { $udp_ports } ct state new meter udp4 { ip saddr timeout $SVC_TIMEOUT limit rate $UDP_RATE/second burst $UDP_BURST packets } accept
        udp dport { $udp_ports } ct state new meter udp6 { ip6 saddr timeout $SVC_TIMEOUT limit rate $UDP_RATE/second burst $UDP_BURST packets } accept
        udp dport { $udp_ports } ct state new limit rate 5/second log prefix "[hysteria-vps udp-flood] " level info
        udp dport { $udp_ports } ct state new drop
        udp dport { $udp_ports } accept

        counter drop
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=hysteria-vps-setup nftables firewall
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft add table inet $TABLE_NAME
ExecStart=/usr/sbin/nft -f $NFT_FILE

[Install]
WantedBy=multi-user.target
EOF
}

delete_table_if_present() {
  nft delete table inet "$TABLE_NAME" >/dev/null 2>&1 || true
}

safety_units_stopped() {
  local unit state
  for unit in "$SAFETY_UNIT.timer" "$SAFETY_UNIT.service"; do
    state="$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null)" || return 1
    case "$state" in
      inactive|failed) ;;
      *) return 1 ;;
    esac
  done
}

disarm_safety() {
  command -v systemctl >/dev/null 2>&1 || {
    warn "systemctl is required to disarm the firewall safety timer"
    return 1
  }
  systemctl stop "$SAFETY_UNIT.timer" "$SAFETY_UNIT.service" >/dev/null 2>&1 || true
  if ! safety_units_stopped; then
    warn "Could not verify that firewall rollback safety is stopped"
    return 1
  fi
  systemctl reset-failed "$SAFETY_UNIT.timer" "$SAFETY_UNIT.service" >/dev/null 2>&1 || true
}

arm_safety() {
  local -a rollback_command

  [[ "$DRY_RUN" == "1" ]] && return 0
  command -v systemd-run >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 || {
    warn "systemd-run and systemctl are required for firewall rollback safety"
    return 1
  }
  disarm_safety || return 1

  info "Arming firewall safety timer for ${SAFETY_DELAY}s"
  if [[ -n "${ROLLBACK_FILE:-}" ]]; then
    rollback_command=(/bin/sh -c '/usr/sbin/nft delete table inet "$1" 2>/dev/null || true; /usr/sbin/nft -f "$2" && rm -f "$2"' _ "$TABLE_NAME" "$ROLLBACK_FILE")
  else
    rollback_command=(/usr/sbin/nft delete table inet "$TABLE_NAME")
  fi
  if ! systemd-run --quiet --collect --unit="$SAFETY_UNIT" --on-active="${SAFETY_DELAY}s" \
    "${rollback_command[@]}" >/dev/null 2>&1; then
    warn "Could not arm firewall safety timer"
    return 1
  fi

  if ! systemctl is-active --quiet "$SAFETY_UNIT.timer"; then
    warn "Firewall safety timer is not active"
    disarm_safety || true
    return 1
  fi
  ok "Safety timer armed: $SAFETY_UNIT"
}

capture_rollback() {
  local rollback_file
  rollback_file="$(mktemp "$STATE_DIR/firewall.rollback.XXXXXX.nft")"
  if nft list table inet "$TABLE_NAME" > "$rollback_file" 2>/dev/null; then
    ROLLBACK_FILE="$rollback_file"
    info "Saved current firewall rules for rollback"
  else
    rm -f "$rollback_file"
  fi
}

remove_rollback_file() {
  [[ -n "${ROLLBACK_FILE:-}" ]] || return 0
  rm -f -- "$ROLLBACK_FILE"
  ROLLBACK_FILE=""
}

firewall_config_snapshot() {
  local set_name

  nft -s -t list table inet "$TABLE_NAME" || return 1
  for set_name in whitelist_v4 whitelist_v6 scanner_blocklist_v4 manual_blocklist_v4 manual_blocklist_v6; do
    nft -s list set inet "$TABLE_NAME" "$set_name" || return 1
  done
}

restore_rollback() {
  if [[ -n "${ROLLBACK_FILE:-}" && ! -f "$ROLLBACK_FILE" ]]; then
    info "Safety timer already restored the previous firewall rules"
    return 0
  fi
  delete_table_if_present
  if [[ -n "${ROLLBACK_FILE:-}" && -f "$ROLLBACK_FILE" ]]; then
    nft -f "$ROLLBACK_FILE"
    ok "Previous firewall rules restored"
  else
    info "No previous firewall rules to restore"
  fi
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y nftables iproute2
}

new_apply_file() {
  if [[ "$DRY_RUN" == "1" ]]; then
    mktemp "${TMPDIR:-/tmp}/hysteria-vps-firewall.XXXXXX.nft"
  else
    install -d -m 0755 "$STATE_DIR"
    mktemp "$STATE_DIR/firewall.apply.XXXXXX.nft"
  fi
}

validation_table_name() {
  printf 'hvs_fw_check_%s\n' "$RANDOM"
}

apply_firewall() {
  local answer applied_config apply_file confirmation_timeout firewall_confirmed validation_table

  require_root
  validate_settings
  collect_whitelist
  collect_blocklist
  collect_manual_blocklist
  if [[ "$DRY_RUN" == "1" ]]; then
    command -v nft >/dev/null 2>&1 || die "nft command is required for dry-run validation"
  else
    install_dependencies
  fi
  apply_file="$(new_apply_file)"
  APPLY_FILE="$apply_file"

  validation_table="$(validation_table_name)"
  generate_ruleset "$apply_file" "$validation_table"

  nft -c -f "$apply_file"
  ok "nftables rules validated: $apply_file"

  generate_ruleset "$apply_file" "$TABLE_NAME" 1

  if [[ "$DRY_RUN" == "1" ]]; then
    rm -f "$apply_file"
    APPLY_FILE=""
    ok "Dry run complete; firewall was not applied"
    return 0
  fi

  capture_rollback
  arm_safety
  nft add table inet "$TABLE_NAME"
  if ! nft -f "$apply_file"; then
    warn "Could not apply new firewall rules; restoring the previous rules"
    restore_rollback
    disarm_safety
    remove_rollback_file
    return 1
  fi
  ok "Firewall applied with table inet $TABLE_NAME"
  applied_config="$(firewall_config_snapshot)" \
    || die "Could not record the applied firewall configuration"

  firewall_confirmed=0
  if [[ "$ASSUME_FIREWALL_OK" == "1" ]]; then
    answer=y
  elif [[ -t 0 ]]; then
    confirmation_timeout=$((10#$SAFETY_DELAY - SAFETY_CONFIRM_MARGIN))
    echo "Open a new SSH session now and verify access before confirming."
    if ! read -r -t "$confirmation_timeout" -p "Is SSH access still working? [y/N]: " answer; then
      answer=""
      warn "Firewall confirmation timed out"
    fi
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      warn "Safety timer remains armed and will restore the previous firewall after ${SAFETY_DELAY}s"
    fi
  else
    answer=""
    warn "Non-interactive mode without HVS_ASSUME_FIREWALL_OK=1: safety timer remains armed for ${SAFETY_DELAY}s"
  fi

  if [[ "$answer" =~ ^[Yy]$ ]]; then
    disarm_safety
    if [[ "$(firewall_config_snapshot 2>/dev/null || true)" == "$applied_config" ]]; then
      firewall_confirmed=1
    else
      warn "Firewall rules changed or were rolled back before confirmation"
    fi
  fi

  if [[ "$firewall_confirmed" == "1" ]]; then
    install -d -m 0755 "$CONF_DIR"
    install -m 0644 "$apply_file" "$NFT_FILE"
    write_service
    systemctl daemon-reload
    systemctl enable --now hysteria-vps-firewall.service
    rm -f "$apply_file"
    APPLY_FILE=""
    cat > "$STATE_DIR/firewall.state" <<EOF
installed_at=$(date -Is)
ssh_port=$SSH_PORT
tcp_ports=$TCP_PORTS
udp_ports=$UDP_PORTS
blocklist_file=$BLOCKLIST_FILE
blocklist_entries=${#BL4[@]}
scanner_log_global_rate=$SCANNER_LOG_GLOBAL_RATE
scanner_log_global_burst=$SCANNER_LOG_GLOBAL_BURST
scanner_log_timeout=$SCANNER_LOG_TIMEOUT
scanner_log_set_size=$SCANNER_LOG_SET_SIZE
nft_file=$NFT_FILE
service=hysteria-vps-firewall.service
EOF
    disarm_safety
    remove_rollback_file
    ok "Firewall persistence enabled and safety timer disarmed"
  else
    rm -f "$apply_file"
    APPLY_FILE=""
    if [[ -t 0 ]]; then
      disarm_safety
      restore_rollback
      remove_rollback_file
      warn "Firewall was not confirmed; previous firewall rules were restored"
    else
      warn "Firewall was not confirmed; safety timer will restore the previous rules after ${SAFETY_DELAY}s"
    fi
    return 1
  fi

  return 0
}

delete_firewall() {
  require_root
  disarm_safety
  systemctl disable --now hysteria-vps-firewall.service >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$NFT_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  delete_table_if_present
  rm -f "$STATE_DIR/firewall.state"
  rm -f "$STATE_DIR"/firewall.rollback.*.nft
  ok "Firewall removed"
}

status_firewall() {
  if nft list table inet "$TABLE_NAME" >/dev/null 2>&1; then
    nft list table inet "$TABLE_NAME"
  else
    warn "Firewall table inet $TABLE_NAME is not active"
    return 1
  fi
}

manual_blocklist() {
  local action="$1" ip="${2:-}" item found=0 candidate
  require_root
  collect_manual_blocklist
  if [[ "$action" == list ]]; then
    if ((${#MANUAL4[@]} + ${#MANUAL6[@]} == 0)); then
      info "Manual blocklist is empty"
    else
      printf '%s\n' "${MANUAL4[@]}" "${MANUAL6[@]}"
    fi
    return 0
  fi

  is_manual_ip "$ip" || die "Expected one IPv4 or IPv6 address (no CIDR): $ip"
  [[ "$DRY_RUN" == 0 ]] || die "Manual blocklist changes do not support dry-run"
  for item in "${MANUAL4[@]}" "${MANUAL6[@]}"; do
    [[ "${item,,}" == "${ip,,}" ]] && found=1
  done
  if [[ "$action" == add && "$found" == 1 ]]; then
    info "Already manually blocked: $ip"
    return 0
  fi
  if [[ "$action" == remove && "$found" == 0 ]]; then
    info "Not manually blocked: $ip"
    return 0
  fi
  nft list table inet "$TABLE_NAME" >/dev/null 2>&1 \
    || die "Firewall is not active; run firewall.sh apply first"
  [[ -f "$NFT_FILE" ]] && systemctl is-enabled --quiet hysteria-vps-firewall.service \
    || die "Firewall persistence is not enabled; run firewall.sh apply first"

  install -d -m 0755 "$CONF_DIR"
  candidate="$(mktemp "$CONF_DIR/manual-blocklist.XXXXXX")"
  PENDING_MANUAL_FILE="$candidate"
  for item in "${MANUAL4[@]}" "${MANUAL6[@]}"; do
    if [[ "$action" == remove && "${item,,}" == "${ip,,}" ]]; then continue; fi
    printf '%s\n' "$item" >> "$candidate"
  done
  if [[ "$action" == add ]]; then printf '%s\n' "$ip" >> "$candidate"; fi

  MANUAL_BLOCKLIST_FILE="$candidate"
  apply_firewall
  mv -f -- "$candidate" "$CONF_DIR/manual-blocklist.txt"
  PENDING_MANUAL_FILE=""
  ok "Manual blocklist updated: $ip"
}

scanners_hits() {
  local statuses
  require_root
  command -v nft >/dev/null 2>&1 || die "nft command is required to inspect scanner activity logging"
  command -v journalctl >/dev/null 2>&1 || die "journalctl is required to show scanner activity"
  command -v awk >/dev/null 2>&1 || die "awk is required to summarize scanner activity"
  if ! nft list table inet "$TABLE_NAME" 2>/dev/null | grep -F "$SCANNER_LOG_TAG" >/dev/null; then
    die "Scanner activity logging is not active; run firewall.sh apply first"
  fi

  if journalctl -k -b --no-pager -o short-iso 2>/dev/null | awk -v tag="$SCANNER_LOG_TAG" '
    index($0, tag) {
      found=1
      raw_timestamp=$1
      sub(/T/, " ", raw_timestamp)
      sub(/[+-][0-9][0-9]:?[0-9][0-9]$/, "", raw_timestamp)
      timestamp=raw_timestamp
      source=protocol=dport="-"
      for (i=1; i<=NF; i++) {
        if ($i ~ /^SRC=/) source=substr($i, 5)
        else if ($i ~ /^PROTO=/) protocol=substr($i, 7)
        else if ($i ~ /^DPT=/) dport=substr($i, 5)
      }
      key = source SUBSEP protocol SUBSEP dport
      if (!(source in source_seen)) {
        source_seen[source]=1
        sources[++source_count]=source
      }
      if (!(key in attempt)) {
        keys[++key_count]=key
      }
      attempt[key]=timestamp
    }
    END {
      if (!found) exit 1
      print "Logged scanner attempts (deduplicated, rate-limited):"
      for (source_index=1; source_index<=source_count; source_index++) {
        source=sources[source_index]
        print "\nSOURCE: " source "\n"
        printf "%-5s  %-5s  %s\n", "PROTO", "PORT", "ATTEMPT"
        printf "%-5s  %-5s  %s\n", "-----", "-----", "-------------------"
        for (key_index=1; key_index<=key_count; key_index++) {
          key=keys[key_index]
          split(key, fields, SUBSEP)
          if (fields[1] == source) {
            printf "%-5s  %-5s  %s\n", fields[2], fields[3], attempt[key]
          }
        }
      }
    }
  '; then
    return 0
  fi
  statuses=("${PIPESTATUS[@]}")
  ((statuses[0] == 0)) || die "Could not read the kernel journal"
  if ((statuses[1] == 1)); then
    info "No scanners-activity events logged since the current boot"
  else
    die "Could not filter scanner activity from the kernel journal"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-apply}" in
    apply) apply_firewall ;;
    delete) delete_firewall ;;
    status) status_firewall ;;
    scanners-hits) scanners_hits ;;
    block) [[ $# -eq 2 ]] || die "Usage: $0 block IP"; manual_blocklist add "$2" ;;
    unblock) [[ $# -eq 2 ]] || die "Usage: $0 unblock IP"; manual_blocklist remove "$2" ;;
    blocklist) [[ $# -eq 1 ]] || die "Usage: $0 blocklist"; manual_blocklist list ;;
    *) die "Usage: $0 [apply|delete|status|scanners-hits|block IP|unblock IP|blocklist]" ;;
  esac
fi
