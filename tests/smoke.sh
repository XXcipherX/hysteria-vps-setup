#!/usr/bin/env bash

# shellcheck disable=SC2016 # Assertions intentionally match literal shell variables.
set -euo pipefail

report_failure() {
  local status="$1" line="$2" command="$3"
  printf 'SMOKE FAILED (exit %s) at line %s:\n  %s\n' "$status" "$line" "$command" >&2
  exit "$status"
}

trap 'report_failure "$?" "$LINENO" "$BASH_COMMAND"' ERR

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

cd "$REPO_ROOT"

bash -n vps-setup.sh scripts/*.sh tests/*.sh

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst is missing; skipping template render smoke"
  exit 0
fi

export HYSTERIA_DOMAIN="example.com"
export HYSTERIA_PASSWORD="safe_password-123"
export HYSTERIA_IMAGE="tobyxdd/hysteria:v2"
export HYSTERIA_CERT_DIR="/opt/mtproto-proxy/caddy/ssl/mtproto-mask/example.com"

envsubst '${HYSTERIA_PASSWORD}' < templates_for_script/hysteria > "$TMP_DIR/config.yaml"
envsubst '${HYSTERIA_IMAGE} ${HYSTERIA_CERT_DIR}' \
  < templates_for_script/compose > "$TMP_DIR/docker-compose.yml"
envsubst '${HYSTERIA_DOMAIN} ${HYSTERIA_PASSWORD}' \
  < templates_for_script/client > "$TMP_DIR/client.yaml"

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import yaml' >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"
      break
    fi
  done
fi

if [[ -n "$PYTHON_BIN" ]]; then
  "$PYTHON_BIN" - \
    "$TMP_DIR/config.yaml" \
    "$TMP_DIR/docker-compose.yml" \
    "$TMP_DIR/client.yaml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    hysteria = yaml.safe_load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    compose = yaml.safe_load(stream)
with open(sys.argv[3], encoding="utf-8") as stream:
    client = yaml.safe_load(stream)

assert hysteria["listen"] == ":443"
assert hysteria["tls"] == {
    "cert": "/etc/hysteria/tls/cert.pem",
    "key": "/etc/hysteria/tls/key.pem",
}
assert "acme" not in hysteria
assert hysteria["auth"] == {
    "type": "password",
    "password": "safe_password-123",
}
assert "obfs" not in hysteria
assert "masquerade" not in hysteria

services = compose["services"]
assert set(services) == {"hysteria"}
assert services["hysteria"]["image"] == "tobyxdd/hysteria:v2"
assert services["hysteria"]["network_mode"] == "host"
assert services["hysteria"]["volumes"][1] == {
    "type": "bind",
    "source": "/opt/mtproto-proxy/caddy/ssl/mtproto-mask/example.com",
    "target": "/etc/hysteria/tls",
    "read_only": True,
}

assert client == {
    "server": "example.com:443",
    "auth": "safe_password-123",
    "tls": {"sni": "example.com"},
}
PY
elif [[ -n "${YQ_BIN:-}" && -x "$YQ_BIN" ]]; then
  "$YQ_BIN" eval '.' "$TMP_DIR/config.yaml" >/dev/null
  "$YQ_BIN" eval '.' "$TMP_DIR/docker-compose.yml" >/dev/null
  "$YQ_BIN" eval '.' "$TMP_DIR/client.yaml" >/dev/null
elif command -v yq >/dev/null 2>&1; then
  yq eval '.' "$TMP_DIR/config.yaml" >/dev/null
  yq eval '.' "$TMP_DIR/docker-compose.yml" >/dev/null
  yq eval '.' "$TMP_DIR/client.yaml" >/dev/null
else
  echo "python with PyYAML and yq are missing; skipping YAML parse smoke"
fi

if grep -R '\${HYSTERIA_' "$TMP_DIR"; then
  echo "Unrendered Hysteria template variable found" >&2
  exit 1
fi
grep -Fq 'TABLE_NAME="hysteria_vps_filter"' scripts/firewall.sh
grep -Fq 'udp dport { $udp_ports } accept' scripts/firewall.sh
grep -Fq 'TCP_PORTS="${HVS_TCP_PORTS:-80,443}"' scripts/firewall.sh
grep -Fq 'UDP_PORTS="${HVS_UDP_PORTS:-443,56000}"' scripts/firewall.sh
grep -Fq 'Saved current firewall rules for rollback' scripts/firewall.sh
grep -Fq 'Safety timer armed' scripts/firewall.sh
grep -Fq 'systemctl enable --now hysteria-vps-firewall.service' scripts/firewall.sh
if grep -Fq 'type filter hook forward priority filter; policy drop;' scripts/firewall.sh; then
  echo "Firewall must leave forwarding to WDTT" >&2
  exit 1
fi
if grep -Fq 'iptables -F' scripts/firewall.sh; then
  echo "Firewall must not flush iptables" >&2
  exit 1
fi

grep -Fq 'UDP_BUFFER_BYTES="${HVS_UDP_BUFFER_BYTES:-16777216}"' scripts/optimize.sh
grep -Fq 'net.core.rmem_max = $UDP_BUFFER_BYTES' scripts/optimize.sh
grep -Fq 'net.core.wmem_max = $UDP_BUFFER_BYTES' scripts/optimize.sh
grep -Fq 'net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG' scripts/optimize.sh
grep -Fq 'net.core.netdev_budget = $NETDEV_BUDGET' scripts/optimize.sh
grep -Fq 'net.core.optmem_max = $OPTMEM_MAX' scripts/optimize.sh
grep -Fq 'net.ipv4.udp_rmem_min = $UDP_MIN_BYTES' scripts/optimize.sh
grep -Fq 'net.ipv4.udp_wmem_min = $UDP_MIN_BYTES' scripts/optimize.sh
grep -Fq 'verify_profile()' scripts/optimize.sh
if grep -Fq 'tcp_congestion_control' scripts/optimize.sh; then
  echo "UDP optimizer must not tune kernel TCP congestion control" >&2
  exit 1
fi

grep -Fq '443/udp is publicly listening for Hysteria 2' scripts/diagnose.sh
grep -Fq '443/tcp is publicly listening for MTProto' scripts/diagnose.sh
grep -Fq 'scanner IPv4 blocklist is active' scripts/diagnose.sh
grep -Fq 'scanner activity logging is active' scripts/diagnose.sh
grep -Fq 'hysteria-vps-firewall.service is enabled for boot' scripts/diagnose.sh
grep -Fq 'XanMod kernel is active:' scripts/diagnose.sh

[[ "$(grep -Evc '^[[:space:]]*(#|$)' lists/cyberok-skipa-v4.txt)" -eq 151 ]]
[[ "$(grep -Ev '^[[:space:]]*(#|$)' lists/cyberok-skipa-v4.txt | git hash-object --stdin)" == "4ef46a9615e575f8192bb5a10adc9237709ae3d7" ]]
grep -Fq 'BLOCKLIST_FILE="${HVS_BLOCKLIST_FILE:-$SCRIPT_DIR/../lists/cyberok-skipa-v4.txt}"' scripts/firewall.sh
grep -Fq 'collect_blocklist' scripts/firewall.sh
grep -Fq 'set scanner_blocklist_v4 {' scripts/firewall.sh
grep -Fq 'SCANNER_LOG_TAG="[scanners-activity]"' scripts/firewall.sh
grep -Fq 'ip saddr @scanner_blocklist_v4 counter drop' scripts/firewall.sh
grep -Fq 'scanners-hits) scanners_hits ;;' scripts/firewall.sh

grep -Fq 'HYSTERIA_IMAGE="tobyxdd/hysteria:v2"' vps-setup.sh
grep -Fq "envsubst '\${HYSTERIA_PASSWORD}'" vps-setup.sh
grep -Fq "envsubst '\${HYSTERIA_IMAGE} \${HYSTERIA_CERT_DIR}'" vps-setup.sh
grep -Fq "envsubst '\${HYSTERIA_DOMAIN} \${HYSTERIA_PASSWORD}'" vps-setup.sh
grep -Fq 'share -c /etc/hysteria/client.yaml' vps-setup.sh
grep -Fq 'docker exec hysteria hysteria version' vps-setup.sh
grep -Fq 'docker exec hysteria hysteria version' scripts/diagnose.sh
grep -Fq 'Apply the nftables firewall? [y/N]:' vps-setup.sh
grep -Fq '[[ ${configure_firewall_input,,} == "y" ]] || return 0' vps-setup.sh
grep -Fq 'restart_ssh_listener()' vps-setup.sh
grep -Fq 'for unit in ssh.socket sshd.socket; do' vps-setup.sh
grep -Fq 'wait_for_ssh_listener "$SSH_PORT"' vps-setup.sh
grep -Fq 'XANMOD_BRANCH="${HVS_XANMOD_BRANCH:-lts}"' scripts/xanmod.sh
grep -Fq 'XANMOD_FP="D38D7D1DA1349567ADED882D86F7D09EE734E623"' scripts/xanmod.sh
grep -Fq 'Detected container virtualization' scripts/xanmod.sh
if grep -R -Fq 'docker exec hysteria version' vps-setup.sh scripts/diagnose.sh; then
  echo "Invalid Hysteria version command found" >&2
  exit 1
fi
if grep -Rqi 'xray' --exclude=smoke.sh --exclude-dir=.git .; then
  echo "Xray-specific content found" >&2
  exit 1
fi

SCANNER_MOCK_BIN="$TMP_DIR/scanner-mock-bin"
mkdir -p "$SCANNER_MOCK_BIN"
cat > "$SCANNER_MOCK_BIN/nft" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_NFT_MODE:-active}" == "active" ]]; then
  printf '%s\n' 'ip saddr @scanner_blocklist_v4 log prefix "[scanners-activity] "'
else
  printf '%s\n' 'ip saddr @scanner_blocklist_v4 counter drop'
fi
EOF
cat > "$SCANNER_MOCK_BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_JOURNAL_MODE:-hits}" in
  hits)
    printf '%s\n' \
      '2026-08-13T04:17:22+0000 host kernel: [scanners-activity] IN=eth0 SRC=85.142.100.104 DST=203.0.113.10 LEN=60 PROTO=TCP SPT=43871 DPT=443 SYN' \
      '2026-08-13T04:17:23+00:00 host kernel: [scanners-activity] IN=eth0 SRC=85.142.100.104 DST=203.0.113.10 LEN=60 PROTO=TCP SPT=43871 DPT=443 SYN' \
      '2026-08-13T04:18:00+0000 host kernel: [scanners-activity] IN=eth0 SRC=212.192.158.168 DST=203.0.113.10 LEN=80 PROTO=UDP SPT=53000 DPT=443' \
      '2026-08-13T04:19:00+0000 host kernel: [scanners-activity] IN=eth0 SRC=85.142.100.104 DST=203.0.113.10 LEN=60 PROTO=TCP SPT=44000 DPT=80 SYN'
    ;;
  empty) exit 0 ;;
  fail) exit 2 ;;
  *) exit 3 ;;
esac
EOF
chmod +x "$SCANNER_MOCK_BIN/nft" "$SCANNER_MOCK_BIN/journalctl"

SCANNER_TEST_RUNNER=()
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    SCANNER_TEST_RUNNER=(sudo -n)
  else
    echo "passwordless sudo is unavailable; skipping scanners-hits behavior smoke"
  fi
fi

if [[ ${EUID:-$(id -u)} -eq 0 || ${#SCANNER_TEST_RUNNER[@]} -gt 0 ]]; then
  scanner_output="$(
    "${SCANNER_TEST_RUNNER[@]}" env PATH="$SCANNER_MOCK_BIN:$PATH" MOCK_JOURNAL_MODE=hits \
      bash scripts/firewall.sh scanners-hits
  )"
  [[ "${scanner_output%%$'\n'*}" == 'Logged scanner attempts (rate-limited):' ]]
  ! grep -Fq '[scanners-activity]' <<< "$scanner_output"
  [[ "$(grep -c '^SOURCE: ' <<< "$scanner_output")" -eq 2 ]]
  grep -Fxq 'SOURCE: 85.142.100.104' <<< "$scanner_output"
  grep -Fxq 'SOURCE: 212.192.158.168' <<< "$scanner_output"
  grep -Eq '^PROTO[[:space:]]+PORT[[:space:]]+FIRST ATTEMPT[[:space:]]+LAST ATTEMPT$' <<< "$scanner_output"
  grep -Eq '^TCP[[:space:]]+443[[:space:]]+2026-08-13 04:17:22[[:space:]]+2026-08-13 04:17:23$' <<< "$scanner_output"
  grep -Eq '^UDP[[:space:]]+443[[:space:]]+2026-08-13 04:18:00[[:space:]]+2026-08-13 04:18:00$' <<< "$scanner_output"
  grep -Eq '^TCP[[:space:]]+80[[:space:]]+2026-08-13 04:19:00[[:space:]]+2026-08-13 04:19:00$' <<< "$scanner_output"

  scanner_output="$(
    "${SCANNER_TEST_RUNNER[@]}" env PATH="$SCANNER_MOCK_BIN:$PATH" MOCK_JOURNAL_MODE=empty \
      bash scripts/firewall.sh scanners-hits
  )"
  grep -Fq 'No scanners-activity events logged since the current boot' <<< "$scanner_output"

  if "${SCANNER_TEST_RUNNER[@]}" env PATH="$SCANNER_MOCK_BIN:$PATH" MOCK_JOURNAL_MODE=fail \
    bash scripts/firewall.sh scanners-hits > "$TMP_DIR/scanners-hits-fail.log" 2>&1; then
    echo "scanners-hits unexpectedly accepted a journalctl failure" >&2
    exit 1
  fi
  grep -Fq 'Could not read the kernel journal' "$TMP_DIR/scanners-hits-fail.log"

  if "${SCANNER_TEST_RUNNER[@]}" env PATH="$SCANNER_MOCK_BIN:$PATH" MOCK_NFT_MODE=inactive \
    bash scripts/firewall.sh scanners-hits > "$TMP_DIR/scanners-hits-inactive.log" 2>&1; then
    echo "scanners-hits unexpectedly accepted inactive logging" >&2
    exit 1
  fi
  grep -Fq 'Scanner activity logging is not active; run firewall.sh apply first' \
    "$TMP_DIR/scanners-hits-inactive.log"
fi

echo "SMOKE: OK"
