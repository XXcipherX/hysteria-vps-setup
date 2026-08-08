#!/usr/bin/env bash

# shellcheck disable=SC2016 # Assertions intentionally match literal shell variables.
set -euo pipefail

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
export HYSTERIA_EMAIL="admin@example.com"
export HYSTERIA_PASSWORD="safe_password-123"
export HYSTERIA_IMAGE="tobyxdd/hysteria:v2"

envsubst '${HYSTERIA_DOMAIN} ${HYSTERIA_EMAIL} ${HYSTERIA_PASSWORD}' \
  < templates_for_script/hysteria > "$TMP_DIR/config.yaml"
envsubst '${HYSTERIA_IMAGE}' \
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
assert hysteria["acme"]["type"] == "http"
assert hysteria["acme"]["domains"] == ["example.com"]
assert hysteria["acme"]["dir"] == "/var/lib/hysteria/acme"
assert hysteria["auth"] == {
    "type": "password",
    "password": "safe_password-123",
}
assert "obfs" not in hysteria
assert set(hysteria["masquerade"]) == {"listenHTTPS"}
assert hysteria["masquerade"]["listenHTTPS"] == ":443"

services = compose["services"]
assert set(services) == {"hysteria"}
assert services["hysteria"]["image"] == "tobyxdd/hysteria:v2"
assert services["hysteria"]["network_mode"] == "host"

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
grep -Fq 'UDP_PORTS="${HVS_UDP_PORTS:-443}"' scripts/firewall.sh
grep -Fq 'Saved current firewall rules for rollback' scripts/firewall.sh
grep -Fq 'Safety timer armed' scripts/firewall.sh
if grep -Fq 'chain forward' scripts/firewall.sh; then
  echo "Firewall must not install a forwarding policy" >&2
  exit 1
fi
if grep -Fq 'iptables -F' scripts/firewall.sh; then
  echo "Firewall must not flush iptables" >&2
  exit 1
fi

grep -Fq 'UDP_BUFFER_BYTES="${HVS_UDP_BUFFER_BYTES:-16777216}"' scripts/optimize.sh
grep -Fq 'net.core.rmem_max = $UDP_BUFFER_BYTES' scripts/optimize.sh
grep -Fq 'net.core.wmem_max = $UDP_BUFFER_BYTES' scripts/optimize.sh
if grep -Fq 'tcp_congestion_control' scripts/optimize.sh; then
  echo "UDP optimizer must not tune kernel TCP congestion control" >&2
  exit 1
fi

grep -Fq '443/udp is publicly listening for Hysteria 2' scripts/diagnose.sh
grep -Fq '443/tcp is publicly listening for HTTPS masquerade' scripts/diagnose.sh

grep -Fq 'HYSTERIA_IMAGE="tobyxdd/hysteria:v2"' vps-setup.sh
grep -Fq "envsubst '\${HYSTERIA_DOMAIN} \${HYSTERIA_EMAIL} \${HYSTERIA_PASSWORD}'" vps-setup.sh
grep -Fq "envsubst '\${HYSTERIA_DOMAIN} \${HYSTERIA_PASSWORD}'" vps-setup.sh
grep -Fq 'share -c /etc/hysteria/client.yaml' vps-setup.sh
grep -Fq 'docker exec hysteria hysteria version' vps-setup.sh
grep -Fq 'docker exec hysteria hysteria version' scripts/diagnose.sh
if grep -R -Fq 'docker exec hysteria version' vps-setup.sh scripts/diagnose.sh; then
  echo "Invalid Hysteria version command found" >&2
  exit 1
fi
if grep -Rqi 'xray' --exclude=smoke.sh --exclude-dir=.git .; then
  echo "Xray-specific content found" >&2
  exit 1
fi

echo "SMOKE: OK"
