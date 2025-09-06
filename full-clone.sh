#!/usr/bin/env bash
# full-clone.sh — Full rsync clone (same-architecture) with password login preserved
# - Copies the whole system except networking/identity and /etc/ssh/*
# - Optional: enforce PasswordAuthentication on destination after clone
# - Optimized for >=1Gbps (no compression, whole-file, fast cipher)
set -euo pipefail

echo "=== Server Migration (rsync full clone: same-architecture) ==="

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
read -rp "After clone, enforce password login on destination? [Y/n]: " ENF
ENF=${ENF:-Y}

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
AUTH_MODE="password"
if [[ -n "${DEST_PASS}" ]]; then
  confirm_install sshpass sshpass
  RSYNC_SSH=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS[@]}")
else
  AUTH_MODE="key"
  read -rp "SSH private key path (default: ~/.ssh/id_ed25519): " KEY_PATH
  KEY_PATH=${KEY_PATH:-~/.ssh/id_ed25519}
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
fi

# ---------- avoid stale known_hosts host key ----------
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

echo "=== Starting rsync full clone to ${DEST} ==="
echo "Copies almost everything, but keeps destination networking/identity and SSH server config."
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

# ---------- Excludes (minimal; keep B's network/identity and SSH server config) ----------
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

  # keep destination’s own networking & identity
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

  # keep destination’s SSH *server* config & host keys
  --exclude=/etc/ssh/*
)

# ---------- run rsync ----------
rsync "${RSYNC_BASE_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

echo
echo "=== Clone complete. ==="

# ---------- optionally enforce password login on destination ----------
if [[ "${ENF}" =~ ^[Yy]$ ]]; then
  echo "=== Enforcing password login on destination (safe override) ==="
  # Create drop-in override without touching existing files
  ENFORCE_CMD=$'set -e\n'\
'install -d -m 0755 /etc/ssh/sshd_config.d\n'\
'printf "PasswordAuthentication yes\\nKbdInteractiveAuthentication yes\\nUsePAM yes\\nPermitRootLogin yes\\nAuthorizedKeysFile .ssh/authorized_keys\\n" > /etc/ssh/sshd_config.d/90-password-override.conf\n'\
'sshd -t\n'\
'systemctl restart ssh || systemctl restart sshd || true\n'\
'echo "Password login override applied."'
  if [[ "${AUTH_MODE}" == "password" ]]; then
    sshpass -p "${DEST_PASS}" ssh -o StrictHostKeyChecking=accept-new "${DEST}" "${ENFORCE_CMD}"
  else
    "${RSYNC_SSH[@]}" "${DEST}" "${ENFORCE_CMD}"
  fi
  echo "✓ Destination configured to allow password login."
else
  echo "Skipping password login enforcement as requested."
fi

echo
echo "Done. You can now reboot ${DEST_IP} and verify services:"
echo "  docker ps   |   systemctl status mysql mariadb docker nginx"
