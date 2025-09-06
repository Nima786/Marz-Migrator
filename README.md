# server-clone-rsync

A simple and optimized rsync-based tool to **fully clone Ubuntu servers** (files, configs, Docker, databases) from one VPS to another with **minimal downtime**.  
It supports **SSH key or password authentication**, automatically handles `.ppk` keys, and includes a verification script.

## ✨ Features
- Clone entire server **A → B** with one command.
- Works with **SSH password or key-based authentication**.
- **Safe excludes**: keeps Server B’s networking, hostname, and SSH host keys intact.
- Optimized for **1Gbps+ links** (fast cipher, no compression).
- Includes **verify script** to check if Server B is healthy after migration.
- Supports `.ppk` keys (auto-converts to OpenSSH format if `puttygen` is installed).

## 🚀 Quick Start
Run this on **Server A** (the source server):

```bash
bash <(curl -s https://raw.githubusercontent.com/Nima786/server-clone-rsync/main/full-clone.sh)
```

The script will:
1. Ask for **Server B IP** and **username**.
2. Ask for **password** (if using password auth). If left blank, it will ask for **SSH key path** (default: `~/.ssh/id_ed25519`).
3. Clone the entire filesystem from Server A → Server B while keeping B’s network/identity intact.

After migration, you can verify Server B with:

```bash
bash <(curl -s https://raw.githubusercontent.com/Nima786/server-clone-rsync/main/verify-clone.sh)
```

## 📋 Requirements
- Ubuntu/Debian source and destination servers.
- Root (or sudo) access on both servers.
- `rsync` installed on both servers.
- `putty-tools` installed if you want to use `.ppk` keys.

Install requirements:
```bash
apt update && apt install -y rsync putty-tools sshpass
```

## ⚠️ Notes
- This tool is designed for **same-architecture clones (x86→x86, arm→arm)**.  
  For cross-architecture migrations, exclude system binaries (`/usr`, `/lib`) and reinstall packages natively on Server B.
- Always test services on Server B before switching DNS or clients.
- Keep Server A as fallback for a few days after migration.

## 📜 License
This project is licensed under the MIT License.
