#!/usr/bin/env bash
# server-clone-rsync - The Ultimate Docker-Aware Migration Script
# - Preserves the destination kernel environment to ensure Docker compatibility.
# - Clones filesystems while preserving destination SSH, network, and auth.
# - Performs a post-sync self-repair and startup of Docker and Marzban services.
set -euo pipefail

echo "=== The Ultimate Docker-Aware Server Clone Script ==="

# ---- helpers ----
confirm_install() {
  local pkg="$1" bin="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    read -rp "Package '$pkg' (for '$bin') is missing. Install it now? [Y/n]: " ans
    ans=${ans:-Y}
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      apt-get update && apt-get install -y "$pkg"
    else
      echo "Cannot continue without $pkg"; exit 1
    fi
  fi
}

# ---- prereqs ----
confirm_install rsync rsync
confirm_install openssh-client ssh

# ---- inputs ----
read -rp "Destination host/IP: " DEST_IP
read -rp "Destination SSH port (default: 22): " DEST_PORT; DEST_PORT=${DEST_PORT:-22}
read -rp "Destination username (default: root): " DEST_USER; DEST_USER=${DEST_USER:-root}
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS; echo
DEST="${DEST_USER}@${DEST_IP}"

# ---- SSH setup ----
SSH_OPTS_BASE=(
  -T -x -p "${DEST_PORT}"
  -o Compression=no
  -o TCPKeepAlive=yes
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
  -c aes128-gcm@openssh.com
)

# Handle known_hosts
ssh-keygen -R "[${DEST_IP}]:${DEST_PORT}" >/dev/null 2>&1 || true
ssh-keyscan -p "${DEST_PORT}" -t ed25519 "${DEST_IP}" >> ~/.ssh/known_hosts 2>/dev/null || true

TMP_KEY_PATH=""
cleanup_key() {
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    shred -u "${TMP_KEY_PATH}" 2>/dev/null || rm -f "${TMP_KEY_PATH}" 2>/dev/null || true
  fi
}
trap cleanup_key EXIT

# ---- Authentication setup and connectivity check ----
SSH_CMD=()
if [[ -n "${DEST_PASS}" ]]; then
  confirm_install sshpass sshpass
  SSH_CMD=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS_BASE[@]}")
else
  read -rp "SSH private key path (default: ~/.ssh/id_ed25519): " KEY_PATH
  KEY_PATH=${KEY_PATH:-~/.ssh/id_ed25519}
  if [[ "${KEY_PATH}" == *.ppk ]]; then
    confirm_install putty-tools puttygen
    TMP_KEY_PATH="/root/rsync_key_$$"
    echo "Converting PPK to OpenSSH format..."
    puttygen "${KEY_PATH}" -O private-openssh -o "${TMP_KEY_PATH}"
    chmod 600 "${TMP_KEY_PATH}"
    KEY_PATH="${TMP_KEY_PATH}"
  fi
  [[ -f "${KEY_PATH}" ]] || { echo "✗ SSH key not found: ${KEY_PATH}"; exit 1; }
  chmod 600 "${KEY_PATH}" 2>/dev/null || true
  SSH_CMD=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS_BASE[@]}")
fi

echo "=== Testing SSH connectivity ==="
"${SSH_CMD[@]}" "${DEST}" "echo '✓ SSH connection successful'" || { echo "✗ SSH connection failed"; exit 1; }

# ---- Pre-sync preparation on Destination ----
echo "=== Preparing destination server ==="
# Stop services on destination to prevent file-in-use errors
"${SSH_CMD[@]}" "${DEST}" "systemctl stop docker containerd 2>/dev/null || true; pkill -f dockerd 2>/dev/null || true"
echo "✓ Docker services stopped on destination."

# ---- Rsync Execution ----
echo "=== Starting rsync migration (this may take a while) ==="

RSYNC_OPTS=(
  -aAXH
  --numeric-ids
  --delete
  --force
  --delete-excluded
  --whole-file
  --delay-updates
  "--info=stats2,progress2"
)

# Robust excludes to prevent breaking the destination OS
EXCLUDES=(
  # System runtime & mounts
  --exclude=/dev/** --exclude=/proc/** --exclude=/sys/** --exclude=/run/** --exclude=/tmp/**
  --exclude=/mnt/** --exclude=/media/** --exclude=/lost+found --exclude=/swapfile*

  # Boot files & KERNEL ENVIRONMENT (CRITICAL FOR DOCKER COMPATIBILITY)
  --exclude=/boot/**
  --exclude=/lib/modules/**
  --exclude=/lib/firmware/**

  # Network and system identity (keep destination's settings)
  --exclude=/etc/network/** --exclude=/etc/netplan/** --exclude=/etc/hostname
  --exclude=/etc/hosts --exclude=/etc/resolv.conf --exclude=/etc/fstab
  --exclude=/etc/cloud/** --exclude=/var/lib/cloud/**
  --exclude=/etc/machine-id --exclude=/var/lib/dbus/machine-id

  # SSH server (keep destination's SSH service fully intact)
  --exclude=/etc/ssh/**

  # User auth (keep destination's users)
  --exclude=/etc/shadow* --exclude=/etc/passwd* --exclude=/etc/group* --exclude=/etc/gshadow*
  --exclude=/root/.ssh/** --exclude=/home/*/.ssh/**

  # Logs and cache
  --exclude=/var/log/** --exclude=/var/cache/** --exclude=/var/tmp/**
)

# Execute rsync
rsync "${RSYNC_OPTS[@]}" -e "$(printf '%q ' "${SSH_CMD[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

# ---- Post-sync Self-Repair on Destination ----
echo "=== Running post-sync setup and repair on destination ==="

# Using a heredoc for the remote script is cleaner and safer
"${SSH_CMD[@]}" "${DEST}" bash <<'EOF'
set -e
echo "--- Post-sync system setup ---"

# Reload systemd to recognize any new/changed service files
systemctl daemon-reload

# Reset any services that might have failed during the process
systemctl reset-failed docker.service docker.socket containerd.service 2>/dev/null || true

# Start Docker's dependencies first
if systemctl list-unit-files | grep -q "^containerd.service"; then
  echo "Starting containerd..."
  systemctl enable --now containerd.service
fi
sleep 3

# Start Docker itself
echo "Starting Docker services..."
systemctl enable --now docker.socket
sleep 2
systemctl enable --now docker.service

# Wait for Docker to be fully ready
echo "Waiting for Docker daemon..."
timeout=60
while [ $timeout -gt 0 ]; do
  if docker info >/dev/null 2>&1; then
    echo "✓ Docker is ready!"
    break
  fi
  sleep 2
  timeout=$((timeout - 2))
done

if ! docker info >/dev/null 2>&1; then
  echo "✗ Docker failed to start properly. Check logs:"
  journalctl -u docker.service --no-pager -n 20
  exit 1
fi

# Start Marzban if its directory exists
if [ -d "/opt/marzban" ]; then
  echo "--- Starting Marzban services ---"
  cd /opt/marzban
  if [ -f "docker-compose.yml" ] || [ -f "compose.yml" ]; then
    echo "Starting Marzban containers..."
    docker compose up -d --remove-orphans
    sleep 10
    echo "--- Marzban Status ---"
    docker compose ps
  else
    echo "⚠ No docker-compose.yml found in /opt/marzban"
  fi
else
  echo "✓ No Marzban installation found, skipping."
fi

echo "--- Setup completed successfully ---"
EOF

echo
echo "=== Migration Complete! ==="
echo "Destination server: ${DEST_IP}:${DEST_PORT}"
echo "It is recommended to reboot the destination server now: ssh ${DEST}@${DEST_IP} -p ${DEST_PORT} 'reboot'"
