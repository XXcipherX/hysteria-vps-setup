#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

apt-get update
apt-get install idn sudo -y

read -ep "Enter your domain: " input_domain
export DOMAIN="$(echo "$input_domain" | idn)"

read -ep "Enter your email: " input_email
export EMAIL="$input_email"

read -ep "Do you want to configure server security? Do this on first run only. [y/N]: " configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  read -ep "Enter SSH port: " input_ssh_port

  if ! [[ "${input_ssh_port}" =~ ^[0-9]+$ ]] || [ "$input_ssh_port" -lt 1 ] || [ "$input_ssh_port" -gt 65535 ]; then
    echo "Invalid SSH port: $input_ssh_port"
    exit 1
  fi

  read -ep "Enter SSH public key: " input_ssh_pbk
  test_pbk_file="$(mktemp)"
  printf '%s\n' "$input_ssh_pbk" > "$test_pbk_file"

  if ! ssh-keygen -l -f "$test_pbk_file" >/dev/null 2>&1; then
    echo "Can't verify the public key. Try again and make sure to include 'ssh-rsa' or 'ssh-ed25519' followed by 'user@pcname' at the end of the file."
    rm -f "$test_pbk_file"
    exit 1
  fi

  rm -f "$test_pbk_file"
fi

docker_install() {
  curl -fsSL https://get.docker.com | bash
}

if ! command -v docker >/dev/null 2>&1; then
  docker_install
fi

export SSH_USER="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8; echo)"
export SSH_USER_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20; echo)"
export PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20; echo)"
export SALAMANDER_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 25; echo)"
export SSH_PORT="${input_ssh_port:-22}"

hysteria_setup() {
  mkdir -p /opt/hysteria-vps-setup
  cd /opt/hysteria-vps-setup
  envsubst < "$SCRIPT_DIR/templates_for_script/compose" > ./docker-compose.yml
  envsubst < "$SCRIPT_DIR/templates_for_script/hysteria" > ./hysteria.yaml
  mkdir -p /opt/hysteria-vps-setup/templates
  envsubst < "$SCRIPT_DIR/templates_for_script/confluence_page" > ./templates/index.html
}

hysteria_setup

sshd_edit() {
  sed -i -E "s/^#?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
  sed -i -E "s/^#?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
  sed -i -E "s/^#?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
  systemctl daemon-reload
  systemctl restart ssh
}

add_user() {
  useradd "$SSH_USER" -s /bin/bash
  usermod -aG sudo "$SSH_USER"
  echo "$SSH_USER:$SSH_USER_PASS" | chpasswd
  mkdir -p "/home/$SSH_USER/.ssh"
  touch "/home/$SSH_USER/.ssh/authorized_keys"
  echo "$input_ssh_pbk" >> "/home/$SSH_USER/.ssh/authorized_keys"
  chmod 700 "/home/$SSH_USER/.ssh/"
  chmod 600 "/home/$SSH_USER/.ssh/authorized_keys"
  chown "$SSH_USER:$SSH_USER" -R "/home/$SSH_USER"
  usermod -aG docker "$SSH_USER"
}

edit_iptables() {
  debconf-set-selections <<EODEBCONF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EODEBCONF

  apt-get -y install iptables-persistent netfilter-persistent

  iptables -F
  iptables -X
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A INPUT -p tcp -m conntrack --ctstate NEW --dport "$SSH_PORT" -j ACCEPT
  iptables -A INPUT -p tcp -m conntrack --ctstate NEW --dport 80 -j ACCEPT
  iptables -A INPUT -p udp -m conntrack --ctstate NEW --dport 443 -j ACCEPT

  ip6tables -F
  ip6tables -X
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT ACCEPT

  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
  ip6tables -A INPUT -p tcp -m conntrack --ctstate NEW --dport "$SSH_PORT" -j ACCEPT
  ip6tables -A INPUT -p tcp -m conntrack --ctstate NEW --dport 80 -j ACCEPT
  ip6tables -A INPUT -p udp -m conntrack --ctstate NEW --dport 443 -j ACCEPT

  netfilter-persistent save
}

if [[ ${configure_ssh_input,,} == "y" ]]; then
  sshd_edit
  add_user
  edit_iptables
fi

end_script() {
  docker compose -f /opt/hysteria-vps-setup/docker-compose.yml up -d
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "New user for ssh: $SSH_USER, password for user: $SSH_USER_PASS. New port for SSH: $SSH_PORT."
  fi
  echo ""
  echo "hysteria2://$PASS@$DOMAIN:443?obfs=salamander&obfs-password=$SALAMANDER_PASS&insecure=0#"
  echo ""
}

end_script
