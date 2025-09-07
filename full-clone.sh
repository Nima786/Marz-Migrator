#!/usr/bin/env bash
# full-clone.sh — Full rsync clone (same-arch) with AUTH-SAFE excludes
# - Copies the whole system except runtime mounts, network identity, SSH server config,
#   and AUTH files (so destination login stays exactly as the provider set it)
# - Supports password OR SSH key (auto-convert .ppk to OpenSSH)
# - ShellCheck-friendly
set -euo pipefail

echo "=== Server Migration (rsync full clone: auth-safe) ==="

# ---- helpers ----
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

# ---- prereqs ----
confirm_install rsync rsync
confirm_install openssh-client ssh

# ---- inputs ----
read -rp "Destination server IP: " DEST_IP
read -rp "Destination username (default: root): " DEST_USER
DEST_USER=${DEST_USER:-root}
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS
echo
DEST="${DEST_USER}@${DEST_IP}"

# ---- SSH setup ----
SSH_OPTS=(
  -T -x
  -o Compression=no
  -o TCPKeepAlive=yes
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
  -c aes128-gcm@openssh.com
)

TMP_KEY_PATH=""

cleanup_key() {
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    # best-effort secure delete; ignore errors on systems without shred
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
    echo "Converting PPK -> OpenSSH…"
    puttygen "${KEY_PATH}" -O private-openssh -o "${TMP_KEY_PATH}"
    chmod 600 "${TMP_KEY_PATH}"
    KEY_PATH="${TMP_KEY_PATH}"
  fi
  if [[ ! -f "${KEY_PATH}" ]]; then
    echo "SSH key not found: ${KEY_PATH}"
    exit 1
  fi
  chmod 600 "${KEY_PATH}" || true
  RSYNC_SSH=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS[@]}")
fi

# avoid stale known_hosts when B got rebuilt on same IP
ssh-keygen -R "${DEST_IP}" >/dev/null 2>&1 || true
ssh-keyscan -t ed25519 "${DEST_IP}" >> ~/.ssh/known_hosts 2>/dev/null || true

# ---- connectivity check ----
echo "=== Checking SSH connectivity ==="
if [[ "${AUTH_MODE}" == "password" ]]; then
  if sshpass -p "${DEST_PASS}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${DEST}" "echo ok" 2>/dev/null | grep -q ok; then
    echo "✓ SSH reachable with password."
  else
    echo "✗ Could not log in with the provided password."
    exit 1
  fi
else
  if "${RSYNC_SSH[@]}" -o BatchMode=yes -o ConnectTimeout=5 "${DEST}" true >/dev/null 2>&1; then
    echo "✓ SSH reachable with key."
  else
    echo "✗ SSH key login failed (non-interactive)."
    exit 1
  fi
fi

# --- Pre-emptive Target Server Safeguards ---
echo "=== Applying pre-clone safeguards on ${DEST_IP} ==="
"${RSYNC_SSH[@]}" "${DEST}" "system
