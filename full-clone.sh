#!/usr/bin/env bash
# Marzban Server Clone Script - Complete Docker-aware migration
# Handles Docker services, systemd states, and Marzban data properly

set -euo pipefail
echo "=== Marzban Server Clone Script ==="

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

# Prerequisites
confirm_install rsync rsync
confirm_install openssh-client ssh

# Get destination details
read -rp "Destination host/IP: " DEST_IP
read -rp "Destination SSH port (default: 22): " DEST_PORT; DEST_PORT=${DEST_PORT:-22}
read -rp "Destination username (default: root): " DEST_USER; DEST_USER=${DEST_USER:-root}
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS; echo
DEST="${DEST_USER}@${DEST_IP}"

# SSH configuration
SSH_OPTS_BASE=(
  -T -x -p "${DEST_PORT}"
  -o Compression=no
  -o TCPKeepAlive=yes
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
  -c aes128-gcm@openssh.com
)

# Setup SSH keys if needed
ssh-keygen -R "[${DEST_IP}]:${DEST_PORT}" >/dev/null 2>&1 || true
ssh-keyscan -p "${DEST_PORT}" -t ed25519 "${DEST_IP}" >> ~/.ssh/known_hosts 2>/dev/null || true

TMP_KEY_PATH=""
cleanup_key() {
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    shred -u "${TMP_KEY_PATH}" 2>/dev/null || rm -f "${TMP_KEY_PATH}" 2>/dev/null || true
  fi
}
trap cleanup_key EXIT

# Setup authentication
RSYNC_SSH=()
if [[ -n "${DEST_PASS}" ]]; then
  confirm_install sshpass sshpass
  echo "=== Testing SSH with password ==="
  sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS_BASE[@]}" "${DEST}" true || {
    echo "✗ SSH password authentication failed"; exit 1
  }
  echo "✓ SSH password authentication working"
  RSYNC_SSH=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS_BASE[@]}")
else
  echo "=== Setting up SSH key authentication ==="
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
  [[ -f "${KEY_PATH}" ]] || { echo "SSH key not found: ${KEY_PATH}"; exit 1; }
  chmod 600 "${KEY_PATH}" 2>/dev/null || true
  ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes -o BatchMode=yes "${SSH_OPTS_BASE[@]}" "${DEST}" true || {
    echo "✗ SSH key authentication failed"; exit 1
  }
  echo "✓ SSH key authentication working"
  RSYNC_SSH=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS_BASE[@]}")
fi

# Function to run commands on destination
run_remote() {
  local cmd="$1"
  if [[ -n "${DEST_PASS}" ]]; then
    sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS_BASE[@]}" "${DEST}" "${cmd}"
  else
    ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS_BASE[@]}" "${DEST}" "${cmd}"
  fi
}

echo "=== Pre-sync preparation ==="

# Stop services on source
echo "Stopping Docker services on source..."
systemctl stop docker 2>/dev/null || echo "Docker not running on source"

# Stop services on destination
echo "Stopping services on destination..."
run_remote "systemctl stop docker 2>/dev/null || true; pkill -f dockerd 2>/dev/null || true; pkill -f containerd 2>/dev/null || true"

# Clean destination Docker state
echo "Cleaning Docker runtime state on destination..."
run_remote "rm -rf /var/run/docker.sock /var/run/docker.pid /var/run/docker/* /run/docker.sock /run/docker.pid 2>/dev/null || true"

echo "=== Starting rsync migration ==="

# Rsync options - more conservative approach
RSYNC_OPTS=(
  -avAXH
  --numeric-ids
  --delete
  --delete-excluded
  --whole-file
  --inplace
  --progress
)

# Smart excludes - keep Docker data but exclude problematic runtime files
EXCLUDES=(
  # System runtime
  --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/run/* --exclude=/tmp/*
  --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found --exclude=/swapfile*
  
  # Boot files
  --exclude=/boot/efi/* --exclude=/boot/grub/*
  
  # Network and system identity (keep destination's settings)
  --exclude=/etc/network/* --exclude=/etc/netplan/* --exclude=/etc/hostname
  --exclude=/etc/hosts --exclude=/etc/resolv.conf --exclude=/etc/fstab
  --exclude=/etc/cloud/* --exclude=/var/lib/cloud/* 
  --exclude=/etc/machine-id --exclude=/var/lib/dbus/machine-id
  
  # SSH (keep destination's SSH config)
  --exclude=/etc/ssh/ssh_host_* --exclude=/etc/ssh/sshd_config
  
  # User auth (keep destination's users)
  --exclude=/etc/shadow* --exclude=/etc/passwd* --exclude=/etc/group* --exclude=/etc/gshadow*
  --exclude=/root/.ssh/authorized_keys --exclude=/home/*/.ssh/authorized_keys
  
  # Logs and cache
  --exclude=/var/log/* --exclude=/var/cache/* --exclude=/var/tmp/*
  --exclude=/var/log/journal/* --exclude=/var/lib/systemd/coredump/*
  
  # Docker runtime exclusions (only exclude truly problematic files)
  --exclude=/var/run/docker.sock --exclude=/run/docker.sock
  --exclude=/var/run/docker.pid --exclude=/run/docker.pid
  --exclude=/var/lib/docker/tmp/* --exclude=/var/lib/docker/containers/*/mounts/shm/*
  --exclude=/var/lib/docker/overlay2/*/merged/* --exclude=/var/lib/docker/overlay2/*/work/*
  --exclude=/var/lib/containerd/io.containerd.runtime.v*/tasks/*
  --exclude=/var/lib/containerd/tmpmounts/*
)

# Execute rsync
echo "Syncing filesystem (this may take a while)..."
rsync "${RSYNC_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

echo "=== Post-sync configuration ==="

# Comprehensive post-sync setup
POST_SYNC_SETUP='
set -e
echo "=== Post-sync system setup ==="

# Fix permissions and ownership
echo "Fixing critical permissions..."
chown root:root /var/lib/docker 2>/dev/null || true
chown root:docker /var/run/docker.sock 2>/dev/null || true
chmod 755 /var/lib/docker 2>/dev/null || true

# Ensure Docker group exists
groupadd -f docker

# Clean any remaining Docker runtime state
rm -rf /var/run/docker.sock /var/run/docker.pid /run/docker.sock /run/docker.pid 2>/dev/null || true
rm -rf /var/lib/docker/tmp/* 2>/dev/null || true

# Reload systemd
systemctl daemon-reload

# Reset any failed services
systemctl reset-failed docker.service 2>/dev/null || true
systemctl reset-failed docker.socket 2>/dev/null || true
systemctl reset-failed containerd.service 2>/dev/null || true

# Start containerd first (if exists)
if systemctl list-unit-files | grep -q "^containerd.service"; then
  echo "Starting containerd..."
  systemctl enable containerd.service
  systemctl start containerd.service
  sleep 3
fi

# Start Docker socket and service
echo "Starting Docker services..."
systemctl enable docker.socket
systemctl start docker.socket
sleep 2

systemctl enable docker.service
systemctl start docker.service

# Wait for Docker to be ready
echo \"Waiting for Docker to be ready...\"
timeout=60
while [ \$timeout -gt 0 ]; do
  if docker info >/dev/null 2>&1; then
    echo \"✓ Docker is ready!\"
    break
  fi
  sleep 2
  timeout=\$((timeout-2))
done

if ! docker info >/dev/null 2>&1; then
  echo \"✗ Docker failed to start properly\"
  journalctl -u docker.service --no-pager -n 10
  exit 1
fi

# Start Marzban if directory exists
if [ -d \"/opt/marzban\" ]; then
  echo \"=== Starting Marzban services ===\"
  cd /opt/marzban
  
  # Check if docker-compose.yml exists
  if [ -f \"docker-compose.yml\" ] || [ -f \"compose.yml\" ]; then
    echo \"Pulling latest images...\"
    docker compose pull || echo \"Warning: Could not pull some images\"
    
    echo \"Starting Marzban containers...\"
    docker compose up -d
    
    echo \"Waiting for services to start...\"
    sleep 10
    
    echo \"=== Marzban Status ===\"
    docker compose ps
    
    # Check if main containers are running
    if docker compose ps --services --filter \"status=running\" | grep -q .; then
      echo \"✓ Marzban services are running!\"
    else
      echo \"⚠ Some Marzban services may not be running properly\"
      docker compose logs --tail=20
    fi
  else
    echo \"⚠ No docker-compose.yml found in /opt/marzban\"
    ls -la /opt/marzban/
  fi
else
  echo \"⚠ /opt/marzban directory not found\"
fi

echo "=== Setup completed ==="
'

# Execute post-sync setup
echo "Running post-sync setup on destination..."
run_remote "${POST_SYNC_SETUP}"

# Restart Docker on source
echo "Restarting Docker on source server..."
systemctl start docker 2>/dev/null || echo "Could not restart Docker on source"

echo
echo "=== Migration Complete! ==="
echo "Destination server: ${DEST_IP}:${DEST_PORT}"
echo
echo "To verify the migration:"
echo "  ssh ${DEST_USER}@${DEST_IP} -p ${DEST_PORT}"
echo "  docker ps"
echo "  cd /opt/marzban && docker compose ps"
echo "  docker compose logs"
echo
echo "If you encounter issues, check logs with:"
echo "  journalctl -u docker.service -f"
