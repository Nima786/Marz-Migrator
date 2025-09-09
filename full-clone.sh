#!/usr/bin/env bash
# full-clone.sh — Full rsync clone (same-arch) that leaves Server B login untouched
# - Copies apps/configs/data
# - Keeps B's SSH/server login intact (does NOT copy /etc/{shadow,passwd} or users' ~/.ssh)
# - No Docker/systemd post-processing; pure clone

set -euo pipefail
echo "=== Server Migration (rsync full clone: auth-safe, no post steps) ==="

# --- helpers ---
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

# prereqs on Source (A)
confirm_install rsync rsync
confirm_install openssh-client ssh

# --- inputs ---
read -rp "Destination server IP: " DEST_IP
read -rp "Destination username (default: root): " DEST_USER
DEST_USER=${DEST_USER:-root}
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS
echo
DEST="${DEST_USER}@${DEST_IP}"

# --- SSH setup ---
SSH_OPTS=(-T -x -o Compression=no -o TCPKeepAlive=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new -c aes128-gcm@openssh.com)

TMP_KEY_PATH=""
cleanup_key() {
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    shred -u "${TMP_KEY_PATH}" 2>/dev/null || rm -f "${TMP_KEY_PATH}" 2>/dev/null || true
  fi
}
trap cleanup_key EXIT

RSYNC_SSH=()
if [[ -n "${DEST_PASS}" ]]; then
  confirm_install sshpass sshpass
  RSYNC_SSH=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS[@]}")
else
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
  RSYNC_SSH=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS[@]}")
fi

# avoid stale known_hosts on reused IPs
ssh-keygen -R "${DEST_IP}" >/dev/null 2>&1 || true
ssh-keyscan -t ed25519 "${DEST_IP}" >> ~/.ssh/known_hosts 2>/dev/null || true

# connectivity check
echo "=== Checking SSH connectivity ==="
if "${RSYNC_SSH[@]}" -o BatchMode=yes -o ConnectTimeout=5 "${DEST}" true >/dev/null 2>&1; then
  echo "✓ SSH reachable."
else
  echo "✗ SSH connectivity failed."; exit 1
fi

echo "=== Starting rsync full clone to ${DEST} ==="

# rsync core options
RSYNC_BASE_OPTS=(
  -aAXH
  --numeric-ids
  --delete
  --whole-file
  --delay-updates
  "--info=stats2,progress2"
)

# Excludes: runtime, boot, network identity, SSH server, AUTH files, users' keys, (optional) firewall
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
  # ⛔ do NOT copy auth creds from A → B (B's login stays untouched)
  --exclude=/etc/shadow --exclude=/etc/gshadow --exclude=/etc/passwd --exclude=/etc/group
  --exclude=/root/.ssh/* --exclude=/home/*/.ssh/*
  # optional: avoid copying firewall state to prevent accidental lockout
  --exclude=/etc/ufw/** --exclude=/var/lib/ufw/** --exclude=/etc/iptables* --exclude=/etc/nftables.conf --exclude=/etc/firewalld/** --exclude=/etc/fail2ban/**
  # noise
  --exclude=/var/cache/* --exclude=/var/tmp/* --exclude=/var/log/journal/*
)

rsync "${RSYNC_BASE_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

echo
echo "=== Clone complete. Server B login remains exactly as before. Reboot ${DEST_IP} and test your services. ==="
