#!/usr/bin/env bash
# full-clone.sh — Full rsync clone (same-architecture)
# - Copies entire system, minus runtime, boot, and network/identity/SSH configs
# - Works out of the box for CyberPanel, OLS, MySQL, Docker, etc.
set -euo pipefail

echo "=== Server Migration (rsync full clone) ==="

# ---------- helpers ----------
confirm_install() {
  local pkg="$1" bin="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    read -rp "Package '$pkg' (for '$bin') is missing. Install it now? [Y/n]: " ans
    ans=${ans:-Y}
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      apt-get update && apt-get install -y "$pkg"
    else
      echo "Cannot continue without $pkg"
      exit 1
    fi
  fi
}

# ---------- required tools ----------
confirm_install rsync rsync
confirm_install openssh-client ssh

# ---------- inputs ----------
read -rp "Destination server IP: " DEST_IP
read -rp "Destination username (default: root): " DEST_USER
DEST_USER=${DEST_USER:-root}
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS
echo

DEST="${DEST_USER}@${DEST_IP}"

# ---------- ssh setup ----------
SSH_OPTS=(
  -T -x
  -o Compression=no
  -o TCPKeepAlive=yes
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
  -c aes128-gcm@openssh.com
)

RSYNC_SSH=()
if [[ -n "${DEST_PASS}" ]]; then
  confirm_install sshpass sshpass
  RSYNC_SSH=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS[@]}")
else
  read -rp "SSH private key path (default: ~/.ssh/id_ed25519): " KEY_PATH
  KEY_PATH=${KEY_PATH:-~/.ssh/id_ed25519}
  if [[ ! -f "${KEY_PATH}" ]]; then
    echo "SSH key not found: $KEY_PATH"
    exit 1
  fi
  chmod 600 "${KEY_PATH}" || true
  RSYNC_SSH=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS[@]}")
fi

# ---------- refresh known_hosts ----------
ssh-keygen -R "${DEST_IP}" >/dev/null 2>&1 || true
ssh-keyscan -t ed25519 "${DEST_IP}" >> ~/.ssh/known_hosts 2>/dev/null || true

# ---------- connectivity test ----------
echo "=== Checking SSH connectivity ==="
if "${RSYNC_SSH[@]}" -o BatchMode=yes -o ConnectTimeout=5 "${DEST}" true >/dev/null 2>&1; then
  echo "✓ SSH reachable."
else
  echo "✗ SSH connectivity failed."
  exit 1
fi

echo "=== Starting rsync full clone to ${DEST} ==="

RSYNC_BASE_OPTS=(
  -aAXH
  --numeric-ids
  --delete
  --whole-file
  --delay-updates
  "--info=stats2,progress2"
)

EXCLUDES=(
  --exclude=/dev/*
  --exclude=/proc/*
  --exclude=/sys/*
  --exclude=/tmp/*
  --exclude=/run/*
  --exclude=/mnt/*
  --exclude=/media/*
  --exclude=/lost+found
  --exclude=/swapfile
  --exclude=/boot/*
  # network & identity
  --exclude=/etc/network/*
  --exclude=/etc/netplan/*
  --exclude=/etc/hostname
  --exclude=/etc/hosts
  --exclude=/etc/resolv.conf
  --exclude=/etc/fstab
  --exclude=/etc/cloud/*
  --exclude=/var/lib/cloud/*
  --exclude=/etc/machine-id
  --exclude=/var/lib/dbus/machine-id
  # keep dest SSH server config/keys
  --exclude=/etc/ssh/*
)

rsync "${RSYNC_BASE_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

echo "=== Clone complete. Reboot ${DEST_IP} and check services. ==="
