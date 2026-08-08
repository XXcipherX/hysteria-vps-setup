#!/usr/bin/env bash

set -euo pipefail

SSH_KEY_TEST_FILE=""
DOCKER_INSTALLER_FILE=""
RENDER_TMP_FILE=""
CLIENT_URI=""

cleanup() {
  if [[ -n "$SSH_KEY_TEST_FILE" ]]; then
    rm -f -- "$SSH_KEY_TEST_FILE"
  fi
  if [[ -n "$DOCKER_INSTALLER_FILE" ]]; then
    rm -f -- "$DOCKER_INSTALLER_FILE"
  fi
  if [[ -n "$RENDER_TMP_FILE" ]]; then
    rm -f -- "$RENDER_TMP_FILE"
  fi
}

trap cleanup EXIT
trap 'echo "Error on line $LINENO. Exit code: $?" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/hysteria-vps-setup"
STATE_DIR="/var/lib/hysteria-vps-setup"
CLIENT_CONFIG="$STATE_DIR/client.yaml"
BACKUP_ROOT="/var/backups/hysteria-vps-setup"
BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
HYSTERIA_IMAGE="tobyxdd/hysteria:v2"
SSH_SAFETY_UNIT="hysteria-vps-ssh-safety"
SSH_SAFETY_DELAY="${HVS_SAFETY_DELAY:-300}"
export DEBIAN_FRONTEND=noninteractive

info() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

backup_path() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$(dirname -- "$BACKUP_DIR$path")"
    cp -a -- "$path" "$BACKUP_DIR$path"
    info "Backed up $path to $BACKUP_DIR$path"
  fi
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Please run as root"
  fi
}

check_platform() {
  command -v apt-get >/dev/null 2>&1 || die "This installer requires an apt-based Debian/Ubuntu system"
  command -v systemctl >/dev/null 2>&1 || die "This installer requires systemd"
  [[ -d /run/systemd/system ]] || die "systemd is not running"
}

check_repository_files() {
  local file
  for file in client compose hysteria; do
    [[ -f "$SCRIPT_DIR/templates_for_script/$file" ]] || die "Missing required template: $file"
  done
  for file in firewall.sh optimize.sh; do
    [[ -f "$SCRIPT_DIR/scripts/$file" ]] || die "Missing required script: $file"
  done
}

confirm_reinstall() {
  local answer
  [[ -e "$INSTALL_DIR" || -e "$STATE_DIR/install.env" ]] || return 0
  warn "An existing hysteria-vps-setup installation was found."
  read -r -e -p "Back it up and replace its generated configuration? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Installation cancelled"
}

install_dependencies() {
  info "Installing base dependencies..."
  apt-get update
  apt-get install -y \
    ca-certificates curl dnsutils gettext-base idn iproute2 nftables \
    openssh-client openssh-server openssl sudo
}

read_domain() {
  local input_domain converted_domain dns_records answer

  read -r -e -p "Enter your domain: " input_domain
  while [[ -z "$input_domain" ]]; do
    read -r -e -p "Domain cannot be empty. Enter your domain: " input_domain
  done
  input_domain="${input_domain%.}"

  if ! converted_domain="$(printf '%s\n' "$input_domain" | idn)"; then
    die "Could not convert the domain to IDNA"
  fi
  if ! [[ "$converted_domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
    die "Invalid domain: $converted_domain"
  fi
  HYSTERIA_DOMAIN="${converted_domain,,}"
  export HYSTERIA_DOMAIN

  dns_records="$(
    dig +short A "$HYSTERIA_DOMAIN"
    dig +short AAAA "$HYSTERIA_DOMAIN"
  )"
  if [[ -z "$dns_records" ]]; then
    read -r -e -p "The domain has no A or AAAA record. Continue anyway? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "Come back after DNS is configured"
  else
    info "DNS records found:"
    printf '%s\n' "$dns_records"
  fi
}

read_email() {
  local input_email
  read -r -e -p "Enter your ACME email: " input_email
  while ! [[ "$input_email" =~ ^[^[:space:]@:#]+@[^[:space:]@:#]+\.[^[:space:]@:#]+$ ]]; do
    read -r -e -p "Invalid email. Enter your ACME email: " input_email
  done
  HYSTERIA_EMAIL="$input_email"
  export HYSTERIA_EMAIL
}

read_security_options() {
  read -r -e -p "Configure server security? Do this on first run only. [y/N]: " configure_ssh_input
  if [[ ${configure_ssh_input,,} != "y" ]]; then
    SSH_PORT=22
    SSH_USER=""
    export SSH_PORT SSH_USER
    return 0
  fi

  read -r -e -p "Enter SSH port (default 22; ports 80 and 443 are reserved): " input_ssh_port
  input_ssh_port="${input_ssh_port:-22}"
  while ! [[ "$input_ssh_port" =~ ^[0-9]+$ ]] \
    || (( 10#$input_ssh_port < 1 || 10#$input_ssh_port > 65535 )) \
    || [[ "$input_ssh_port" == "80" || "$input_ssh_port" == "443" ]]; do
    read -r -e -p "Invalid or reserved port. Enter again: " input_ssh_port
    input_ssh_port="${input_ssh_port:-22}"
  done
  SSH_PORT="$input_ssh_port"
  export SSH_PORT

  read -r -e -p "Enter SSH public key: " input_ssh_pbk
  SSH_KEY_TEST_FILE="$(mktemp)"
  printf '%s\n' "$input_ssh_pbk" > "$SSH_KEY_TEST_FILE"
  while ! ssh-keygen -l -f "$SSH_KEY_TEST_FILE" >/dev/null 2>&1; do
    warn "The public key is invalid. Paste a complete OpenSSH public key."
    read -r -e -p "Enter SSH public key: " input_ssh_pbk
    printf '%s\n' "$input_ssh_pbk" > "$SSH_KEY_TEST_FILE"
  done
  rm -f -- "$SSH_KEY_TEST_FILE"
  SSH_KEY_TEST_FILE=""
}

read_performance_options() {
  read -r -e -p "Apply the recommended Hysteria UDP buffer profile? [y/N]: " configure_optimize_input
}

docker_install() {
  DOCKER_INSTALLER_FILE="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$DOCKER_INSTALLER_FILE"
  bash "$DOCKER_INSTALLER_FILE"
  rm -f -- "$DOCKER_INSTALLER_FILE"
  DOCKER_INSTALLER_FILE=""
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    info "Installing Docker Engine and Compose..."
    docker_install
  fi
  systemctl enable --now docker
}

generate_credentials() {
  local candidate

  HYSTERIA_PASSWORD="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
  [[ -n "$HYSTERIA_PASSWORD" ]] || die "Failed to generate the Hysteria password"
  export HYSTERIA_PASSWORD HYSTERIA_IMAGE

  if [[ ${configure_ssh_input,,} == "y" ]]; then
    while true; do
      candidate="u$(openssl rand -hex 4)"
      if ! getent passwd "$candidate" >/dev/null 2>&1; then
        SSH_USER="$candidate"
        break
      fi
    done
    export SSH_USER
  fi
}

render_configs() {
  backup_path "$INSTALL_DIR/docker-compose.yml"
  backup_path "$INSTALL_DIR/hysteria/config.yaml"
  backup_path "$INSTALL_DIR/hysteria/acme"
  backup_path "$CLIENT_CONFIG"

  install -d -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/hysteria"
  install -d -m 0700 "$INSTALL_DIR/hysteria/acme"
  install -d -m 0700 "$STATE_DIR"

  RENDER_TMP_FILE="$(mktemp "$INSTALL_DIR/.compose.XXXXXX")"
  # shellcheck disable=SC2016 # envsubst needs literal variable names.
  envsubst '${HYSTERIA_IMAGE}' < "$SCRIPT_DIR/templates_for_script/compose" > "$RENDER_TMP_FILE"
  install -m 0644 "$RENDER_TMP_FILE" "$INSTALL_DIR/docker-compose.yml"
  rm -f -- "$RENDER_TMP_FILE"

  RENDER_TMP_FILE="$(mktemp "$INSTALL_DIR/.hysteria.XXXXXX")"
  # shellcheck disable=SC2016 # envsubst needs literal variable names.
  envsubst '${HYSTERIA_DOMAIN} ${HYSTERIA_EMAIL} ${HYSTERIA_PASSWORD}' \
    < "$SCRIPT_DIR/templates_for_script/hysteria" > "$RENDER_TMP_FILE"
  install -m 0600 "$RENDER_TMP_FILE" "$INSTALL_DIR/hysteria/config.yaml"
  rm -f -- "$RENDER_TMP_FILE"

  RENDER_TMP_FILE="$(mktemp "$STATE_DIR/.client.XXXXXX")"
  # shellcheck disable=SC2016 # envsubst needs literal variable names.
  envsubst '${HYSTERIA_DOMAIN} ${HYSTERIA_PASSWORD}' \
    < "$SCRIPT_DIR/templates_for_script/client" > "$RENDER_TMP_FILE"
  install -m 0600 "$RENDER_TMP_FILE" "$CLIENT_CONFIG"
  rm -f -- "$RENDER_TMP_FILE"

  RENDER_TMP_FILE=""
}

add_user() {
  local sudoers_file="/etc/sudoers.d/$SSH_USER"

  useradd -m "$SSH_USER" -s /bin/bash
  install -d -m 0700 -o "$SSH_USER" -g "$SSH_USER" "/home/$SSH_USER/.ssh"
  printf '%s\n' "$input_ssh_pbk" > "/home/$SSH_USER/.ssh/authorized_keys"
  chmod 0600 "/home/$SSH_USER/.ssh/authorized_keys"

  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$SSH_USER" > "$sudoers_file"
  chmod 0440 "$sudoers_file"
  visudo -cf "$sudoers_file" >/dev/null

  printf 'sudo -i\n' > "/home/$SSH_USER/.bash_profile"
  chown -R "$SSH_USER:$SSH_USER" "/home/$SSH_USER"
  usermod -aG docker "$SSH_USER"
  passwd -l "$SSH_USER" >/dev/null 2>&1
}

arm_ssh_safety() {
  local conf="/etc/ssh/sshd_config"
  local dropin_dir="/etc/ssh/sshd_config.d"
  local backup_conf="$BACKUP_DIR$conf"
  local backup_dropin="$BACKUP_DIR$dropin_dir"

  systemctl stop "$SSH_SAFETY_UNIT.timer" "$SSH_SAFETY_UNIT.service" >/dev/null 2>&1 || true
  # shellcheck disable=SC2016 # Positional parameters expand inside the child shell.
  systemd-run --quiet --unit="$SSH_SAFETY_UNIT" --on-active="${SSH_SAFETY_DELAY}s" \
    /bin/bash -c '
      cp -a -- "$1" "$2"
      rm -rf -- "$3"
      if [[ -d "$4" ]]; then
        cp -a -- "$4" "$3"
      else
        install -d -m 0755 "$3"
      fi
      sshd -t && (systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service)
    ' _ "$backup_conf" "$conf" "$dropin_dir" "$backup_dropin"
  info "SSH safety timer armed for ${SSH_SAFETY_DELAY}s"
}

disarm_ssh_safety() {
  systemctl stop "$SSH_SAFETY_UNIT.timer" "$SSH_SAFETY_UNIT.service" >/dev/null 2>&1 || true
}

restore_ssh_config() {
  local conf="/etc/ssh/sshd_config"
  local dropin_dir="/etc/ssh/sshd_config.d"
  local backup_conf="$BACKUP_DIR$conf"
  local backup_dropin="$BACKUP_DIR$dropin_dir"

  cp -a -- "$backup_conf" "$conf"
  rm -rf -- "$dropin_dir"
  if [[ -d "$backup_dropin" ]]; then
    cp -a -- "$backup_dropin" "$dropin_dir"
  else
    install -d -m 0755 "$dropin_dir"
  fi
  sshd -t || die "The backed-up SSH configuration is invalid"
  systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service
  warn "Previous SSH configuration restored"
}

sshd_edit() {
  local conf="/etc/ssh/sshd_config"

  backup_path "$conf"
  backup_path /etc/ssh/sshd_config.d
  arm_ssh_safety
  install -d -m 0755 /etc/ssh/sshd_config.d

  sed -i 's|^[[:space:]]*Include[[:space:]]\+/etc/ssh/sshd_config.d/\*.conf|#&|' "$conf"
  sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' "$conf"
  rm -f /etc/ssh/sshd_config.d/*.conf

  cat > /etc/ssh/sshd_config.d/00-hysteria-vps-hardened.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
EOF

  sshd -t || die "sshd configuration validation failed"
  systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service
}

configure_security() {
  local firewall_result

  [[ ${configure_ssh_input,,} == "y" ]] || return 0
  add_user
  sshd_edit
  ok "SSH hardened. New key-only user: $SSH_USER; port: $SSH_PORT"
  if SSH_PORT="$SSH_PORT" HVS_TCP_PORTS="80,443" HVS_UDP_PORTS="443" \
    bash "$SCRIPT_DIR/scripts/firewall.sh" apply; then
    firewall_result=0
  else
    firewall_result=$?
  fi
  if [[ "$firewall_result" -ne 0 ]]; then
    restore_ssh_config
    disarm_ssh_safety
    return "$firewall_result"
  fi
  disarm_ssh_safety
  ok "SSH and firewall changes confirmed; safety timers disarmed"
}

apply_performance_profile() {
  [[ ${configure_optimize_input,,} == "y" ]] || return 0
  bash "$SCRIPT_DIR/scripts/optimize.sh" apply
}

container_running() {
  [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

hysteria_version() {
  docker exec hysteria hysteria version 2>/dev/null |
    awk '/^Version:/ { sub(/^Version:[[:space:]]*/, ""); print; exit }' || true
}

start_services() {
  local attempt

  info "Validating Compose configuration..."
  docker compose -f "$INSTALL_DIR/docker-compose.yml" config -q
  docker compose -f "$INSTALL_DIR/docker-compose.yml" pull

  info "Starting Hysteria 2..."
  docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d

  for ((attempt = 1; attempt <= 20; attempt++)); do
    if container_running hysteria; then
      ok "Hysteria container is running"
      return 0
    fi
    sleep 2
  done

  docker compose -f "$INSTALL_DIR/docker-compose.yml" ps >&2 || true
  docker compose -f "$INSTALL_DIR/docker-compose.yml" logs --tail=100 >&2 || true
  die "Containers did not become healthy enough to remain running"
}

generate_client_uri() {
  info "Generating client URI with Hysteria..."
  if ! CLIENT_URI="$(
    docker run --rm \
      --add-host "$HYSTERIA_DOMAIN:127.0.0.1" \
      -v "$CLIENT_CONFIG:/etc/hysteria/client.yaml:ro" \
      "$HYSTERIA_IMAGE" share -c /etc/hysteria/client.yaml
  )"; then
    die "Hysteria could not generate the client URI"
  fi
  if [[ "$CLIENT_URI" != hysteria2://* || "$CLIENT_URI" == *[[:space:]]* ]]; then
    die "Hysteria returned an invalid client URI"
  fi
}

write_install_state() {
  local install_state_ssh_user=""

  if [[ ${configure_ssh_input,,} == "y" ]]; then
    install_state_ssh_user="$SSH_USER"
  fi

  install -d -m 0700 "$STATE_DIR"
  backup_path "$STATE_DIR/install.env"
  backup_path "$STATE_DIR/client.uri"

  cat > "$STATE_DIR/install.env" <<EOF
installed_at=$(date -Is)
install_dir=$INSTALL_DIR
domain=$HYSTERIA_DOMAIN
email=$HYSTERIA_EMAIL
hysteria_image=$HYSTERIA_IMAGE
ssh_user=$install_state_ssh_user
ssh_port=$SSH_PORT
security_configured=${configure_ssh_input,,}
optimize_enabled=${configure_optimize_input,,}
backup_dir=$BACKUP_DIR
EOF
  printf '%s\n' "$CLIENT_URI" > "$STATE_DIR/client.uri"
  chmod 0600 "$STATE_DIR/install.env" "$STATE_DIR/client.uri"
}

print_result() {
  local version
  version="$(hysteria_version)"

  echo
  ok "Hysteria 2 installation completed"
  [[ -n "$version" ]] && printf 'Version: %s\n' "$version"
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    printf 'SSH user: %s\nSSH port: %s\n' "$SSH_USER" "$SSH_PORT"
  fi
  echo
  printf '%s\n' "$CLIENT_URI"
  echo
  printf 'Client YAML: %s (mode 0600)\n' "$CLIENT_CONFIG"
  printf 'Client URI: %s/client.uri (mode 0600)\n' "$STATE_DIR"
}

main() {
  require_root
  check_platform
  check_repository_files
  confirm_reinstall
  install_dependencies
  read_domain
  read_email
  read_security_options
  read_performance_options
  ensure_docker
  generate_credentials
  render_configs
  configure_security
  apply_performance_profile
  start_services
  generate_client_uri
  write_install_state
  print_result
}

main "$@"
