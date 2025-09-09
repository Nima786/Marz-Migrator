#!/usr/bin/env bash
# full-clone.sh — Full rsync clone (same-arch) with conditional Docker warm-up
# Works for Marzban, CyberPanel, and other apps that depend on Docker/systemd.
set -euo pipefail

echo "=== Server Migration (rsync full clone) ==="

# --- helpers ---
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

confirm_install rsync rsync
confirm_install openssh-client ssh

# --- inputs ---
read -rp "Destination server IP: " DEST_IP
read -rp "Destination username (default: root): " DEST_USER
DEST_USER=${DEST_USER:-root}
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS
echo
DEST="${DEST_USER}@${DEST_IP}"

# --- ssh setup ---
SSH_OPTS=(-T -x -o Compression=no -o TCPKeepAlive=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new -c aes128-gcm@openssh.com)

TMP_KEY_PATH=""
cleanup_key() {
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    shred -u "${TMP_KEY_PATH}" 2>/dev/null || rm -f "${TMP_KEY_PATH}" 2>/dev/null || true
  fi
}
trap cleanup_key EXIT

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
    echo "Converting PPK -> OpenSSH key…"
    puttygen "${KEY_PATH}" -O private-openssh -o "${TMP_KEY_PATH}"
    chmod 600 "${TMP_KEY_PATH}"
    KEY_PATH="${TMP_KEY_PATH}"
  fi
  [[ -f "${KEY_PATH}" ]] || { echo "SSH key not found: ${KEY_PATH}"; exit 1; }
  chmod 600 "${KEY_PATH}" || true
  RSYNC_SSH=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS[@]}")
fi

# refresh known_hosts
ssh-keygen -R "${DEST_IP}" >/dev/null 2>&1 || true
ssh-keyscan -t ed25519 "${DEST_IP}" >> ~/.ssh/known_hosts 2>/dev/null || true

# connectivity check
echo "=== Checking SSH connectivity ==="
if [[ "${AUTH_MODE}" == "password" ]]; then
  if sshpass -p "${DEST_PASS}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${DEST}" "echo ok" 2>/dev/null | grep -q ok; then
    echo "✓ SSH reachable with password."
  else
    echo "✗ Could not log in with the provided password."; exit 1
  fi
else
  if "${RSYNC_SSH[@]}" -o BatchMode=yes -o ConnectTimeout=5 "${DEST}" true >/dev/null 2>&1; then
    echo "✓ SSH reachable with key."
  else
    echo "✗ SSH key login failed (non-interactive)."; exit 1
  fi
fi

# --- rsync options ---
RSYNC_BASE_OPTS=(-aAXH --numeric-ids --delete --whole-file --delay-updates "--info=stats2,progress2")
EXCLUDES=(
  --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found --exclude=/swapfile
  --exclude=/boot/*
  --exclude=/etc/network/* --exclude=/etc/netplan/* --exclude=/etc/hostname --exclude=/etc/hosts --exclude=/etc/resolv.conf --exclude=/etc/fstab
  --exclude=/etc/cloud/* --exclude=/var/lib/cloud/* --exclude=/etc/machine-id --exclude=/var/lib/dbus/machine-id
  --exclude=/etc/ssh/*
)

echo "=== Starting rsync full clone to ${DEST} ==="
rsync "${RSYNC_BASE_OPTS[@]}" -e "$(printf '%q ' "${RSYNC_SSH[@]}")" \
  "${EXCLUDES[@]}" \
  / "${DEST}":/

# --- post-clone: conditional Docker + compose bring-up (logged) ---
read -r -d '' POST <<'EOF'
set -e
LOG=/var/log/server-clone-post.log
{
  echo "== $(date -Is) : Post-clone start =="

  systemctl daemon-reload || true

  # helper to check docker active
  is_docker_active() { systemctl is-active --quiet docker; }

  echo "[1] Try to start docker as-is"
  mkdir -p /var/lib/docker
  systemctl enable --now docker 2>/dev/null || systemctl start docker || true
  if is_docker_active; then echo "Docker is running (as-is)"; exit 0; fi

  echo "[2] First-aid: stop docker, clear stale PID/socket, ensure containerd"
  systemctl stop docker 2>/dev/null || true
  rm -f /var/run/docker.pid /var/run/docker.sock 2>/dev/null || true
  systemctl enable --now containerd 2>/dev/null || systemctl restart containerd || true
  modprobe overlay 2>/dev/null || true
  systemctl start docker || true
  if is_docker_active; then echo "Docker started after first-aid"; exit 0; fi

  echo "[3] Second-aid: clear stale docker network db"
  rm -f /var/lib/docker/network/files/local-kv.db 2>/dev/null || true
  systemctl restart docker || true
  if is_docker_active; then echo "Docker started after clearing network DB"; exit 0; fi

  echo "[4] Last resort: temporarily back up daemon.json if present"
  if [ -f /etc/docker/daemon.json ]; then
    mv -v /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)" || true
    systemctl restart docker || true
  fi
  if is_docker_active; then echo "Docker started after daemon.json backup"; fi

  # Continue either way; compose bring-up will succeed only if docker is running
  if is_docker_active; then
    echo "[Compose] Checking for docker-compose stacks"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      for y in \
        /opt/*/docker-compose.yml \
        /srv/*/docker-compose.yml \
        /root/*/docker-compose.yml \
        /var/*/docker-compose.yml ; do
        if [ -f "$y" ]; then
          echo "Bringing up stack at $y"
          ( cd "$(dirname "$y")" && docker compose up -d ) || true
        fi
      done
    else
      echo "docker compose plugin not present; skipping compose bring-up"
    fi
  else
    echo "Docker not running after all attempts; skipping compose bring-up"
  fi

  echo "== $(date -Is) : Post-clone end =="
} >>"$LOG" 2>&1
EOF

if [[ "${AUTH_MODE}" == "password" ]]; then
  sshpass -p "${DEST_PASS}" ssh -o StrictHostKeyChecking=accept-new "${DEST}" "${POST}"
else
  "${RSYNC_SSH[@]}" "${DEST}" "${POST}"
fi

echo "=== Clone complete. Check /var/log/server-clone-post.log on ${DEST_IP} for details. ==="
echo "Reboot is optional; if Marzban/CyberPanel use Docker, they should start once Docker is active."
