#!/usr/bin/env bash
# server-clone-rsync - The Ultimate "Intelligent Sync" Migration Script (v6 - FINAL)
# - METHODOLOGY: A professional-grade tool that prepares the destination, runs pre-flight
#   checks, surgically syncs application state, and provides final activation instructions.
# - FIX: Pre-flight disk space check is now robust and handles non-existent paths.
set -euo pipefail

echo "=== The Ultimate Docker Application Migration Script ==="

# ---- helpers ----
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

# ---- prereqs ----
confirm_install rsync rsync
confirm_install openssh-client ssh

# ---- inputs ----
read -rp "Destination server IP: " DEST_IP
read -rp "Destination SSH port (default: 22): " DEST_PORT; DEST_PORT=${DEST_PORT:-22}
read -rp "Destination username (default: root): " DEST_USER; DEST_USER=${USER:-root}
read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS; echo
DEST="${DEST_USER}@${DEST_IP}"

# ---- SSH setup ----
SSH_OPTS=(
  -p "${DEST_PORT}" -T -x
  -o Compression=no -o TCPKeepAlive=yes -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new -c aes128-gcm@openssh.com
)

TMP_KEY_PATH=""
cleanup_key() {
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    shred -u "${TMP_KEY_PATH}" 2>/dev/null || rm -f "${TMP_KEY_PATH}" 2>/dev/null || true
  fi
}
trap cleanup_key EXIT

# ---- Authentication setup ----
SSH_CMD=()
KEY_PATH=""
if [[ -n "${DEST_PASS}" ]]; then
  confirm_install sshpass sshpass
  SSH_CMD=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS[@]}")
else
  read -rp "SSH private key path (default: ~/.ssh/id_ed25519): " KEY_PATH
  KEY_PATH=${KEY_PATH:-~/.ssh/id_ed25519}
  if [[ "${KEY_PATH}" == *.ppk ]]; then
    confirm_install putty-tools puttygen
    TMP_KEY_PATH="/tmp/rsync_key_$$"
    echo "Converting PPK -> OpenSSH..."
    puttygen "${KEY_PATH}" -O private-openssh -o "${TMP_KEY_PATH}"
    chmod 600 "${TMP_KEY_PATH}"
    KEY_PATH="${TMP_KEY_PATH}"
  fi
  [[ -f "${KEY_PATH}" ]] || { echo "✗ SSH key not found: ${KEY_PATH}"; exit 1; }
  chmod 600 "${KEY_PATH}" 2>/dev/null || true
  SSH_CMD=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS[@]}")
fi

# ---- Remote execution function and connectivity check ----
run_remote() {
  "${SSH_CMD[@]}" "${DEST}" "bash -c '$1'"
}

echo "=== Testing SSH connectivity ==="
run_remote "echo '✓ SSH connection successful'" || { echo "✗ SSH connection failed"; exit 1; }

# ---- MENU: CHOOSE APPLICATION RECIPE ----
APP_STATE_PATHS=()
POST_CLONE_INSTRUCTIONS=""
echo "Please choose the application type to migrate:"
select app_type in "Marzban" "Generic Docker App (manual path entry)" "Exit"; do
  case $app_type in
    "Marzban")
      APP_STATE_PATHS=(
        "/opt/marzban"
        "/var/lib/marzban"
        "/var/lib/docker/volumes"
        "/usr/local/bin/marzban"
      )
      POST_CLONE_INSTRUCTIONS="Log into the destination server and run: \`marzban up\`"
      break
      ;;
    "Generic Docker App (manual path entry)")
      echo "Enter the absolute paths to sync, separated by spaces."
      echo "Example: /opt/myapp /var/lib/docker/volumes"
      read -rp "Paths to sync: " -a APP_STATE_PATHS
      POST_CLONE_INSTRUCTIONS="Log into the destination server, \`cd\` to your application's directory, and run: \`docker compose up -d\`"
      break
      ;;
    "Exit")
      exit 0
      ;;
    *)
      echo "Invalid option. Please try again."
      ;;
  esac
done

# ---- INTERACTIVE FIREWALL CLONING ----
FIREWALL_STATE_PATHS=(
  "/etc/ufw"
  "/etc/nftables.conf"
  "/etc/iptables"
  "/etc/firewalld"
)
read -rp "Clone firewall configuration? (Risky if IP-specific rules exist) [y/N]: " CLONE_FIREWALL
CLONE_FIREWALL=${CLONE_FIREWALL:-N}
if [[ "$CLONE_FIREWALL" =~ ^[Yy]$ ]]; then
  echo "INFO: Firewall state will be cloned."
  APP_STATE_PATHS+=("${FIREWALL_STATE_PATHS[@]}")
fi

# ---- PRE-FLIGHT CHECKS ----
echo "=== Running Pre-flight Checks ==="
# Check 1: Source Docker is running
if ! docker info &>/dev/null; then
  echo "✗ FATAL: Docker is not running on the source server. Please start it and try again."
  exit 1
fi
echo "✓ Source Docker is running."

# Check 2: Destination has enough disk space (ROBUST VERSION)
echo "Calculating required disk space..."
EXISTING_PATHS=()
for path in "${APP_STATE_PATHS[@]}"; do
    if [ -e "${path}" ]; then
        EXISTING_PATHS+=("${path}")
    fi
done

SOURCE_SIZE_KB=0
if [ ${#EXISTING_PATHS[@]} -gt 0 ]; then
    SOURCE_SIZE_KB=$(du -sk "${EXISTING_PATHS[@]}" | tail -n1 | awk '{print $1}')
fi

DEST_FREE_KB=$(run_remote "df -k /" | tail -n1 | awk '{print $4}')
REQUIRED_KB=$((SOURCE_SIZE_KB * 12 / 10)) # Add 20% buffer

if [[ "${REQUIRED_KB}" -gt "${DEST_FREE_KB}" ]]; then
  echo "✗ FATAL: Not enough disk space on destination."
  echo "  Required: ~$((REQUIRED_KB / 1024)) MB"
  echo "  Available: ~$((DEST_FREE_KB / 1024)) MB"
  exit 1
fi
echo "✓ Destination has enough disk space."

# ---- PHASE 1: PREPARE DESTINATION ----
echo "=== Phase 1: Preparing Destination Environment ==="
run_remote "$(cat <<'EOF'
set -e
echo "--- Stopping any running services..."
systemctl stop docker containerd &>/dev/null || true
echo "--- Installing a clean, native Docker engine..."
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
echo "✓ Docker environment is ready."
EOF
)"

# ---- PHASE 2: SURGICAL STATE SYNCHRONIZATION ----
echo "=== Phase 2: Synchronizing Application State (Safe Method) ==="
RSYNC_OPTS=(
  -aAXH --numeric-ids --delete --force --whole-file --delay-updates "--info=stats2,progress2"
)
RSYNC_SSH_CMD_STR=""
if [[ -n "${DEST_PASS}" ]]; then
  RSYNC_SSH_CMD_STR="sshpass -p '${DEST_PASS}' ssh $(printf '%q ' "${SSH_OPTS[@]}")"
else
  RSYNC_SSH_CMD_STR="ssh -i '${KEY_PATH}' -o IdentitiesOnly=yes $(printf '%q ' "${SSH_OPTS[@]}")"
fi

for path in "${EXISTING_PATHS[@]}"; do
  echo "--- Synchronizing ${path} ---"
  if [ -d "${path}" ]; then
    rsync "${RSYNC_OPTS[@]}" -e "${RSYNC_SSH_CMD_STR}" "${path}/" "${DEST}:${path}/"
  else
    rsync "${RSYNC_OPTS[@]}" -e "${RSYNC_SSH_CMD_STR}" "${path}" "${DEST}:${path}"
  fi
done

# ---- PHASE 3: FINAL INSTRUCTIONS ----
echo
echo "================================================="
echo "===             MIGRATION COMPLETE            ==="
echo "================================================="
echo
echo "The destination server is prepared and all data has been synchronized."
echo
echo "--- YOUR FINAL STEP (MANDATORY) ---"
echo
echo "1. Log into the destination server:"
echo "   ssh ${DEST_USER}@${DEST_IP} -p ${DEST_PORT}"
echo
echo "2. Check that the application's configuration file exists:"
echo "   ls -l /opt/marzban/docker-compose.yml"
echo
echo "3. Run the application's startup command:"
echo "   ${POST_CLONE_INSTRUCTIONS}"
echo
echo "This will pull fresh, non-corrupted images and start your panel with all your cloned data."
echo
