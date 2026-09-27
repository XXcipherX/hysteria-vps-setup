#!/usr/bin/env bash

set -euo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "firewall-netns.sh must run as root" >&2
  exit 1
}

for command in ip nft python3 timeout; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required" >&2
    exit 1
  }
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
SERVER_NS="hvs-fw-server-$$"
CLIENT_NS="hvs-fw-client-$$"
SERVER_LINK="hvss$$"
CLIENT_LINK="hvsc$$"
PIDS=()

cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  done
  ip netns del "$CLIENT_NS" >/dev/null 2>&1 || true
  ip netns del "$SERVER_NS" >/dev/null 2>&1 || true
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FIREWALL NETNS FAILED: $*" >&2
  exit 1
}

tcp_connect() {
  local address="$1" port="$2"
  timeout 1 ip netns exec "$CLIENT_NS" bash -c \
    'exec 3<>/dev/tcp/"$1"/"$2"' _ "$address" "$port" 2>/dev/null
}

tcp6_connect() {
  local address="$1" port="$2"
  timeout 1 ip netns exec "$CLIENT_NS" python3 -c \
    'import socket,sys; s=socket.socket(socket.AF_INET6); s.settimeout(1); s.connect((sys.argv[1], int(sys.argv[2])))' \
    "$address" "$port" 2>/dev/null
}

wait_for_listener() {
  local attempt
  for ((attempt = 0; attempt < 20; attempt++)); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

mkdir -p "$TMP_DIR/conf" "$TMP_DIR/state"
printf '%s\n' '198.51.100.2/32' > "$TMP_DIR/blocklist.txt"

HVS_CONF_DIR="$TMP_DIR/conf"
HVS_STATE_DIR="$TMP_DIR/state"
HVS_BLOCKLIST_FILE="$TMP_DIR/blocklist.txt"
HVS_TCP_PORTS="80,443"
HVS_UDP_PORTS="443"
HVS_UDP_RATE=1
HVS_UDP_BURST=2
HVS_DRY_RUN=1
SSH_PORT=2222
unset SSH_CONNECTION SSH_CLIENT
source "$REPO_ROOT/scripts/firewall.sh"
trap cleanup EXIT

validate_settings
collect_whitelist
collect_blocklist
collect_manual_blocklist
generate_ruleset "$TMP_DIR/firewall.nft" "$TABLE_NAME"

ip netns add "$SERVER_NS"
ip netns add "$CLIENT_NS"
ip link add "$SERVER_LINK" type veth peer name "$CLIENT_LINK"
ip link set "$SERVER_LINK" netns "$SERVER_NS"
ip link set "$CLIENT_LINK" netns "$CLIENT_NS"

ip -n "$SERVER_NS" link set lo up
ip -n "$CLIENT_NS" link set lo up
ip -n "$SERVER_NS" link set "$SERVER_LINK" up
ip -n "$CLIENT_NS" link set "$CLIENT_LINK" up
ip -n "$SERVER_NS" address add 192.0.2.1/24 dev "$SERVER_LINK"
ip -n "$CLIENT_NS" address add 192.0.2.2/24 dev "$CLIENT_LINK"
ip -n "$SERVER_NS" address add 198.51.100.1/24 dev "$SERVER_LINK"
ip -n "$CLIENT_NS" address add 198.51.100.2/24 dev "$CLIENT_LINK"
ip -n "$SERVER_NS" address add 2001:db8::1/64 dev "$SERVER_LINK" nodad
ip -n "$CLIENT_NS" address add 2001:db8::2/64 dev "$CLIENT_LINK" nodad

ip netns exec "$SERVER_NS" python3 -m http.server 80 --bind 0.0.0.0 >"$TMP_DIR/tcp-80.log" 2>&1 &
PIDS+=("$!")
ip netns exec "$SERVER_NS" python3 -m http.server 8080 --bind 0.0.0.0 >"$TMP_DIR/tcp-8080.log" 2>&1 &
PIDS+=("$!")
ip netns exec "$SERVER_NS" python3 -m http.server 443 --bind 2001:db8::1 >"$TMP_DIR/tcp6-443.log" 2>&1 &
PIDS+=("$!")

wait_for_listener tcp_connect 192.0.2.1 80 || fail "TCP test listener did not start"
wait_for_listener tcp_connect 192.0.2.1 8080 || fail "closed-port test listener did not start"
wait_for_listener tcp6_connect 2001:db8::1 443 || fail "IPv6 test listener did not start"

ip netns exec "$SERVER_NS" nft -c -f "$TMP_DIR/firewall.nft"
ip netns exec "$SERVER_NS" nft -f "$TMP_DIR/firewall.nft"

tcp_connect 192.0.2.1 80 || fail "allowed TCP service is unreachable"
ip -n "$SERVER_NS" neighbour flush dev "$SERVER_LINK" >/dev/null
ip -n "$CLIENT_NS" neighbour flush dev "$CLIENT_LINK" >/dev/null
tcp6_connect 2001:db8::1 443 || fail "allowed IPv6 TCP service is unreachable"
if tcp_connect 192.0.2.1 8080; then
  fail "unlisted TCP port is reachable"
fi

UDP_RESULT="$TMP_DIR/udp-count"
ip netns exec "$SERVER_NS" python3 - "$UDP_RESULT" <<'PY' &
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", 443))
sock.settimeout(2)
count = 0
try:
    while True:
        sock.recvfrom(2048)
        count += 1
except socket.timeout:
    pass
with open(sys.argv[1], "w", encoding="ascii") as output:
    output.write(str(count))
PY
UDP_PID="$!"
PIDS+=("$UDP_PID")
sleep 0.2
ip netns exec "$CLIENT_NS" python3 - <<'PY'
import socket

for offset in range(10):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("192.0.2.2", 40000 + offset))
    sock.sendto(b"test", ("192.0.2.1", 443))
    sock.close()
PY
wait "$UDP_PID"
UDP_COUNT="$(<"$UDP_RESULT")"
[[ "$UDP_COUNT" =~ ^[0-9]+$ && "$UDP_COUNT" -ge 1 && "$UDP_COUNT" -lt 10 ]] \
  || fail "UDP new-flow limiter received $UDP_COUNT of 10 packets"

printf '%s\n' '192.0.2.2' '2001:db8::2' > "$MANUAL_BLOCKLIST_FILE"
collect_manual_blocklist
generate_ruleset "$TMP_DIR/manual.nft" "$TABLE_NAME" 1
ip netns exec "$SERVER_NS" nft -c -f "$TMP_DIR/manual.nft"
ip netns exec "$SERVER_NS" nft -f "$TMP_DIR/manual.nft"
if tcp_connect 192.0.2.1 80 || tcp6_connect 2001:db8::1 443; then
  fail "manually blocked IP reached an allowed TCP service"
fi
ip netns exec "$SERVER_NS" nft list chain inet "$TABLE_NAME" prerouting \
  | grep -Eq '@manual_blocklist_v4 counter packets [1-9][0-9]* bytes' \
  || fail "manual IPv4 drop counter did not increase"
ip netns exec "$SERVER_NS" nft list chain inet "$TABLE_NAME" prerouting \
  | grep -Eq '@manual_blocklist_v6 counter packets [1-9][0-9]* bytes' \
  || fail "manual IPv6 drop counter did not increase"

ip -n "$CLIENT_NS" address del 192.0.2.2/24 dev "$CLIENT_LINK"
if tcp_connect 198.51.100.1 80; then
  fail "scanner blocklist source reached an allowed TCP service"
fi
ip netns exec "$SERVER_NS" nft list chain inet "$TABLE_NAME" prerouting \
  | grep -Eq '@scanner_blocklist_v4 counter packets [1-9][0-9]* bytes' \
  || fail "scanner blocklist drop counter did not increase"

echo "FIREWALL NETNS: OK"
