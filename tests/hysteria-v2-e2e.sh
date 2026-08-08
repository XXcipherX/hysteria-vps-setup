#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HYSTERIA_IMAGE="${HYSTERIA_IMAGE:-tobyxdd/hysteria:v2}"
SERVER_PORT="${HVS_E2E_SERVER_PORT:-18443}"
TARGET_PORT="${HVS_E2E_TARGET_PORT:-18080}"
E2E_DIR="$(mktemp -d)"
COMPOSE_FILE="$E2E_DIR/docker-compose.yml"
TARGET_PID=""

cleanup() {
  local status=$?

  if [[ "$status" -ne 0 && -f "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" ps >&2 || true
    docker compose -f "$COMPOSE_FILE" logs --tail=100 >&2 || true
  fi
  if [[ -f "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ -n "$TARGET_PID" ]]; then
    kill "$TARGET_PID" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$E2E_DIR"
  exit "$status"
}

trap cleanup EXIT

command -v docker >/dev/null 2>&1
command -v envsubst >/dev/null 2>&1
command -v openssl >/dev/null 2>&1
command -v python3 >/dev/null 2>&1
python3 -c 'import yaml'
docker compose version

install -d -m 0700 "$E2E_DIR/hysteria/acme"

export HYSTERIA_DOMAIN="localhost"
export HYSTERIA_EMAIL="ci@example.com"
export HYSTERIA_PASSWORD="hysteria-v2-e2e-password"
export HYSTERIA_IMAGE

envsubst '${HYSTERIA_DOMAIN} ${HYSTERIA_EMAIL} ${HYSTERIA_PASSWORD}' \
  < "$REPO_ROOT/templates_for_script/hysteria" > "$E2E_DIR/hysteria/config.yaml"
envsubst '${HYSTERIA_IMAGE}' \
  < "$REPO_ROOT/templates_for_script/compose" > "$COMPOSE_FILE"
envsubst '${HYSTERIA_DOMAIN} ${HYSTERIA_PASSWORD}' \
  < "$REPO_ROOT/templates_for_script/client" > "$E2E_DIR/client.yaml"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost' \
  -keyout "$E2E_DIR/hysteria/acme/server.key" \
  -out "$E2E_DIR/hysteria/acme/server.crt" >/dev/null 2>&1

python3 - \
  "$E2E_DIR/hysteria/config.yaml" \
  "$E2E_DIR/client.yaml" \
  "$SERVER_PORT" <<'PY'
import sys
import yaml

server_path, client_path, port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(server_path, encoding="utf-8") as stream:
    config = yaml.safe_load(stream)

config["listen"] = f":{port}"
config.pop("acme")
config["tls"] = {
    "cert": "/var/lib/hysteria/acme/server.crt",
    "key": "/var/lib/hysteria/acme/server.key",
}
config["masquerade"]["listenHTTPS"] = f":{port}"

with open(server_path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(config, stream, sort_keys=False)

with open(client_path, encoding="utf-8") as stream:
    client = yaml.safe_load(stream)

client["server"] = f"127.0.0.1:{port}"
client["tls"]["insecure"] = True

with open(client_path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(client, stream, sort_keys=False)
PY

python3 -m http.server "$TARGET_PORT" --bind 127.0.0.1 \
  --directory "$E2E_DIR" >"$E2E_DIR/http-server.log" 2>&1 &
TARGET_PID=$!

docker compose -f "$COMPOSE_FILE" config -q
docker compose -f "$COMPOSE_FILE" pull
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

ready=0
for _ in {1..30}; do
  if [[ "$(docker inspect --format '{{.State.Running}}' hysteria 2>/dev/null || true)" == "true" ]] \
    && docker logs hysteria 2>&1 | grep -q 'server up and running'; then
    ready=1
    break
  fi
  sleep 1
done

if [[ "$ready" -ne 1 ]]; then
  echo "Hysteria server did not become ready" >&2
  exit 1
fi

SHARE_URI="$(
  docker run --rm \
    -v "$E2E_DIR/client.yaml:/etc/hysteria/client.yaml:ro" \
    "$HYSTERIA_IMAGE" share -c /etc/hysteria/client.yaml
)"
if [[ "$SHARE_URI" != hysteria2://* || "$SHARE_URI" == *[[:space:]]* ]]; then
  echo "Hysteria share returned an invalid URI" >&2
  exit 1
fi

docker run --rm --network host \
  -v "$E2E_DIR/client.yaml:/etc/hysteria/client.yaml:ro" \
  "$HYSTERIA_IMAGE" ping -c /etc/hysteria/client.yaml "127.0.0.1:$TARGET_PORT"

docker exec hysteria hysteria version
echo "HYSTERIA V2 E2E: OK"
