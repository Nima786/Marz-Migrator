#!/usr/bin/env bash
# verify-clone.sh — Verify Server B after rsync clone
set -euo pipefail

# -------- UI helpers --------
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; CYA=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok(){ echo "${GRN}✔${RST} $*"; }
warn(){ echo "${YLW}⚠${RST} $*"; }
err(){ echo "${RED}✖${RST} $*"; }

echo "=== Post-Migration Verification ==="
read -rp "Destination server IP: " DEST_IP
read -rp "Destination username (default: root): " DEST_USER
DEST_USER=${DEST_USER:-root}

read -srp "Password for ${DEST_USER}@${DEST_IP} (leave empty to use SSH key): " DEST_PASS
echo

SSH_OPTS=(
  -T
  -x
  -o Compression=no
  -o TCPKeepAlive=yes
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
  -c aes128-gcm@openssh.com
)

RSYNC_SSH=()  # generic SSH runner
TMP_KEY_PATH=""

cleanup_key(){
  if [[ -n "${TMP_KEY_PATH}" && -f "${TMP_KEY_PATH}" ]]; then
    shred -u "${TMP_KEY_PATH}" 2>/dev/null || true
  fi
}
trap cleanup_key EXIT

if [[ -n "${DEST_PASS}" ]]; then
  if command -v sshpass >/dev/null 2>&1; then
    RSYNC_SSH=(sshpass -p "${DEST_PASS}" ssh "${SSH_OPTS[@]}")
  else
    warn "sshpass not found; SSH may prompt for password interactively."
    RSYNC_SSH=(ssh "${SSH_OPTS[@]}")
  fi
else
  read -rp "SSH private key path (default: ~/.ssh/id_ed25519): " KEY_PATH
  KEY_PATH=${KEY_PATH:-~/.ssh/id_ed25519}
  if [[ "${KEY_PATH}" == *.ppk ]]; then
    if command -v puttygen >/dev/null 2>&1; then
      TMP_KEY_PATH="/root/verify_key_$$"
      echo "Converting PPK -> OpenSSH with puttygen..."
      puttygen "${KEY_PATH}" -O private-openssh -o "${TMP_KEY_PATH}"
      chmod 600 "${TMP_KEY_PATH}"; KEY_PATH="${TMP_KEY_PATH}"
    else
      err "PPK given but puttygen is not installed. Install: apt update && apt install -y putty-tools"
      exit 1
    fi
  fi
  [[ -f "${KEY_PATH}" ]] || { err "SSH key not found at ${KEY_PATH}"; exit 1; }
  chmod 600 "${KEY_PATH}" || true
  RSYNC_SSH=(ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes "${SSH_OPTS[@]}")
fi

DEST="${DEST_USER}@${DEST_IP}"

echo
echo "${CYA}${BLD}1) Reachability & identity${RST}"
if "${RSYNC_SSH[@]}" -o BatchMode=yes -o ConnectTimeout=5 "${DEST}" true 2>/dev/null; then
  ok "SSH reachable."
else
  warn "SSH reachability check failed or needs interaction; continuing..."
fi
# Use double quotes so shellcheck is happy; expansions happen on the remote.
HOST_INFO=$("${RSYNC_SSH[@]}" "${DEST}" "echo -n \"\$(hostnamectl --static 2>/dev/null || hostname) | \"; uname -r 2>/dev/null || true" || true)
echo "Server B: ${HOST_INFO}"

echo
echo "${CYA}${BLD}2) Systemd health on Server B${RST}"
FAILED=$("${RSYNC_SSH[@]}" "${DEST}" 'systemctl --failed --no-legend 2>/dev/null | wc -l' || echo "0")
if [[ "${FAILED}" == "0" ]]; then
  ok "No failed systemd units."
else
  warn "${FAILED} failed unit(s) found:"
  "${RSYNC_SSH[@]}" "${DEST}" 'systemctl --failed --no-pager || true'
fi

echo
echo "${CYA}${BLD}3) Common services on Server B${RST}"
# Docker
if "${RSYNC_SSH[@]}" "${DEST}" 'command -v docker >/dev/null 2>&1'; then
  ok "Docker installed."
  "${RSYNC_SSH[@]}" "${DEST}" 'docker ps -a --format "table {{.Names}}\t{{.Status}}" || true'
else
  warn "Docker not found (skipping)."
fi
# MySQL/MariaDB
if "${RSYNC_SSH[@]}" "${DEST}" 'command -v mysql >/dev/null 2>&1'; then
  ok "MySQL/MariaDB present."
  "${RSYNC_SSH[@]}" "${DEST}" 'systemctl status mysql mariadb 2>/dev/null | sed -n "1,5p" || true'
  "${RSYNC_SSH[@]}" "${DEST}" 'mysql -N -e "SHOW DATABASES;" 2>/dev/null | wc -l | xargs echo "DB count:" || true'
else
  warn "mysql client not found (skipping DB list)."
fi
# Web servers
if "${RSYNC_SSH[@]}" "${DEST}" 'systemctl is-active nginx >/dev/null 2>&1'; then
  ok "nginx is active."
else
  "${RSYNC_SSH[@]}" "${DEST}" 'systemctl status nginx 2>/dev/null | sed -n "1,5p" || true'
fi
if "${RSYNC_SSH[@]}" "${DEST}" 'systemctl is-active apache2 >/dev/null 2>&1'; then
  ok "apache2 is active."
else
  "${RSYNC_SSH[@]}" "${DEST}" 'systemctl status apache2 2>/dev/null | sed -n "1,5p" || true'
fi

echo
echo "${CYA}${BLD}4) Cross-check directory sizes (A vs B)${RST}"
DIRS=(/etc /home /var/www /var/lib/docker /var/lib/mysql)
printf "%-20s %15s %15s %9s\n" "Path" "A (bytes)" "B (bytes)" "Δ%"
for d in "${DIRS[@]}"; do
  SA=$(du -sb "$d" 2>/dev/null | awk '{print $1}'); SA=${SA:-0}
  SB=$("${RSYNC_SSH[@]}" "${DEST}" "du -sb $d 2>/dev/null | awk '{print \$1}'" || true); SB=${SB:-0}
  if [[ "$SA" == "0" && "$SB" == "0" ]]; then
    printf "%-20s %15s %15s %9s\n" "$d" "-" "-" "-"
    continue
  fi
  if [[ "$SA" -gt 0 ]]; then
    PCT=$(awk -v a="$SA" -v b="$SB" 'BEGIN{ if(a==0){print 0}else{printf "%.1f", ((b-a)/a)*100} }')
  else
    PCT="∞"
  fi
  printf "%-20s %15s %15s %9s\n" "$d" "$SA" "$SB" "$PCT"
done

echo
echo "${CYA}${BLD}5) Spot-check a few binaries match (md5)${RST}"
BINARIES=(/bin/bash /usr/bin/rsync /usr/sbin/cron)
for b in "${BINARIES[@]}"; do
  if [[ -r "$b" ]]; then
    A_MD5=$(md5sum "$b" 2>/dev/null | awk '{print $1}')
  else
    A_MD5="NA"
  fi
  B_MD5=$("${RSYNC_SSH[@]}" "${DEST}" "md5sum $b 2>/dev/null | awk '{print \$1}'" || true)
  [[ -z "$B_MD5" ]] && B_MD5="NA"
  STATUS=$([[ "$A_MD5" == "$B_MD5" && "$A_MD5" != "NA" ]] && echo "${GRN}match${RST}" || echo "${YLW}check${RST}")
  printf "%-20s  A:%-34s  B:%-34s  %s\n" "$b" "$A_MD5" "$B_MD5" "$STATUS"
done

echo
echo "${CYA}${BLD}6) Kernel & reboot advice${RST}"
"${RSYNC_SSH[@]}" "${DEST}" 'echo -n "Kernel: "; uname -r'
echo "If services look good, update DNS or clients to Server B’s IP."
echo
ok "Verification pass complete."
