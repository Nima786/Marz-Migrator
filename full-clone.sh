#!/usr/bin/env bash
# full-clone.sh — Clone Server A -> Server B with rsync
# Safe for login: DOES NOT overwrite SSH/PAM/passwd files on Server B.
# Optimized for >=1Gbps links (no compression, whole-file, fast cipher).
set -euo pipefail

echo "=== Server Migration (rsync clone) ==="

# ---------- helpers ----------
confirm_install() {
  # confirm_install <apt-package> <bin>
  local pkg="$1" bin="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    read -rp "Package '$pkg' (for '$bin') is missing. Install it now? [Y/n]: " _ans
    _ans=${_ans:-Y}
    if [[ "$_ans" =~ ^[Yy]$ ]]; then
      apt-get update && apt-get install -y "$pkg"
    else
      echo "Cannot continue without '$pkg'. Exiting."
      exit 1
    fi
  fi
}

# ---------- required tools on Source (A) ----------
echo "=== Checking required packages on Source Server (Server A) ==="
confirm_install rsync rsync
confirm_install openssh-client ssh

# ---------- gather inputs ----------
read -rp "Destination server IP: " DEST_IP
read -rp "Destination username (default: root): " DEST_USER
DEST_USER=${DEST_USER:-root}
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS
echo

DEST="${DEST_USER}@${DEST_IP}"

# ---------- SSH options ----------
SSH_OPTS=(
  -T
  -x
  -o Compression=no
  -o TCPKeepAlive=yes
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
  -c aes128-gcm@openssh.com
)

TMP_KEY_PATH=""
cleanup_key() {
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    shred -u "${TMP_KEY_PATH}" 2>/dev/null || true
  fi
}
trap cleanup_key EXIT

# ---------- auth selection (password or key) ----------
RSYNC_SSH=()
if [[ -n "${DEST_PASS}" ]]; then
  # password mode
  confirm_install sshpass sshpass
  RSYNC_SSH=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS[@]}")
  AUTH_MODE="password"
else
  # key mode
  read -rp "SSH private key path (default: ~/.ssh/id_ed25519): " KEY_PATH
  KEY_PATH=${KEY_PATH:-~/.ssh/id_ed25519}

  # .ppk support (convert to OpenSSH)
  if [[ "${KEY_PATH}" == *.ppk ]]; then
    confirm_install putty-tools puttygen
    TMP_KEY_PATH="/root/rsync_key_$$"
    echo "Converting PPK -> OpenSSH key with puttygen..."
    puttygen "${KEY_PATH}" -O private-openssh -o "${TMP_KEY_PATH}"
    chmod 600 "${TMP_KEY_PATH}"
    KEY_PATH="${TMP_KEY_PATH}"
  fi

  if [[ ! -f "${KEY_PATH}" ]]; then
    echo "Error: SSH key not found at '${KEY_PATH}'."
    exit 1
  fi
  chmod 600 "${KEY_PATH}" || true
  RSYNC_SSH=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS[@]}")
  AUTH_MODE="key"
fi

# ---------- nicety: refresh known_hosts for DEST_IP to avoid stale host-key errors ----------
ssh-keygen -R "${DEST_IP}" >/dev/null 2>&1 || true
ssh-keyscan -t ed25519 "${DEST_IP}" >> ~/.ssh/known_hosts 2>/dev/null || true

# ---------- friendly connectivity check (auth-aware) ----------
echo "=== Checking connectivity to ${DEST} ==="
if [[ "${AUTH_MODE}" == "password" ]]; then
  if sshpass -p "${DEST_PASS}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${DEST}" "echo ok" 2>/dev/null | grep -q ok; then
    echo "✓ SSH reachable with password."
  else
    echo "✗ Could not log in with the provided password. Aborting."
    exit 1
  fi
else
  if "${RSYNC_SSH[@]}" -o BatchMode=yes -o ConnectTimeout=5 "${DEST}" true >/dev/null 2>&1; then
    echo "✓ SSH reachable with key."
  else
    echo "✗ SSH key login failed (non-interactive). Aborting."
    exit 1
  fi
fi

echo "=== Starting rsync clone to ${DEST} ==="
echo "This will copy the entire filesystem except networking/identity/boot and login-related files."
echo "Source: /   ->   Destination: ${DEST}:/"
echo

# ---------- rsync options ----------
RSYNC_BASE_OPTS=(
  -aAXH
  --numeric-ids
  --delete
  --whole-file
  --delay-updates
  "--info=stats2,progress2"
)

# ---------- Excludes (DO NOT TOUCH login/SSH on B) ----------
EXCLUDES=(
  # runtime and mounts
  --exclude=/dev/*
  --exclude=/proc/*
  --exclude=/sys/*
  --exclude=/tmp/*
  --exclude=/run/*
  --exclude=/mnt/*
  --exclude=/media/*
  --exclude=/lost+found
  --exclude=/swapfile

  # kernel/boot (we're not replacing kernels/bootloader)
  --exclude=/boot/*
  --exclude=/lib/modules/*
  --exclude=/lib/firmware/*

  # caches/noise
  --exclude=/var/cache/*
  --exclude=/var/tmp/*
  --exclude=/var/log/journal/*

  # KEEP B's network & identity
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

  # *** CRITICAL: KEEP B's SSH + login intact ***
  --exclude=/etc/ssh/*
  --exclude=/etc/pam.d/*
  --exclude=/etc/passwd
  --exclude=/etc/shadow
  --exclude=/etc/group
)

# ---------- run rsync ----------
rsync "${RSYNC_BASE_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

echo
echo "=== Migration complete. ==="
echo "Tip: reboot the destination (${DEST_IP}) and verify services:"
echo "  docker ps   |   systemctl status mysql mariadb docker nginx"
