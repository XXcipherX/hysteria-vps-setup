#!/usr/bin/env bash

set -uo pipefail

INSTALL_DIR="${HVS_INSTALL_DIR:-/opt/hysteria-vps-setup}"
STATE_DIR="${HVS_STATE_DIR:-/var/lib/hysteria-vps-setup}"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
HYSTERIA_CONFIG="$INSTALL_DIR/hysteria/config.yaml"
FIREWALL_TABLE="${HVS_FIREWALL_TABLE:-hysteria_vps_filter}"
OPTIMIZE_STATE="$STATE_DIR/optimize.state"
INSTALL_STATE="$STATE_DIR/install.env"

OK=0
WARN=0
FAIL=0
JSON=0

for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    -h|--help)
      echo "Usage: $0 [--json]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

json_escape() {
  local value="${1//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

status_line() {
  local state="$1"
  shift
  case "$state" in
    OK) OK=$((OK + 1)); [[ "$JSON" == "0" ]] && printf '  [OK]   %s\n' "$*" ;;
    WARN) WARN=$((WARN + 1)); [[ "$JSON" == "0" ]] && printf '  [WARN] %s\n' "$*" ;;
    FAIL) FAIL=$((FAIL + 1)); [[ "$JSON" == "0" ]] && printf '  [FAIL] %s\n' "$*" ;;
    INFO) [[ "$JSON" == "0" ]] && printf '  [INFO] %s\n' "$*" ;;
  esac
  return 0
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

state_value() {
  local key="$1" file="$2"
  [[ -f "$file" && ! -L "$file" ]] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$file" 2>/dev/null
}

sysctl_value() {
  sysctl -n "$1" 2>/dev/null || true
}

service_active() {
  have_cmd systemctl || return 2
  systemctl is-active --quiet "$1" 2>/dev/null
}

service_enabled() {
  have_cmd systemctl || return 2
  systemctl is-enabled --quiet "$1" 2>/dev/null
}

container_running() {
  [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

hysteria_version() {
  docker exec hysteria hysteria version 2>/dev/null |
    awk '/^Version:/ { sub(/^Version:[[:space:]]*/, ""); print; exit }' || true
}

listener_addresses() {
  local protocol="$1" port="$2"
  have_cmd ss || return 2
  if [[ "$protocol" == "tcp" ]]; then
    ss -H -ltn 2>/dev/null
  else
    ss -H -lun 2>/dev/null
  fi | awk -v port="$port" '
    {
      local_addr=$(NF-1)
      if (local_addr ~ ("(^|[.:])" port "$") || local_addr ~ ("\\]:" port "$")) {
        print local_addr
      }
    }
  '
}

port_listening() {
  local protocol="$1" port="$2"
  listener_addresses "$protocol" "$port" | grep -q .
}

port_has_non_loopback_listener() {
  local protocol="$1" port="$2" addr
  while IFS= read -r addr; do
    if [[ "$addr" =~ ^127\. || "$addr" =~ ^\[?::1\]?: || "$addr" == localhost:* ]]; then
      continue
    fi
    return 0
  done < <(listener_addresses "$protocol" "$port")
  return 1
}

check_files() {
  [[ "$JSON" == "0" ]] && echo "Files"
  if [[ -d "$INSTALL_DIR" ]]; then
    status_line OK "install dir exists: $INSTALL_DIR"
  else
    status_line FAIL "install dir missing: $INSTALL_DIR"
  fi
  if [[ -f "$COMPOSE_FILE" ]]; then
    status_line OK "Compose file exists"
  else
    status_line FAIL "Compose file missing: $COMPOSE_FILE"
  fi
  if [[ -f "$HYSTERIA_CONFIG" ]]; then
    status_line OK "Hysteria config exists"
  else
    status_line FAIL "Hysteria config missing: $HYSTERIA_CONFIG"
  fi
  if [[ -f "$HYSTERIA_CONFIG" ]]; then
    local mode
    mode="$(stat -c '%a' "$HYSTERIA_CONFIG" 2>/dev/null || true)"
    if [[ "$mode" == "600" ]]; then
      status_line OK "Hysteria config mode is 0600"
    else
      status_line WARN "Hysteria config mode is $mode, expected 600"
    fi
  fi
}

check_docker() {
  local version
  [[ "$JSON" == "0" ]] && echo "Docker"
  if ! have_cmd docker; then
    status_line FAIL "docker command is missing"
    return
  fi
  if ! docker info >/dev/null 2>&1; then
    status_line FAIL "docker is installed, but daemon/socket is not reachable"
    return
  fi
  status_line OK "docker daemon is reachable"

  if docker compose version >/dev/null 2>&1; then
    status_line OK "Docker Compose is available"
    if [[ -f "$COMPOSE_FILE" ]] && docker compose -f "$COMPOSE_FILE" config -q >/dev/null 2>&1; then
      status_line OK "Compose configuration is valid"
    else
      status_line FAIL "Compose configuration is invalid or missing"
    fi
  else
    status_line FAIL "Docker Compose plugin is missing"
  fi

  if container_running hysteria; then
    status_line OK "container hysteria is running"
  else
    status_line FAIL "container hysteria is not running"
  fi

  version="$(hysteria_version)"
  [[ -n "$version" ]] && status_line INFO "$version"
}

check_config_validation() {
  [[ "$JSON" == "0" ]] && echo "Configuration"

  if [[ -f "$HYSTERIA_CONFIG" ]]; then
    if have_cmd python3 && python3 -c 'import yaml' >/dev/null 2>&1; then
      if python3 - "$HYSTERIA_CONFIG" >/dev/null 2>&1 <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    config = yaml.safe_load(stream)

assert isinstance(config, dict)
assert config.get("listen") == ":443"
assert config.get("acme", {}).get("type") == "http"
assert config.get("auth", {}).get("type") == "password"
assert config.get("auth", {}).get("password")
assert config.get("masquerade", {}).get("listenHTTPS") == ":443"
PY
      then
        status_line OK "Hysteria YAML parses and contains required fields"
      else
        status_line FAIL "Hysteria YAML is invalid or incomplete"
      fi
    else
      status_line INFO "python3-yaml is unavailable; skipped local YAML parsing"
    fi
  fi

}

check_ports() {
  [[ "$JSON" == "0" ]] && echo "Listeners"
  if ! have_cmd ss; then
    status_line WARN "ss command is missing; cannot inspect listeners"
    return
  fi

  if port_has_non_loopback_listener udp 443; then
    status_line OK "443/udp is publicly listening for Hysteria 2"
  elif port_listening udp 443; then
    status_line FAIL "443/udp is loopback-only"
  else
    status_line FAIL "443/udp is not listening"
  fi

  if port_has_non_loopback_listener tcp 443; then
    status_line OK "443/tcp is publicly listening for HTTPS masquerade"
  elif port_listening tcp 443; then
    status_line FAIL "443/tcp is loopback-only"
  else
    status_line FAIL "443/tcp is not listening"
  fi

  if port_has_non_loopback_listener tcp 80; then
    status_line INFO "80/tcp currently has a public ACME listener"
  elif port_listening tcp 80; then
    status_line WARN "80/tcp is listening only on loopback"
  else
    status_line INFO "80/tcp is idle; Hysteria opens it when HTTP-01 validation needs it"
  fi
}

check_dns() {
  local domain
  [[ "$JSON" == "0" ]] && echo "DNS"
  domain="$(state_value domain "$INSTALL_STATE")"
  if [[ -z "$domain" ]]; then
    status_line WARN "installed domain is not recorded"
  elif getent ahosts "$domain" >/dev/null 2>&1; then
    status_line OK "$domain resolves"
  else
    status_line FAIL "$domain does not resolve"
  fi
}

check_firewall() {
  [[ "$JSON" == "0" ]] && echo "Firewall"
  if ! have_cmd nft; then
    status_line WARN "nft command is missing"
    return
  fi
  if nft list table inet "$FIREWALL_TABLE" >/dev/null 2>&1; then
    status_line OK "nft table inet $FIREWALL_TABLE is active"
  else
    status_line INFO "installer firewall is not active"
  fi
  if service_active hysteria-vps-firewall.service; then
    status_line OK "hysteria-vps-firewall.service is active"
  elif service_enabled hysteria-vps-firewall.service; then
    status_line WARN "firewall service is enabled but not active"
  else
    status_line INFO "firewall service is not enabled"
  fi
}

check_udp_tuning() {
  local actual_rmem actual_wmem expected
  [[ "$JSON" == "0" ]] && echo "UDP buffers"
  actual_rmem="$(sysctl_value net.core.rmem_max)"
  actual_wmem="$(sysctl_value net.core.wmem_max)"
  expected="$(state_value udp_buffer_bytes "$OPTIMIZE_STATE")"

  status_line INFO "net.core.rmem_max=${actual_rmem:-n/a}"
  status_line INFO "net.core.wmem_max=${actual_wmem:-n/a}"
  if [[ -n "$expected" ]]; then
    if [[ "$actual_rmem" == "$expected" && "$actual_wmem" == "$expected" ]]; then
      status_line OK "UDP buffers match the saved profile"
    else
      status_line WARN "UDP buffers differ from the saved profile ($expected)"
    fi
  elif [[ "$actual_rmem" =~ ^[0-9]+$ && "$actual_wmem" =~ ^[0-9]+$ ]] \
    && (( actual_rmem >= 16777216 && actual_wmem >= 16777216 )); then
    status_line OK "UDP buffers meet the 16 MiB recommendation"
  else
    status_line INFO "recommended UDP buffer profile is not applied"
  fi
}

bool_command() {
  if "$@" >/dev/null 2>&1; then
    printf true
  else
    printf false
  fi
}

emit_json() {
  local domain version rmem wmem
  domain="$(state_value domain "$INSTALL_STATE")"
  version="$(hysteria_version)"
  rmem="$(sysctl_value net.core.rmem_max)"
  wmem="$(sysctl_value net.core.wmem_max)"

  printf '{'
  printf '"install_dir":"%s",' "$(json_escape "$INSTALL_DIR")"
  printf '"domain":"%s",' "$(json_escape "$domain")"
  printf '"hysteria_version":"%s",' "$(json_escape "$version")"
  printf '"compose_file":%s,' "$(bool_command test -f "$COMPOSE_FILE")"
  printf '"hysteria_config":%s,' "$(bool_command test -f "$HYSTERIA_CONFIG")"
  printf '"hysteria_running":%s,' "$(bool_command container_running hysteria)"
  printf '"udp_443_public":%s,' "$(bool_command port_has_non_loopback_listener udp 443)"
  printf '"tcp_443_public":%s,' "$(bool_command port_has_non_loopback_listener tcp 443)"
  printf '"firewall_active":%s,' "$(bool_command nft list table inet "$FIREWALL_TABLE")"
  printf '"rmem_max":"%s",' "$(json_escape "$rmem")"
  printf '"wmem_max":"%s",' "$(json_escape "$wmem")"
  printf '"ok":%s,"warn":%s,"fail":%s}\n' "$OK" "$WARN" "$FAIL"
}

if [[ "$JSON" == "0" ]]; then
  echo "hysteria-vps-setup diagnostics"
  echo
fi

check_files
check_docker
check_config_validation
check_ports
check_dns
check_firewall
check_udp_tuning

if [[ "$JSON" == "1" ]]; then
  emit_json
else
  echo
  printf 'Summary: OK=%d WARN=%d FAIL=%d\n' "$OK" "$WARN" "$FAIL"
fi

[[ "$FAIL" -eq 0 ]]
