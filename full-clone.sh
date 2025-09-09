#!/usr/bin/env bash
# Fixed rsync clone script - preserves Docker data and services
# This version handles Docker containers and services properly

set -euo pipefail
echo "=== Server Migration (rsync full clone: docker-aware) ==="

confirm_install() {
  local pkg="$1" bin="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    read -rp "Package '$pkg' (for '$bin') is missing. Install it now? [Y/n]: " a
    a=${a:-Y}
    if [[ "$a" =~ ^[Yy]$ ]]; then
      apt-get update && apt-get install -y "$pkg"
    else
      echo "Cannot continue without $pkg"; exit 1
    fi
  fi
}

# prerequisites on Source (A)
confirm_install rsync rsync
confirm_install openssh-client ssh

# inputs
read -rp "Destination host/IP: " DEST_IP
read -rp "Destination SSH port (default: 22): " DEST_PORT; DEST_PORT=${DEST_PORT:-22}
read -rp "Destination username (default: root): " DEST_USER; DEST_USER=${DEST_USER:-root}
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS; echo
DEST="${DEST_USER}@${DEST_IP}"

# SSH options
SSH_OPTS_BASE=(
  -T -x
  -p "${DEST_PORT}"
  -o Compression=no
  -o TCPKeepAlive=yes
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
  -c aes128-gcm@openssh.com
)

# refresh known_hosts for host:port
ssh-keygen -R "[${DEST_IP}]:${DEST_PORT}" >/dev/null 2>&1 || true
ssh-keyscan -p "${DEST_PORT}" -t ed25519 "${DEST_IP}" >> ~/.ssh/known_hosts 2>/dev/null || true

TMP_KEY_PATH=""
cleanup_key() {
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    shred -u "${TMP_KEY_PATH}" 2>/dev/null || rm -f "${TMP_KEY_PATH}" 2>/dev/null || true
  fi
}
trap cleanup_key EXIT

# auth + robust probe
RSYNC_SSH=()
if [[ -n "${DEST_PASS}" ]]; then
  confirm_install sshpass sshpass
  echo "=== Checking SSH connectivity (password) ==="
  if sshpass -p "${DEST_PASS}" ssh \
      "${SSH_OPTS_BASE[@]}" \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o KbdInteractiveAuthentication=no \
      "${DEST}" true >/dev/null 2>&1; then
    echo "✓ SSH reachable with password."
  else
    echo "… password-only failed, trying keyboard-interactive"
    if sshpass -p "${DEST_PASS}" ssh \
        "${SSH_OPTS_BASE[@]}" \
        -o PreferredAuthentications=keyboard-interactive,password \
        -o PubkeyAuthentication=no \
        "${DEST}" true >/dev/null 2>&1; then
      echo "✓ SSH reachable with keyboard-interactive."
    else
      echo "✗ SSH connectivity failed with the provided password."; exit 1
    fi
  fi
  RSYNC_SSH=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS_BASE[@]}")
else
  echo "=== Using SSH key authentication ==="
  read -rp "SSH private key path (default: ~/.ssh/id_ed25519): " KEY_PATH
  KEY_PATH=${KEY_PATH:-~/.ssh/id_ed25519}
  if [[ "${KEY_PATH}" == *.ppk ]]; then
    confirm_install putty-tools puttygen
    TMP_KEY_PATH="/root/rsync_key_$$"
    echo "Converting PPK -> OpenSSH…"
    puttygen "${KEY_PATH}" -O private-openssh -o "${TMP_KEY_PATH}"
    chmod 600 "${TMP_KEY_PATH}"
    KEY_PATH="${TMP_KEY_PATH}"
  fi
  [[ -f "${KEY_PATH}" ]] || { echo "SSH key not found: ${KEY_PATH}"; exit 1; }
  chmod 600 "${KEY_PATH}" || true
  if ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes -o BatchMode=yes "${SSH_OPTS_BASE[@]}" "${DEST}" true >/dev/null 2>&1; then
    echo "✓ SSH reachable with key."
  else
    echo "✗ SSH key login failed (non-interactive)."; exit 1
  fi
  RSYNC_SSH=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS_BASE[@]}")
fi

# STOP SERVICES ON SOURCE BEFORE SYNC
echo "=== Stopping services on source server ==="
systemctl stop docker 2>/dev/null || echo "Docker not running"
systemctl stop marzban 2>/dev/null || echo "Marzban service not found"

echo "=== Starting rsync to ${DEST} (port ${DEST_PORT}) ==="

# rsync options
RSYNC_BASE_OPTS=(
  -aAXH
  --delete
  --whole-file
  --delay-updates
  "--info=stats2,progress2"
)

# FIXED EXCLUDES - Keep Docker data but exclude only problematic runtime files
EXCLUDES=(
  # runtime/mounts
  --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found --exclude=/swapfile
  # boot
  --exclude=/boot/*
  # keep destination network/identity
  --exclude=/etc/network/* --exclude=/etc/netplan/* --exclude=/etc/hostname --exclude=/etc/hosts --exclude=/etc/resolv.conf --exclude=/etc/fstab
  --exclude=/etc/cloud/* --exclude=/var/lib/cloud/* --exclude=/etc/machine-id --exclude=/var/lib/dbus/machine-id
  # keep destination SSH server config & host keys
  --exclude=/etc/ssh/*
  # DO NOT copy auth creds or users' keys from A -> B
  --exclude=/etc/shadow --exclude=/etc/gshadow --exclude=/etc/passwd --exclude=/etc/group
  --exclude=/root/.ssh/* --exclude=/home/*/.ssh/*
  # reduce noise
  --exclude=/var/cache/* --exclude=/var/tmp/* --exclude=/var/log/journal/*

  # MINIMAL Docker excludes - only exclude truly problematic files
  --exclude=/var/lib/docker/tmp/**
  --exclude=/var/lib/docker/containers/*/mounts/**
  --exclude=/run/docker.sock
  --exclude=/var/run/docker.sock
  # Keep most docker data but exclude unit file overrides that might conflict
  --exclude=/etc/systemd/system/docker.service.d/**
)

# Run rsync
rsync "${RSYNC_BASE_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

echo
echo "=== Running post-clone setup on destination server ==="

# Post-clone commands to run on destination
POST_CLONE_COMMANDS='
# Reload systemd
systemctl daemon-reload

# Fix Docker permissions and start
if command -v docker >/dev/null 2>&1; then
  echo "Setting up Docker..."
  systemctl enable docker
  systemctl start docker || {
    echo "Docker failed to start, trying reset..."
    systemctl reset-failed docker
    systemctl start docker
  }
  
  # Wait for docker to be ready
  timeout 30 bash -c "until docker info >/dev/null 2>&1; do sleep 1; done" || echo "Docker may not be fully ready"
fi

# Navigate to Marzban and start services
if [ -d "/opt/marzban" ]; then
  echo "Starting Marzban services..."
  cd /opt/marzban
  
  # Pull any missing images
  docker compose pull || echo "Could not pull images"
  
  # Start services
  docker compose up -d || echo "Failed to start Marzban services"
  
  # Check status
  sleep 5
  docker compose ps
else
  echo "Marzban directory not found at /opt/marzban"
fi

# Start other services that might be needed
systemctl start cron 2>/dev/null || true
systemctl start rsyslog 2>/dev/null || true

echo "Post-clone setup completed!"
'

# Execute post-clone commands on destination
echo "Executing post-clone setup commands..."
if [[ -n "${DEST_PASS}" ]]; then
  sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS_BASE[@]}" "${DEST}" "${POST_CLONE_COMMANDS}"
else
  ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS_BASE[@]}" "${DEST}" "${POST_CLONE_COMMANDS}"
fi

# RESTART SERVICES ON SOURCE
echo "=== Restarting services on source server ==="
systemctl start docker 2>/dev/null || echo "Could not restart docker on source"
systemctl start marzban 2>/dev/null || echo "Marzban service not found on source"

echo
echo "=== Clone complete! ==="
echo "Check the destination server with:"
echo "  ssh ${DEST_USER}@${DEST_IP} -p ${DEST_PORT}"
echo "  docker ps"
echo "  cd /opt/marzban && docker compose ps"
