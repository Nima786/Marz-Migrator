#!/usr/bin/env bash
# Full rsync clone (same-arch)
# - Leaves Server B login untouched (excludes auth files and users' ~/.ssh)
# - Port-aware + robust password probe (password + keyboard-interactive)
# - Minimal Docker first-aid (no installs): try to start, clear stale pid/sock, ensure containerd
# - Logs post actions to /var/log/server-clone-post.log on Server B

set -euo pipefail
echo "=== Server Migration (rsync full clone: auth-safe) ==="

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

# Prereqs on Source (A)
confirm_install rsync rsync
confirm_install openssh-client ssh

# Inputs
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

# Refresh known_hosts for host:port
ssh-keygen -R "[${DEST_IP}]:${DEST_PORT}" >/dev/null 2>&1 || true
ssh-keyscan -p "${DEST_PORT}" -t ed25519 "${DEST_IP}" >> ~/.ssh/known_hosts 2>/dev/null || true

TMP_KEY_PATH=""
cleanup_key() {
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    shred -u "${TMP_KEY_PATH}" 2>/dev/null || rm -f "${TMP_KEY_PATH}" 2>/dev/null || true
  fi
}
trap cleanup_key EXIT

# Auth + robust probe
RSYNC_SSH=()
if [[ -n "${DEST_PASS}" ]]; then
  confirm_install sshpass sshpass
  echo "=== Checking SSH connectivity (password) ==="
  # Try password only first
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

# Rsync opts — NOTE: we keep ownership mapping by NAME (no --numeric-ids)
RSYNC_BASE_OPTS=(
  -aAXH
  --delete
  --whole-file
  --delay-updates
  "--info=stats2,progress2"
)

# Excludes: runtime, boot, network identity, SSH server, AUTH files, users' keys, optional firewall/caches
EXCLUDES=(
  --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found --exclude=/swapfile
  --exclude=/boot/*
  --exclude=/etc/network/* --exclude=/etc/netplan/* --exclude=/etc/hostname --exclude=/etc/hosts --exclude=/etc/resolv.conf --exclude=/etc/fstab
  --exclude=/etc/cloud/* --exclude=/var/lib/cloud/* --exclude=/etc/machine-id --exclude=/var/lib/dbus/machine-id
  --exclude=/etc/ssh/*
  --exclude=/etc/shadow --exclude=/etc/gshadow --exclude=/etc/passwd --exclude=/etc/group
  --exclude=/root/.ssh/* --exclude=/home/*/.ssh/*
  --exclude=/etc/ufw/** --exclude=/var/lib/ufw/** --exclude=/etc/iptables* --exclude=/etc/nftables.conf --exclude=/etc/firewalld/** --exclude=/etc/fail2ban/**
  --exclude=/var/cache/* --exclude=/var/tmp/* --exclude=/var/log/journal/*
)

# Run rsync
rsync "${RSYNC_BASE_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

# Post: minimal Docker first‑aid (no installs), then optional compose bring-up
read -r -d '' POST <<'EOF'
set -e
LOG=/var/log/server-clone-post.log
{
  echo "== $(date -Is) post-clone start =="

  systemctl daemon-reload || true

  # If docker.service exists, try to start as-is
  if systemctl list-unit-files --type=service | grep -q '^docker\.service'; then
    echo "[docker] starting as-is"
    mkdir -p /var/lib/docker
    systemctl enable --now docker 2>/dev/null || systemctl start docker || true
    if ! systemctl is-active --quiet docker; then
      echo "[docker] first-aid: clear stale pid/sock, ensure containerd"
      systemctl stop docker 2>/dev/null || true
      rm -f /var/run/docker.pid /var/run/docker.sock 2>/dev/null || true
      if systemctl list-unit-files --type=service | grep -q '^containerd\.service'; then
        systemctl enable --now containerd 2>/dev/null || systemctl restart containerd || true
      fi
      systemctl start docker || true
    fi
  else
    echo "[docker] docker.service not present; skipping (no installs performed)"
  fi

  # Compose bring-up only if docker is running AND compose plugin exists
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    for y in \
      /opt/*/docker-compose.yml \
      /srv/*/docker-compose.yml \
      /root/*/docker-compose.yml \
      /var/*/docker-compose.yml ; do
      [ -f "$y" ] || continue
      echo "compose up: $y"
      ( cd "$(dirname "$y")" && docker compose up -d ) || true
    done
  else
    echo "[compose] not available or docker not running; skipping"
  fi

  echo "== $(date -Is) post-clone end =="
} >>"$LOG" 2>&1
EOF

# Run remote post
if [[ -n "${DEST_PASS}" ]]; then
  sshpass -p "${DEST_PASS}" ssh -o StrictHostKeyChecking=accept-new "${DEST}" "${POST}"
else
  "${RSYNC_SSH[@]}" "${DEST}" "${POST}"
fi

echo
echo "=== Clone complete. Server B login stays unchanged. ==="
echo "If Marzban still says 'docker daemon not running', check /var/log/server-clone-post.log on B to see why docker refused to start (no installs were performed)."
