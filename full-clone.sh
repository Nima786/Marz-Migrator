#!/usr/bin/env bash
# Full rsync clone (same-arch) — auth-safe, port-aware, docker-safe excludes, no post steps
# - Leaves B's login untouched (no /etc/{shadow,passwd,group,gshadow}, no users' ~/.ssh)
# - Keeps B's SSH server config/host keys (/etc/ssh/*) and network identity
# - Skips docker/containerd state & docker unit overrides (common source of dockerd failures after clone)

set -euo pipefail
echo "=== Server Migration (rsync full clone: auth-safe, docker-safe) ==="

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

echo "=== Starting rsync to ${DEST} (port ${DEST_PORT}) ==="

# rsync options — owners map by NAME on B (no --numeric-ids)
RSYNC_BASE_OPTS=(
  -aAXH
  --delete
  --whole-file
  --delay-updates
  "--info=stats2,progress2"
)

# Excludes: runtime, boot, network identity, SSH server, AUTH files, users' keys, firewall noise,
#           and docker/containerd state + docker unit overrides (to prevent dockerd breakage)
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
  # optional: avoid copying firewall state
  --exclude=/etc/ufw/** --exclude=/var/lib/ufw/** --exclude=/etc/iptables* --exclude=/etc/nftables.conf --exclude=/etc/firewalld/** --exclude=/etc/fail2ban/**
  # reduce noise
  --exclude=/var/cache/* --exclude=/var/tmp/* --exclude=/var/log/journal/*

  # >>> Docker-safe excludes <<<
  --exclude=/var/lib/docker/**          # docker data/state
  --exclude=/var/lib/containerd/**      # containerd state
  --exclude=/etc/docker/**              # docker daemon config
  --exclude=/etc/systemd/system/docker.service.d/**  # docker unit overrides that often break on B
)

# Run rsync
rsync "${RSYNC_BASE_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

echo
echo "=== Clone complete. ==="
echo "Server B login remains unchanged. If Docker is installed on B, start it with:"
echo "  systemctl enable --now docker"
echo "Then bring up your stack (example Marzban):"
echo "  cd /opt/marzban && docker compose up -d"
