#!/usr/bin/env bash
# full-clone.sh — Clone Server A -> Server B with rsync
# Safe: reads from this server (A), writes to destination (B).
# Tuned for >=1Gbps links (no compression, whole-file, fast cipher).
set -euo pipefail

echo "=== Server Migration (rsync clone) ==="

read -rp "Destination server IP: " DEST_IP
read -rp "Destination username (default: root): " DEST_USER
DEST_USER=${DEST_USER:-root}

# Ask for password first. If provided -> password mode. If empty -> key mode.
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS
echo

# Common rsync + ssh options
RSYNC_BASE_OPTS=(
  -aAXH
  --numeric-ids
  --delete
  --whole-file
  --delay-updates
  --info=stats2,progress2
)
SSH_OPTS=(-T -x
  -o Compression=no
  -o TCPKeepAlive=yes
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
  -c aes128-gcm@openssh.com
)

# Excludes: keep B's network/identity & skip junk
EXCLUDES=(
  --exclude=/dev/*
  --exclude=/proc/*
  --exclude=/sys/*
  --exclude=/tmp/*
  --exclude=/run/*
  --exclude=/mnt/*
  --exclude=/media/*
  --exclude=/lost+found
  --exclude=/boot/*
  --exclude=/lib/modules/*
  --exclude=/lib/firmware/*
  --exclude=/swapfile
  --exclude=/var/cache/apt/archives/*
  --exclude=/var/cache/man/*
  --exclude=/var/tmp/*
  --exclude=/var/log/journal/*
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
  --exclude=/etc/ssh/ssh_host_*
)

DEST="${DEST_USER}@${DEST_IP}"

cleanup_key() {
  [[ -n "${TMP_KEY_PATH:-}" && -f "${TMP_KEY_PATH}" ]] && shred -u "${TMP_KEY_PATH}" 2>/dev/null || true
}
trap cleanup_key EXIT

build_ssh_cmd() {
  # Build RSYNC_SSH array into global var
  if [[ -n "${DEST_PASS}" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
      RSYNC_SSH=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS[@]}")
    else
      echo "Note: sshpass not found. rsync/ssh may prompt interactively for the password."
      RSYNC_SSH=(ssh "${SSH_OPTS[@]}")
    fi
  else
    # Key-based auth
    read -rp "SSH private key path (default: ~/.ssh/id_ed25519): " KEY_PATH
    KEY_PATH=${KEY_PATH:-~/.ssh/id_ed25519}

    # If a .ppk is provided, try to convert it (requires puttygen)
    if [[ "${KEY_PATH}" == *.ppk ]]; then
      if command -v puttygen >/dev/null 2>&1; then
        TMP_KEY_PATH="/root/rsync_key_$$"
        echo "Converting PPK -> OpenSSH key with puttygen..."
        puttygen "${KEY_PATH}" -O private-openssh -o "${TMP_KEY_PATH}"
        chmod 600 "${TMP_KEY_PATH}"
        KEY_PATH="${TMP_KEY_PATH}"
      else
        echo "Error: '${KEY_PATH}' is a .ppk file and puttygen is not installed."
        echo "Install it with:  apt update && apt install -y putty-tools"
        exit 1
      fi
    fi

    if [[ ! -f "${KEY_PATH}" ]]; then
      echo "Error: SSH key not found at '${KEY_PATH}'."
      exit 1
    fi
    chmod 600 "${KEY_PATH}" || true
    RSYNC_SSH=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS[@]}")
  fi
}

# Build SSH command based on auth choice
build_ssh_cmd

echo "=== Starting rsync clone to ${DEST} ==="
echo "This will copy the entire filesystem except networking/identity/boot junk."
echo "Source: /   ->   Destination: ${DEST}:/"
echo

# Optional reachability probe (non-fatal)
set +e
"${RSYNC_SSH[@]}" -o BatchMode=yes -o ConnectTimeout=5 "${DEST}" true >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
  echo "Warning: quick SSH reachability check failed or requires interaction; proceeding with rsync..."
fi
set -e

# Run rsync (no --inplace; uses --delay-updates to avoid 'Text file busy')
rsync "${RSYNC_BASE_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

echo
echo "=== Migration complete. ==="
echo "You can now reboot the destination (${DEST_IP}) and verify services:"
echo "  docker ps   |   systemctl status mysql mariadb docker nginx"
