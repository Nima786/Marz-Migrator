# server-clone-rsync

A simple and optimized rsync-based tool to **Marz-Migrator** (files, configs, Docker, databases) from one VPS to another with **minimal downtime**.  
It supports **SSH key or password authentication**, automatically handles `.ppk` keys.

## ✨ Features
- Clone entire server **A → B** with one command.
- Works with **SSH password or key-based authentication**.
- **Safe excludes**: keeps Server B’s networking, hostname, and SSH host keys intact.
- Optimized for **1Gbps+ links** (fast cipher, no compression).
- Includes **verify script** to check if Server B is healthy after migration.
- Supports `.ppk` keys (auto-converts to OpenSSH format if `puttygen` is installed).

⚠️ Disclaimer
-------------

This script directly clones one server onto another using `rsync`. While it has been tested, **always create a full backup of your source server** before running it. If anything goes wrong (network issues, hardware failure, or user mistakes), you can lose data without a backup.

Use this tool at your own risk — double-check that you have recovery options before proceeding.
## 🚀 Quick Start
Run this on **Server A** (the source server):

```bash
bash <(curl -s https://raw.githubusercontent.com/Nima786/Marz-Migrator/main/full-clone.sh)
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
📖 How to use this script
-------------------------

1.  **Prepare your servers**
    *   Make sure you can SSH into both Server A (source) and Server B (destination).
    *   If you use SSH keys:
        *   Upload **Server B’s private key** file (e.g. `private-key.ppk` or `id_ed25519`) into the **root directory of Server A**.
        *   This allows the script to authenticate to Server B during the clone.
2.  **On Server A (the source server)**, run the clone script:
    
        bash <(curl -s https://raw.githubusercontent.com/Nima786/server-clone-rsync/main/full-clone.sh)
    
3.  The script will ask for:
    *   Destination server **IP**
    *   Destination **username** (default: `root`)
    *   Either:
        *   **Password** (if you use password auth), or
        *   Leave blank → provide the path to the **SSH private key** you uploaded (e.g. `/root/private-key.ppk`)
4.  The script will then **rsync all data from Server A → Server B**, while skipping:
    *   Networking configs (to keep B’s IP/hostname working)
    *   Machine identity files
    *   Temporary/system files
    

## ⚠️ Notes
- This tool is designed for **same-architecture clones (x86→x86, arm→arm)**.  
  For cross-architecture migrations, exclude system binaries (`/usr`, `/lib`) and reinstall packages natively on Server B.
- Always test services on Server B before switching DNS or clients.
- Keep Server A as fallback for a few days after migration.

## 📜 License
This project is licensed under the MIT License.
