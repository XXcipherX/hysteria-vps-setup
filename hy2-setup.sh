#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if script started as root
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Install idn
apt-get update
apt-get install idn sudo -y

read -ep "Enter your domain: " input_domain
export DOMAIN=$(echo "$input_domain" | idn)

read -ep "Enter your email: " input_email
export EMAIL=$(echo "$input_email")

docker_install() {
  curl -fsSL https://get.docker.com | bash
}

if ! command -v docker >/dev/null 2>&1; then
    docker_install
fi

export PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20; echo)
export SALAMANDER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 25; echo)

hysteria_setup() {
  mkdir -p /opt/hysteria-vps-setup
  cd /opt/hysteria-vps-setup
    envsubst < "$SCRIPT_DIR/templates_for_script/compose" > ./docker-compose.yml
    envsubst < "$SCRIPT_DIR/templates_for_script/hysteria" > ./hysteria.yaml
    mkdir -p /opt/hysteria-vps-setup/templates
    envsubst < "$SCRIPT_DIR/templates_for_script/confluence_page" > ./templates/index.html
}

hysteria_setup

end_script() {
    docker compose -f /opt/hysteria-vps-setup/docker-compose.yml up -d
    echo ""
    echo "hysteria2://$PASS@$DOMAIN:443?obfs=salamander&obfs-password=$SALAMANDER_PASS&insecure=0#"
}

end_script
