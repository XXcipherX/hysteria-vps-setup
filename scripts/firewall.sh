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

SSH_PORT="${SSH_PORT:-$(default_ssh_port)}"
TCP_PORTS="${HVS_TCP_PORTS:-80,443}"
UDP_PORTS="${HVS_UDP_PORTS:-443}"
WHITELIST="${HVS_WHITELIST:-}"
SYN_RATE="${HVS_SYN_RATE:-200}"
SYN_BURST="${HVS_SYN_BURST:-400}"
SSH_RATE="${HVS_SSH_RATE:-6}"
SSH_BURST="${HVS_SSH_BURST:-5}"
ICMP_RATE="${HVS_ICMP_RATE:-10}"
ICMP_BURST="${HVS_ICMP_BURST:-20}"
ICMP_TIMEOUT="${HVS_ICMP_TIMEOUT:-1h}"
SSH_TIMEOUT="${HVS_SSH_TIMEOUT:-24h}"
SVC_TIMEOUT="${HVS_SVC_TIMEOUT:-24h}"
SCANNER_LOG_RATE="${HVS_SCANNER_LOG_RATE:-3}"
SCANNER_LOG_BURST="${HVS_SCANNER_LOG_BURST:-5}"
SCANNER_LOG_GLOBAL_RATE="${HVS_SCANNER_LOG_GLOBAL_RATE:-30}"
SCANNER_LOG_GLOBAL_BURST="${HVS_SCANNER_LOG_GLOBAL_BURST:-50}"
SCANNER_LOG_TIMEOUT="${HVS_SCANNER_LOG_TIMEOUT:-1h}"
SAFETY_DELAY="${HVS_SAFETY_DELAY:-300}"
DRY_RUN="${HVS_DRY_RUN:-0}"
ASSUME_FIREWALL_OK="${HVS_ASSUME_FIREWALL_OK:-0}"
APPLY_FILE=""
ROLLBACK_FILE=""

info() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup_apply_file() {
  [[ -n "${APPLY_FILE:-}" ]] || return 0
  rm -f -- "$APPLY_FILE"
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
  for value_name in SYN_RATE SYN_BURST SSH_RATE SSH_BURST ICMP_RATE ICMP_BURST SCANNER_LOG_RATE SCANNER_LOG_BURST SCANNER_LOG_GLOBAL_RATE SCANNER_LOG_GLOBAL_BURST SAFETY_DELAY; do
    is_positive_uint "${!value_name}" || die "$value_name must be a positive integer"
  done
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
    WL6+=("$item")
  elif [[ "$item" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
    WL4+=("$item")
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
    [[ "$line" != *[[:space:]]* ]] \
      || die "Blocklist entries must contain one IPv4/CIDR per line: $line"
    append_blocklist_item "$line"
  done < "$BLOCKLIST_FILE"

  ((${#BL4[@]} > 0)) \
    || die "Blocklist file contains no IPv4/CIDR entries: $BLOCKLIST_FILE"
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
  local ruleset_dir ruleset_file="${1:-$NFT_FILE}" table_name="${2:-$TABLE_NAME}"
  local tcp_ports udp_ports wl4 wl6 bl4
  tcp_ports="$(format_ports_for_nft "$TCP_PORTS")"
  udp_ports="$(format_ports_for_nft "$UDP_PORTS")"
  wl4="$(join_by_comma "${WL4[@]}")"
  wl6="$(join_by_comma "${WL6[@]}")"
  bl4="$(join_by_comma "${BL4[@]}")"

  ruleset_dir="$(dirname -- "$ruleset_file")"
  ensure_ruleset_dir "$ruleset_dir"
  cat > "$ruleset_file" <<EOF
#!/usr/sbin/nft -f

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

    chain bad_tcp_flags {
        limit rate 5/second log prefix "[hysteria-vps badflags] " level info
        counter drop
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept
        ip saddr @scanner_blocklist_v4 meter scanner_log4 { ip saddr timeout $SCANNER_LOG_TIMEOUT limit rate $SCANNER_LOG_RATE/minute burst $SCANNER_LOG_BURST packets } limit rate $SCANNER_LOG_GLOBAL_RATE/minute burst $SCANNER_LOG_GLOBAL_BURST packets log prefix "$SCANNER_LOG_TAG " level info
        ip saddr @scanner_blocklist_v4 counter drop

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

        tcp dport $SSH_PORT ct state new meter ssh4 { ip saddr timeout $SSH_TIMEOUT limit rate $SSH_RATE/minute burst $SSH_BURST packets } accept
        tcp dport $SSH_PORT ct state new meter ssh6 { ip6 saddr timeout $SSH_TIMEOUT limit rate $SSH_RATE/minute burst $SSH_BURST packets } accept
        tcp dport $SSH_PORT ct state new limit rate 5/second log prefix "[hysteria-vps ssh-flood] " level warn
        tcp dport $SSH_PORT ct state new drop

        tcp dport { $tcp_ports } ct state new meter svc4 { ip saddr timeout $SVC_TIMEOUT limit rate $SYN_RATE/second burst $SYN_BURST packets } accept
        tcp dport { $tcp_ports } ct state new meter svc6 { ip6 saddr timeout $SVC_TIMEOUT limit rate $SYN_RATE/second burst $SYN_BURST packets } accept
        tcp dport { $tcp_ports } ct state new limit rate 5/second log prefix "[hysteria-vps synflood] " level info
        tcp dport { $tcp_ports } ct state new drop

        udp dport { $udp_ports } accept

        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
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
ExecStartPre=-/usr/sbin/nft delete table inet $TABLE_NAME
ExecStart=/usr/sbin/nft -f $NFT_FILE
ExecStop=-/usr/sbin/nft delete table inet $TABLE_NAME

[Install]
WantedBy=multi-user.target
EOF
}

delete_table_if_present() {
  nft delete table inet "$TABLE_NAME" >/dev/null 2>&1 || true
}

arm_safety() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  info "Arming firewall safety timer for ${SAFETY_DELAY}s"
  if command -v systemd-run >/dev/null 2>&1; then
    systemctl stop "$SAFETY_UNIT.timer" "$SAFETY_UNIT.service" >/dev/null 2>&1 || true
    if [[ -n "${ROLLBACK_FILE:-}" ]]; then
      # shellcheck disable=SC2016 # Positional parameters expand inside the child shell.
      if systemd-run --quiet --unit="$SAFETY_UNIT" --on-active="${SAFETY_DELAY}s" \
        /bin/sh -c '/usr/sbin/nft delete table inet "$1" 2>/dev/null || true; /usr/sbin/nft -f "$2" && rm -f "$2"' \
        _ "$TABLE_NAME" "$ROLLBACK_FILE" >/dev/null 2>&1; then
        ok "Safety timer armed: $SAFETY_UNIT"
        return 0
      fi
    elif systemd-run --quiet --unit="$SAFETY_UNIT" --on-active="${SAFETY_DELAY}s" \
      /usr/sbin/nft delete table inet "$TABLE_NAME" >/dev/null 2>&1; then
      ok "Safety timer armed: $SAFETY_UNIT"
      return 0
    fi
  fi

  local pid_file="$STATE_DIR/firewall-safety.pid" log_file="$STATE_DIR/firewall-safety.log"
  if [[ -f "$pid_file" && ! -L "$pid_file" ]]; then
    kill "$(cat "$pid_file")" >/dev/null 2>&1 || true
  fi
  if [[ -n "${ROLLBACK_FILE:-}" ]]; then
    # shellcheck disable=SC2016 # Positional parameters expand inside the child shell.
    nohup sh -c 'sleep "$1"; /usr/sbin/nft delete table inet "$2" 2>/dev/null || true; /usr/sbin/nft -f "$3" && rm -f "$3"; rm -f "$4"' \
      _ "$SAFETY_DELAY" "$TABLE_NAME" "$ROLLBACK_FILE" "$pid_file" >"$log_file" 2>&1 &
  else
    # shellcheck disable=SC2016 # Positional parameters expand inside the child shell.
    nohup sh -c 'sleep "$1"; /usr/sbin/nft delete table inet "$2" 2>/dev/null; rm -f "$3"' \
      _ "$SAFETY_DELAY" "$TABLE_NAME" "$pid_file" >"$log_file" 2>&1 &
  fi
  echo $! > "$pid_file"
  ok "Safety fallback armed: pid $(cat "$pid_file")"
}

disarm_safety() {
  systemctl stop "$SAFETY_UNIT.timer" "$SAFETY_UNIT.service" >/dev/null 2>&1 || true
  local pid_file="$STATE_DIR/firewall-safety.pid"
  if [[ -f "$pid_file" && ! -L "$pid_file" ]]; then
    kill "$(cat "$pid_file")" >/dev/null 2>&1 || true
    rm -f "$pid_file"
  fi
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

restore_rollback() {
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
  local answer apply_file firewall_confirmed validation_table

  require_root
  validate_settings
  collect_whitelist
  collect_blocklist
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

  generate_ruleset "$apply_file"
  if [[ "$DRY_RUN" == "1" ]]; then
    rm -f "$apply_file"
    APPLY_FILE=""
    ok "Dry run complete; firewall was not applied"
    return 0
  fi

  capture_rollback
  arm_safety
  delete_table_if_present
  if ! nft -f "$apply_file"; then
    warn "Could not apply new firewall rules; restoring the previous rules"
    restore_rollback
    disarm_safety
    remove_rollback_file
    return 1
  fi
  ok "Firewall applied with table inet $TABLE_NAME"

  firewall_confirmed=0
  if [[ "$ASSUME_FIREWALL_OK" == "1" ]]; then
    firewall_confirmed=1
  elif [[ -t 0 ]]; then
    echo "Open a new SSH session now and verify access before confirming."
    read -r -p "Is SSH access still working? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      firewall_confirmed=1
    else
      warn "Safety timer is still armed and will restore the previous firewall after ${SAFETY_DELAY}s"
    fi
  else
    warn "Non-interactive mode without HVS_ASSUME_FIREWALL_OK=1: safety timer remains armed for ${SAFETY_DELAY}s"
  fi

  if [[ "$firewall_confirmed" == "1" ]]; then
    write_service
    systemctl daemon-reload
    systemctl enable hysteria-vps-firewall.service
    install -d -m 0755 "$CONF_DIR"
    install -m 0644 "$apply_file" "$NFT_FILE"
    rm -f "$apply_file"
    APPLY_FILE=""
    cat > "$STATE_DIR/firewall.state" <<EOF
installed_at=$(date -Is)
ssh_port=$SSH_PORT
tcp_ports=$TCP_PORTS
udp_ports=$UDP_PORTS
blocklist_file=$BLOCKLIST_FILE
blocklist_entries=${#BL4[@]}
scanner_log_rate=$SCANNER_LOG_RATE
scanner_log_burst=$SCANNER_LOG_BURST
scanner_log_global_rate=$SCANNER_LOG_GLOBAL_RATE
scanner_log_global_burst=$SCANNER_LOG_GLOBAL_BURST
scanner_log_timeout=$SCANNER_LOG_TIMEOUT
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
      restore_rollback
      disarm_safety
      remove_rollback_file
      warn "Firewall was not confirmed; previous firewall rules were restored"
    else
      warn "Firewall was not confirmed; safety timer will restore the previous rules after ${SAFETY_DELAY}s"
    fi
    return 1
  fi
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

scanners_hits() {
  local statuses
  require_root
  command -v nft >/dev/null 2>&1 \
    || die "nft command is required to inspect scanner activity logging"
  command -v journalctl >/dev/null 2>&1 \
    || die "journalctl is required to show scanner activity"
  command -v awk >/dev/null 2>&1 \
    || die "awk is required to summarize scanner activity"
  if ! nft list chain inet "$TABLE_NAME" input 2>/dev/null \
    | grep -F "$SCANNER_LOG_TAG" >/dev/null; then
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
      if (!(key in first_seen)) {
        first_seen[key]=timestamp
        keys[++key_count]=key
      }
      last_seen[key]=timestamp
    }
    END {
      if (!found) exit 1
      print "Logged scanner attempts (rate-limited):"
      for (source_index=1; source_index<=source_count; source_index++) {
        source=sources[source_index]
        print "\nSOURCE: " source "\n"
        printf "%-5s  %-5s  %-19s  %s\n", "PROTO", "PORT", "FIRST ATTEMPT", "LAST ATTEMPT"
        printf "%-5s  %-5s  %-19s  %s\n", "-----", "-----", "-------------------", "-------------------"
        for (key_index=1; key_index<=key_count; key_index++) {
          key=keys[key_index]
          split(key, fields, SUBSEP)
          if (fields[1] == source) {
            printf "%-5s  %-5s  %-19s  %s\n", fields[2], fields[3], first_seen[key], last_seen[key]
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

case "${1:-apply}" in
  apply) apply_firewall ;;
  delete) delete_firewall ;;
  status) status_firewall ;;
  scanners-hits) scanners_hits ;;
  *) die "Usage: $0 [apply|delete|status|scanners-hits]" ;;
esac
