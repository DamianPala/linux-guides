# Install Proxmox VE on a Hetzner Dedicated Server

Proxmox VE is an open-source server virtualization platform built on Debian. It manages KVM virtual machines and LXC containers through a web interface. This guide covers the full setup on a Hetzner dedicated server with two NVMe drives: base Debian via `installimage`, Proxmox on top, and a ZFS mirror for VM storage.

## Why this approach

Hetzner dedicated servers don't support booting from custom ISOs directly. The standard approach is to use Hetzner's `installimage` tool from rescue mode to install Debian, then add Proxmox packages on top. This gives you a clean Debian base with mdadm software RAID for the root filesystem and ZFS for VM data — a solid hybrid layout that's easy to migrate.

## End result

```
nvme0n1 / nvme1n1
├─ p1  → md0  (RAID1)  →  /boot   ext4    1 GB
├─ p2  → md1  (RAID1)  →  /       ext4   48 GB
├─ p3  → md2  (RAID1)  →  swap           16 GB
├─ p4  → extended partition container (created by installimage)
└─ p5  → ZFS mirror    →  "storage"    remaining space
```

- Root on mdadm RAID1 — `installimage` handles this natively
- VM storage on ZFS mirror — snapshots, compression, flexible provisioning
- Proxmox VE with web GUI on port 8006

**Why ZFS for VM storage?** ZFS snapshots are nearly free — they use copy-on-write and don't degrade I/O performance. This matters when you run snapshot-based backups on all VMs (e.g., via Proxmox Backup Server). The alternative, LVM-thin, has cheaper initial setup but its snapshots cause measurable performance degradation under write-heavy workloads.

## Prerequisites

- Hetzner dedicated server with 2x NVMe drives
- Access to Hetzner Robot panel (to boot into rescue mode)
- At least 64 GB RAM recommended (for VMs + ZFS ARC)

## Step 1 — Boot into rescue mode

1. Log into Hetzner Robot panel
2. Go to your server → **Rescue** tab
3. Activate rescue system (Linux x86_64)
4. Note the root password or add your SSH key
5. Reboot the server (Robot → Reset tab)
6. SSH into the rescue system

## Step 2 — Run installimage

Start the installer:

```bash
installimage
```

Select the **latest stable Debian** as the image — Proxmox always tracks the current Debian stable release. In the config editor, set the following:

```
DRIVE1  /dev/nvme0n1
DRIVE2  /dev/nvme1n1

SWRAID  1
SWRAIDLEVEL  1

HOSTNAME  your-hostname

PART  /boot  ext4  1G
PART  /      ext4  48G
PART  swap   swap  16G
PART  /data  ext4  all
```

**About HOSTNAME:** A short hostname like `my-pve` works fine. The Proxmox wiki recommends an FQDN (e.g., `pve.example.com`) but it's not strictly required — as long as `hostname --ip-address` resolves to the server's real IP (not 127.0.0.1), PVE will work.

**About the layout:** The `/data` partition is temporary — we'll convert it to a ZFS mirror later. We use ext4 here because `installimage` doesn't support ZFS. The 48 GB root is generous for PVE itself (packages, logs, ISO cache). 16 GB swap provides a safety net for memory pressure. Note that `installimage` creates an extended partition (p4) to hold the last logical partition (p5) — this is normal MBR behavior.

Save and confirm. Wait for the installation to complete, then reboot:

```bash
reboot
```

## Step 3 — Verify the base system

After reboot, SSH back in and check the disk layout:

```bash
lsblk
```

You should see `md0` through `md3` as RAID1 arrays across both NVMe drives, with `/data` mounted on `md3`.

## Step 4 — Install Proxmox VE

Follow the official Proxmox wiki guide for installing PVE on top of Debian. Proxmox publishes a dedicated page for each Debian release:

- **Debian 13 (Trixie) / PVE 9:** https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie
- For newer versions, check the Proxmox wiki for the equivalent "Install Proxmox VE on Debian NN" page

The wiki walks you through: adding the GPG key and repository, installing the Proxmox kernel (with a reboot), and then the `proxmox-ve` meta-package.

**Tips for this step:**

- When **postfix** asks for configuration, select **local only** unless you need email relay
- After installing the Proxmox kernel and rebooting, **remove the stock Debian kernel** as the wiki instructs
- **Remove `os-prober`** — unnecessary on a headless server and can interfere with GRUB
- If you see **perl locale warnings** after install, run `dpkg-reconfigure locales` and generate the locales you need (e.g., `en_US.UTF-8`). Common on Hetzner where the base image ships with minimal locale config

### Verification

```bash
pveversion
```

You should see `pve-manager/X.Y.Z` running a `-pve` kernel.

### Disable enterprise repo (no subscription)

PVE adds an enterprise repo by default. Without a subscription key, `apt update` will error. Comment it out (don't delete — PVE may recreate it on upgrades):

```bash
sed -i '/^[^#]/ s/^/# /' /etc/apt/sources.list.d/pve-enterprise.sources
```

**About the filename:** PVE 9+ uses the deb822 `.sources` format. If you're on an older PVE, the file may be named `pve-enterprise.list` instead — check with `ls /etc/apt/sources.list.d/pve-*`.

### Verification

Confirm the enterprise repo is commented out and the no-subscription repo (added during the wiki install) is active:

```bash
grep -r '^[^#]' /etc/apt/sources.list.d/pve-*.sources
```

You should see only `pve-no-subscription` lines — no uncommented `pve-enterprise` entries. Then:

```bash
apt update
```

This should complete without errors or 401 warnings.

## Step 5 — Set up ZFS VM storage

Install ZFS if not already present (PVE doesn't always install it automatically when added on top of Debian):

```bash
apt install zfsutils-linux -y
```

Unmount and disassemble the temporary `/data` partition:

```bash
umount /data
```

Remove the `/data` entry from `/etc/fstab`:

```bash
sed -i '\|/data|d' /etc/fstab
```

Verify it's gone:

```bash
grep data /etc/fstab
```

This should return nothing.

Stop and clean up the md3 array:

```bash
mdadm --stop /dev/md3
mdadm --zero-superblock /dev/nvme0n1p5 /dev/nvme1n1p5
```

Update mdadm config to remove the stale array:

```bash
mdadm --examine --scan > /etc/mdadm/mdadm.conf
update-initramfs -u
```

Create the ZFS mirror pool:

```bash
zpool create -f -o ashift=13 -o autotrim=on \
  -O compression=lz4 \
  -O atime=off \
  storage mirror /dev/nvme0n1p5 /dev/nvme1n1p5
```

**About the options:**

- `ashift=13` — 8K sector alignment, safe default for NVMe (4K also works with `ashift=12`; check with `cat /sys/block/nvme0n1/queue/physical_block_size`)
- `autotrim=on` — automatic TRIM, important for NVMe longevity and performance
- `compression=lz4` — fast, lightweight compression with minimal CPU overhead
- `atime=off` — disables access time tracking, unnecessary for VM storage

Register the pool in Proxmox:

```bash
zfs set mountpoint=none storage
pvesm add zfspool local-zfs -pool storage
```

The `mountpoint=none` prevents the root dataset from mounting — PVE manages zvols (virtual block devices) directly under the pool.

**Thick vs thin provisioning:** PVE defaults to thick — each VM disk reserves its full size on the pool upfront. This guarantees writes never fail due to lack of space. If you prefer thin provisioning (disks grow on demand, allows overcommitting), add `-sparse 1` to the `pvesm add` command. Thin saves space but requires monitoring — if the pool fills up, VM writes will fail. You can change this later with `pvesm set local-zfs -sparse 1` (or `-sparse 0`).

### Verification

```bash
zpool status
zfs list
pvesm status
```

You should see the `storage` pool as a healthy mirror and `local-zfs` in the PVE storage list.

## Step 6 — Limit ZFS ARC memory

ZFS uses RAM for its read cache (ARC). On a VM host you want to cap this so VMs aren't competing for memory. Rule of thumb: ~2 GB base + 1 GB per TB of pool. In our case — 64 GB server, ~53 GB allocated to VMs, sub-1 TB pool — 3 GB for ARC leaves enough headroom for the OS and services. Adjust based on your VM density and available RAM.

```bash
echo "options zfs zfs_arc_max=3221225472" > /etc/modprobe.d/zfs.conf
update-initramfs -u
```

This takes effect on next reboot. To apply immediately without rebooting:

```bash
echo 3221225472 > /sys/module/zfs/parameters/zfs_arc_max
```

## Step 7 — Access the web GUI

Open your browser and navigate to:

```
https://YOUR-SERVER-IP:8006
```

Log in with **root** and **Linux PAM** authentication. The certificate is self-signed — accept the browser warning.

**Security note:** The web GUI binds to all interfaces by default. On a Hetzner server with a public IP, port 8006 is exposed to the internet. For production setups, consider accessing it through an SSH tunnel (`ssh -L 8006:localhost:8006 root@YOUR-SERVER-IP`) or restricting access via Hetzner's Robot firewall.

## Step 8 — Security

### Root password

If you installed with SSH keys only (common on Hetzner), root may not have a password. The PVE web GUI requires one:

```bash
passwd root
```

### Harden SSH

Since you have SSH key access, disable password login for root:

```bash
sed -i '/^#\?PermitRootLogin/c\PermitRootLogin prohibit-password' /etc/ssh/sshd_config
```

**Before restarting SSH**, verify your key is in place — otherwise you'll lock yourself out:

```bash
cat /root/.ssh/authorized_keys
```

You should see your public key. Hetzner's installimage may also add the server's own key (`root@your-hostname`) — you can remove that line, it's not needed for access.

### SSH keepalive

Server-side keepalive cleanly disconnects dead sessions (e.g., after laptop sleep) instead of leaving them hanging:

```bash
sed -i '/^#\?ClientAliveInterval/c\ClientAliveInterval 60' /etc/ssh/sshd_config
grep -q 'ClientAliveInterval' /etc/ssh/sshd_config || echo "ClientAliveInterval 60" >> /etc/ssh/sshd_config
```

Apply all SSH changes:

```bash
systemctl restart ssh
```

### Quality of life

Optional but handy on a headless server:

```bash
apt remove -y vim && \
apt install -y neovim tmux
```

## Notes

- **No enterprise subscription?** The `pve-no-subscription` repo is fine for home labs and small setups. The enterprise repo requires a paid key. PVE will show a subscription nag on login — this is cosmetic only.
- **Secure Boot** must be disabled for the Proxmox kernel to boot. Hetzner servers typically don't have it enabled.
- **Migration-friendly setup:** Treat the PVE host as cattle, not a pet. Since VMs live on ZFS and backups go to PBS, migrating to a new server means: fresh PVE install → connect PBS → restore VMs. No need to migrate disk images manually. For host-level config, PVE stores everything in `/var/lib/pve-cluster/config.db` (which maps to `/etc/pve/`). A tarball of `/etc/pve`, `/etc/network/interfaces`, `/etc/fstab`, and `/etc/modprobe.d/` covers the essentials.
- **ZFS scrubs:** PVE schedules monthly ZFS scrubs by default. These run in the background and check data integrity across the mirror.

## References

- https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie
- https://docs.hetzner.com/robot/dedicated-server/operating-systems/installimage/
- https://pve.proxmox.com/wiki/ZFS_on_Linux
- https://pve.proxmox.com/pve-docs/chapter-pve-installation.html
