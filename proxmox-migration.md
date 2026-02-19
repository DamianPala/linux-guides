# Migrate Proxmox VE to a New Server

This guide covers migrating PVE configuration and VMs between two dedicated servers using Proxmox Backup Server (PBS). It assumes the new server already has PVE installed with a working ZFS pool and PBS connected.

## What gets migrated

- Network config (bridges, IPs, routes)
- Firewall rules (nftables)
- PBS storage connection
- Backup job schedules
- VMs (restored from PBS backups)

## Step 1 — Backup old server state

Before touching anything, dump the old server's config into a tarball. Run this **on the old server**:

```bash
TS="$(date +'%F_%H-%M-%S')" \
HOST="$(hostname -s)" \
STATE="pve-state-${HOST}-${TS}.txt" && \

{
  echo "=== timestamp: $TS ==="
  echo "=== host: $HOST ==="
  echo
  pveversion -v 2>/dev/null || true
  cat /etc/os-release 2>/dev/null || true
  ip a 2>/dev/null || true
  ip r 2>/dev/null || true
  zpool status 2>/dev/null || true
  zfs list -o name,used,avail,refer,mountpoint 2>/dev/null || true
  nft list ruleset 2>/dev/null || true
  iptables-save 2>/dev/null || true
} > "$STATE" && \

tar -czf "proxmox-backup-${HOST}-${TS}.tar.gz" \
  "$STATE" \
  /etc/pve \
  /etc/network/interfaces \
  /etc/hosts \
  /etc/resolv.conf \
  /etc/udev \
  /etc/apt \
  /etc/sysctl.d \
  /etc/ssh \
  /etc/systemd/system \
  $(test -d /etc/wireguard && echo /etc/wireguard) && \

rm -f "$STATE"
```

This captures PVE version, network config, ZFS layout, firewall rules, and all key config directories into a single `proxmox-backup-HOSTNAME-TIMESTAMP.tar.gz`.

Then copy the tarball to the **new server**:

```bash
rsync -avP proxmox-backup-*.tar.gz root@NEW_SERVER:/root/
```

On the new server, extract it for reference during migration:

```bash
cd /root && mkdir pve-backup && tar -xzf proxmox-backup-*.tar.gz -C pve-backup
```

This gives you quick access to the old config files for all subsequent steps (network, firewall, PBS keys, etc.).

## Step 2 — Network interfaces

Copy `/etc/network/interfaces` from the old server and adapt:

- Change the physical interface name (e.g., `enp7s0` → `enp35s0`) — check with `ip link`
- Update IPv4 address, gateway, and subnet
- Update IPv6 address if applicable
- Keep bridge definitions (vmbr0, vmbr1, vmbr2) and their structure

**Safe apply with auto-rollback** — run this in a separate tmux pane before changing anything:

```bash
cp /etc/network/interfaces /etc/network/interfaces.bak && sleep 180 && cp /etc/network/interfaces.bak /etc/network/interfaces && ifreload -a
```

Then in your main session, edit the file and apply:

```bash
ifreload -a
```

If SSH survives — cancel the rollback with `Ctrl+C` in the tmux pane.

## Step 3 — Firewall (nftables)

```bash
systemctl disable --now pve-firewall proxmox-firewall
```

Copy your nftables config from the old server and update IPs/interfaces. Apply with the safe-apply tool:

```bash
nftables-apply /etc/nftables-candidate.conf
```

If PBS or other services have firewall rules that whitelist the old server's IP, update them to allow the new server's IP.

Don't forget IP forwarding if your setup requires NAT:

```bash
cat > /etc/sysctl.d/99-ipforward.conf << 'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system
```

## Step 4 — PBS storage

In the PVE web GUI: **Datacenter → Storage → Add → Proxmox Backup Server**

- **ID:** `pbs`
- **Server:** PBS IP address
- **Datastore:** datastore name
- **Username:** `root@pam`
- **Password:** PBS root password
- **Fingerprint:** paste from old server's `/etc/pve/storage.cfg` or let PVE fetch it

If backups are encrypted, copy the encryption key from the old server:

```bash
mkdir -p /etc/pve/priv/storage
rsync root@OLD_SERVER:/etc/pve/priv/storage/pbs.enc /etc/pve/priv/storage/pbs.enc
```

## Step 5 — Restore VMs

Restore from PBS via GUI: **pbs → Content** → select backup → **Restore**.

**Important:** Change **Storage** from "From backup configuration" to `local-zfs` — the old pool doesn't exist on the new server.

Restore the **router/gateway VM first** — other VMs depend on it for network access.

You can change VMIDs during restore. If you do, see [Step 8](#step-8--fix-pbs-backup-groups-after-vmid-change) to fix PBS backup groups.

## Step 6 — PVE config files

Copy these from the old server to the new one:

```bash
# User accounts and permissions
rsync root@OLD_SERVER:/etc/pve/user.cfg /etc/pve/user.cfg

# Datacenter settings (keyboard layout, console, etc.)
rsync root@OLD_SERVER:/etc/pve/datacenter.cfg /etc/pve/datacenter.cfg
```

## Step 7 — Backup jobs

```bash
rsync root@OLD_SERVER:/etc/pve/jobs.cfg /etc/pve/jobs.cfg
```

If you changed VMIDs, update the `vmid` line to match the new IDs:

```
# Old
vmid 103,105,106,107,108,109

# New (after VMID reassignment)
vmid 100,101,102,110,111,112
```

The job ID (e.g., `backup-d89d8246-b31f`) is a random identifier — reuse it or let PVE generate a new one.

**Don't forget:** If the old server is still running, disable its backup jobs to avoid duplicate backups to PBS. In the old PVE web GUI: **Datacenter → Backup** → select the job → **Remove** (or just disable it).

## Step 8 — Fix PBS backup groups after VMID change

If you changed VMIDs during restore, PBS still stores backups under the old IDs.

On the **PBS server**:

```bash
# 1. Find the datastore path
proxmox-backup-manager datastore list

# 2. Enable maintenance mode (blocks all access)
proxmox-backup-manager datastore update DATASTORE --maintenance-mode offline

# 3. Go to the datastore directory
cd /path/to/datastore

# 4. Rename directories — handle conflicts carefully
#    If old VMID X needs to become Y, but Y already exists,
#    move Y out of the way first (e.g., to a temp name or its final ID)
ls vm/
mv vm/OLD_ID vm/NEW_ID

# 4. Verify
ls vm/

# 5. Disable maintenance mode
proxmox-backup-manager datastore update DATASTORE --delete maintenance-mode
```

**Ordering matters** when two IDs swap. For example, if old 108 becomes new 100 but old 100 also exists:

```bash
mv vm/100 vm/200      # move old 100 out of the way first
mv vm/108 vm/100      # now safe to use 100
```

### Verify the rename

Use PBS WebGUI to verify names.

## Step 9 — Router / gateway VM

- Restore the router VM **first** — other VMs depend on it for network access
- Update the **MAC address** of the WAN interface (vmbr0 port) to match the new server's virtual MAC from your hosting provider (e.g., Hetzner Robot → IPs → virtual MAC)

## Step 10 — DNS records

Update DNS A/AAAA records for any domains pointing at the old server's IP. This includes:
