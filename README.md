# ClusterCtrl-Time-Sync
A script that automatically updates &amp; syncs the time from the worker nodes to the master node using ClusterCtrl Hat v2.0

**Fully automated NTP synchronization for Raspberry Pi clusters using `clusterctrl Hat v2.0`**

> **Update's Worker Nodes & Sync's Time from all worker nodes to the master**

---

## Features

| Feature | Description |
|-------|-------------|
| **Auto Power-On** | If `p1` – `p4` is off, script will automatically turn them on  |
| **Config File** | `~/.cluster-sync.conf` → Stores previus sessions incase of errors |
| **SSH Key Deploy** | Auto Generate and Deploy SSH Key's to all nodes so they can semlesly talk without ever entering your password again.  |
| **Time Sync Verify** | `chronyc sources` Sync's node's time to master nodes time |
| **Log Rotation** | Keeps last 5 logs in `/tmp` |

---

# How to Use ClusterCtrl Time Sync

Follow these steps to get your Raspberry Pi cluster synchronized with Chrony NTP.

---

## Prerequisites

- Raspberry Pi cluster with `p1.local` to `p4.local` (ClusterCTRL setup)
- `clusterctrl` installed and configured for power control

### Steps

- Step 1: Clone Repository
```bash
git clone https://github.com/UntrustedTech/ClusterCtrl-Time-Sync.git
cd ClusterCtrl-Time-Sync
```

- Step 2: Make Script Executable
```bash
chmod +x cluster-sync.sh
```

- Step 3: Run the script
```bash
sudo ./cluster-sync.sh
```

### Example Output when Run
```bash
$ sudo ./cluster-sync.sh

ClusterCtrl Time Sync v1.1
────────────────────────────────────────
Author: UntrustedTech
Log: /tmp/cluster_sync_1110_0159.log

   Config loaded: /home/pi/.cluster-sync.conf
   Using saved credentials.

Select mode:
  [1] Automated
  [2] Assisted
Choice [1/2] (default: auto): 

Authentication:
  [1] Password
  [2] SSH Keys
Choice [1/2] (default: keys): 

Pre-flight Network Check
────────────────────────────────
   p1: Checkmark Online
   p2: Checkmark Online
   p3: Cross Offline → Powering on...   Waiting for p3...... Up
   p3: Checkmark Online (powered on)
   p4: Checkmark Online

   Some nodes required power-on. Proceeding...

Master Node
──────────────
   Update Done
   Upgrade Done
   Install chrony Done
   Config chrony Checkmark

SSH Key Setup (Master → Workers)
────────────────────────────────────
   Using existing key
   p1 is online
   Deploying to p1 Checkmark
   p2 is online
   Deploying to p2 Checkmark
   p3 is online
   Deploying to p3 Checkmark
   p4 is online
   Deploying to p4 Checkmark

   Keys deployed
   Continuing in 5s...
   → 5 → 4 → 3 → 2 → 1  

p1
──────
   p1 is online
   Update Done
   Upgrade Done
   Clean Done
   Reboot Done
   Waiting for p1..... Up
   Chrony Done
   Verifying time sync Checkmark
   p1 synced

p2
──────
   p2 is online
   Update Done
   Upgrade Done
   Clean Done
   Reboot Done
   Waiting for p2..... Up
   Chrony Done
   Verifying time sync Checkmark
   p2 synced

p3
──────
   p3 is online
   Update Done
   Upgrade Done
   Clean Done
   Reboot Done
   Waiting for p3..... Up
   Chrony Done
   Verifying time sync Checkmark
   p3 synced

p4
──────
   p4 is online
   Update Done
   Upgrade Done
   Clean Done
   Reboot Done
   Waiting for p4..... Up
   Chrony Done
   Verifying time sync Checkmark
   p4 synced

FINAL TASK REPORT
 Task                                                  Status
 ──────────────────────────────────────────────────  ────────────
 Power On p3                                           Checkmark Success
 SSH Key Generation                                    Circle Skipped
 SSH Deploy p1                                         Checkmark Success
 SSH Deploy p2                                         Checkmark Success
 SSH Deploy p3                                         Checkmark Success
 SSH Deploy p4                                         Checkmark Success
 Master: Update                                        Checkmark Success
 Master: config                                        Checkmark Success
 p1: Update                                            Checkmark Success
 p1: time verify                                       Checkmark Success
 p2: Update                                            Checkmark Success
 p2: time verify                                       Checkmark Success
 p3: Update                                            Checkmark Success
 p3: time verify                                       Checkmark Success
 p4: Update                                            Checkmark Success
 p4: time verify                                       Checkmark Success

Cluster fully synchronized!
```

### What Happens During Execution

The script will first ask you a few option

- Select Mode
Automated ( Runs through the whole program unassisted)

Assisted (Asks if you want to continue after each node is done)

- Authentication
Password ( continues script with password, will ask for password each time its run)

SSH Keys ( Generate and deploy ssh keys so the worker nodes can auto login )

Then it makes sure all nodes are online, if they are not the script will automatically turn them on

Now it will update the master node, and set Chrony up and ssh if that option was chosen

after that it starts to ssh into each worker node, updates them, installs and syncs chrony, makes sure chrony is sinced to master node. and proceeds to the next nodes untill completed

And thats it! Enjoy your freshly backed clustered pi!
