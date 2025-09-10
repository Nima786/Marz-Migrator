Marz-Migrator
=============

An intelligent, one-click migration script for Docker-based proxy panels like **Marzban** and **Marzneshin**. It safely clones your panel's complete state from one VPS to another with minimal downtime.

Instead of a risky, full-server clone, this tool uses a robust **"Surgical Sync & Rebuild"** methodology. It prepares the destination server with a native Docker engine, surgically syncs only the application's code and data volumes, and then provides a simple final command to rebuild the container state, guaranteeing a clean, non-corrupted, and perfectly functional migration.

It supports both **SSH key** and **password authentication** and automatically handles `.ppk` keys.

✨ Core Features
---------------

*   **Intelligent Migration:** Avoids OS corruption and kernel incompatibilities by respecting the destination server's environment.
*   **Application-Aware:** Includes "recipes" for Marzban and Marzneshin to sync the exact files and directories needed for a perfect clone.
*   **Safe By Design:** Includes pre-flight checks for Docker status and available disk space to prevent failed migrations.
*   **Optional Firewall Cloning:** Gives you the expert choice to clone your existing firewall state (UFW, nftables, etc.) for a true one-click setup.
*   **User-Friendly:** Supports SSH passwords or keys, with automatic `.ppk` conversion (requires `putty-tools`).

* * *

⚠️ Disclaimer
-------------

This script is a powerful tool designed to prepare a destination server and synchronize application data. While it is built with multiple safety checks, **always have a full backup of your source server** before proceeding. Data loss can occur due to network issues, misconfiguration, or other unforeseen problems.

Use this tool at your own risk. Double-check your server IPs and have a recovery plan before starting the migration.

* * *

🚀 Quick Start: The 3-Phase Migration
-------------------------------------

Run this single command on **Server A** (the source server):

    bash <(curl -s https://raw.githubusercontent.com/Nima786/Marz-Migrator/main/Marz-Migrator.sh)
    

The script will guide you through a 3-phase process:

#### Phase 1: Prepare Destination

The script connects to Server B and uses its native package manager to install a clean, compatible Docker engine. This completely avoids the kernel and library conflicts that cause traditional `rsync` clones to fail.

#### Phase 2: Surgical Sync

It then surgically copies only the essential state of your chosen application (e.g., Marzban's code, configs, and data volumes) from Server A to Server B.

#### Phase 3: Final Activation (Manual Step)

Once the sync is complete, the script will provide you with a single, simple command to run on Server B. This command tells the new Docker engine to pull fresh container images and start them with your cloned data, finalizing the migration.

* * *

📋 Requirements
---------------

*   Two Ubuntu/Debian servers (source and destination).
*   Root (or sudo) access on both servers.
*   `rsync` and `curl` installed on the source server.
*   `sshpass` installed on the source if using password authentication.
*   `putty-tools` installed on the source if using `.ppk` keys.

#### Quick Install on Source Server:

    apt update && apt install -y rsync curl sshpass putty-tools
    

* * *

📖 How It Works
---------------

1.  **Run the Script on Server A:** The script is initiated from the source server you want to clone.
2.  **Enter Destination Details:** Provide Server B's IP, SSH port, and credentials (password or SSH key path).
3.  **Choose a Recipe:** Select the application you are migrating (e.g., "Marzban"). This tells the script which specific directories to sync.
4.  **Choose to Clone Firewall:** Decide if you want to also clone your firewall rules. The default is "No" for maximum safety.
5.  **Automated Preparation & Sync:** The script runs its pre-flight checks, prepares Server B, and synchronizes the application data.
6.  **Manual Activation:** Log into Server B and run the final startup command provided by the script. This ensures you have the final control and can verify the result.

* * *

📜 License
----------

This project is licensed under the MIT License.
