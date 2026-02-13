# System Backup & Disaster Recovery: Ransomware-Resistant Guide

This guide shows how to build a backup system that can survive ransomware attacks, disk failures, and accidental deletions. You'll set up encrypted Btrfs on LUKS2 with automated snapshots, push backups to a NAS using Borg in append-only mode.

The result is a system where even if your laptop gets compromised, you can recover from NAS snapshots—attackers can queue deletions, but NAS snapshots preserve your data until you detect the breach.

## Security Model

This backup system is designed for the worst-case scenario: **a fully compromised laptop**. Ransomware, stolen credentials, malicious software—any of these could give an attacker full control of your machine, including your backup credentials. The architecture ensures that even in this scenario, your backups remain safe.

**The core principle: Laptop is untrusted, NAS is trusted.**

Your laptop can only *add* data to the backup repository. It cannot permanently delete anything. Deletions require action on the NAS side, which an attacker controlling your laptop cannot reach.

### Defense Layers

| Layer | What it does | Protects against |
|-------|--------------|------------------|
| **Append-only mode** | SSH forced-command restricts laptop to `borg serve --append-only`. Delete/prune commands are accepted but only *tag* data for removal (soft delete). | Immediate destruction—buys you time to detect the breach |
| **NAS snapshots** | Btrfs snapshots of the Borg repository, taken daily, retained 14 days. Immutable snapshots (WORM) prevent deletion even by NAS admin. | Soft-deleted data becoming permanent—your real recovery source |
| **Maintenance safety checks** | NAS-side script verifies archive counts and repo integrity *before* running `borg compact`. Aborts if anomalies detected. | Attacker queuing mass deletions that would finalize on next maintenance |
| **Healthchecks.io** | Dead man's switch alerts if backups stop running. | Silent failures, laptop offline/stolen without you noticing |

### Attack Timeline Example

1. **Monday 10:00** — Attacker compromises laptop, runs `borg delete --glob-archives '*'`
2. **Monday 10:01** — Append-only mode accepts the command, archives are *tagged* for deletion (soft delete)
3. **Monday 18:00** — Daily backup runs, creates new archive (attacker may delete this too)
4. **Tuesday 06:00** — NAS snapshot captures current repo state (including soft-deleted markers)
5. **Sunday 06:00** — NAS maintenance script runs, detects archive count dropped from 20 to 1, **aborts** before `borg compact`
6. **Sunday 06:01** — You receive email alert about failed maintenance
7. **Recovery** — You restore from Saturday's NAS snapshot, which has all 20 archives intact

Without NAS snapshots: if maintenance had run without safety checks, `borg compact` would have permanently deleted your data.

### Recovery Window

Your recovery window equals your NAS snapshot retention (14 days in this guide). If you detect a breach within 14 days, you can recover from a pre-attack snapshot. After 14 days, older snapshots are rotated out.

**Recommendations:**
- Check Healthchecks.io dashboard weekly (or set up alerts)
- Investigate any maintenance script failures immediately
- Consider longer snapshot retention if you travel or may not check for weeks

## How It Works

**Local system:**
- UEFI boot with Secure Boot enabled
- Unencrypted `/boot` and ESP for the bootloader
- LUKS2 encrypted swap partition (separate from root)
- LUKS2 encrypted root partition with Btrfs subvolumes (`@`, `@home`)
- LUKS2 encrypted storage partition with LVM (ext4 logical volumes for `~/storage` and `~/storage-nb`)
- TPM2 auto-unlock with PIN for all three LUKS containers (dracut-based, fallback passphrase)
- Btrfs snapshots created automatically by borgmatic before each backup (for consistency)

**Remote backups:**
- Borg repositories on NAS, accessed via SSH
- SSH forced-command restricts laptop to `borg serve --append-only`
- NAS snapshots with 14-day retention
- Automatic maintenance via NAS Task Scheduler (with safety checks)
- Healthchecks.io monitors backup success

**3-2-1 rule:**
- 3 copies: live system, remote Borg backups, NAS snapshots of Borg repo
- 2 different media: laptop SSD, NAS storage
- 1 offsite: NAS is physically separate from laptop

## Prerequisites

**Hardware:**
- UEFI system with TPM 2.0
- Secure Boot capable
- At least 15-20% free space on Btrfs (for snapshots and CoW operations)

**Software:**
- Kubuntu 25.10 or similar (systemd-based with dracut support)
- NAS with SSH access (Synology, TrueNAS, or Linux server)

## Step 1: Partition Layout and LUKS Setup

This tutorial assumes you've followed a LUKS2+Btrfs installation like the one described in related guides. Your disk layout should look like:

| Partition | Size | Type | Mount | Encrypted |
|-----------|------|------|-------|-----------|
| p1 | 1 GB | FAT32 | /boot/efi | No |
| p2 | 1 GB | ext4 | /boot | No |
| p3 | 8 GB | LUKS2→swap | — | Yes |
| p4 | ~400 GB | LUKS2→Btrfs | / + /home | Yes |
| p5 | remaining | LUKS2→LVM→ext4 | ~/storage + ~/storage-nb | Yes |

**Btrfs subvolumes** on p4 (cryptroot):
- `@` → `/` (root filesystem)
- `@home` → `/home` (user data)

**LVM logical volumes** on p5 (cryptstorage):
- `storage` → `~/storage` (VMki, ISO images - backed up daily)
- `storage-nb` → `~/storage-nb` (sync data, large caches - not backed up)

Verify your setup:

```bash
lsblk -f
sudo btrfs subvolume list /
sudo lvdisplay
cat /etc/crypttab
cat /etc/fstab
```

Look for three LUKS containers (swap, root, storage), Btrfs compression enabled on `@` and `@home`, and LVM volumes for storage.

### Configure Variables

Set these variables for your environment (used throughout the tutorial):

```bash
NAS="backup@192.168.1.100"           # backup user@NAS IP
REPO_PATH="/volume1/backup/laptop"   # repository path on NAS
```

## Step 2: Install Backup Tools

Install Borg and borgmatic:

```bash
# Install uv if not present
command -v uv &>/dev/null || { curl -LsSf https://astral.sh/uv/install.sh | sh && source ~/.local/bin/env; }

# Install borg and borgmatic system-wide (to /usr/local/bin)
UV=$(which uv)
sudo UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin "$UV" tool install borgbackup
sudo UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin "$UV" tool install borgmatic
```

Verify versions (Borg 1.4.3+, borgmatic 2.1.x+ required):

```bash
borg --version
borgmatic --version
```

**Upgrading later:**
```bash
UV=$(which uv)
sudo UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin "$UV" tool upgrade borgbackup
sudo UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin "$UV" tool upgrade borgmatic
```

## Step 3: NAS Preparation (Synology)

### Install Borg on Synology

Synology DSM doesn't include Borg by default. Install it via SynoCommunity:

1. **Package Center → Settings → Package Sources → Add**
2. Fill in:
   ```
   Name: SynoCommunity
   Location: https://packages.synocommunity.com
   ```
3. Click OK, then go to **Package Center → Community**
4. Find and install **Borg**

Verify installation (SSH as admin):

```bash
ssh admin@nas_ip
borg --version
```

### Create Shared Folder with Quota

First, create a dedicated shared folder for backups:

**Control Panel → Shared Folder → Create**:
```
Name: backup
Description: Borg backup repositories
Location: volume1
Encryption: No (Borg handles encryption)
Enable Recycle Bin: No (Borg manages versions)
Enable data checksum: No (Btrfs has built-in checksums)
Hide this shared folder in "My Network Places": Yes (reduces network visibility)
Hide sub-folders and files from users without permissions: Yes (principle of least privilege)
```

**Security notes:**
- **Data checksum**: Disabled because Synology Btrfs volumes already have checksums at the filesystem level. Borg also has its own checksums. Three layers would be redundant.
- **Hide from network**: Prevents the backup folder from appearing in SMB/AFP network browsing. Backup user connects via SSH only, not file sharing.
- **Hide without permissions**: Users without access won't see this folder exists in DSM File Station. Reduces information leakage.

**Set quota on the shared folder** (Control Panel → Shared Folder → Edit "backup" → Advanced → Quota):
```
Enable quota: Yes
Size limit: 500 GB (adjust to your needs)
```

This quota works independently of user privileges and physically limits the shared folder size.

### Create Backup User

**Control Panel → User & Group → Create** user "backup":

**Basic settings:**
```
Username: backup
Password: (strong password - you'll rarely use it directly)
Email: (optional)
```

**User Groups:**
```
administrators: ✓ (REQUIRED for SSH access in DSM 6.2.2+)
users: ✓
```

**Shared Folder Permissions:**
```
backup: Read/Write ✓
homes: Read/Write ✓ (REQUIRED - without this, user can't access their home directory for SSH keys)
All other folders: No Access
```

**Applications Access - BLOCK EVERYTHING:**

Go to **Control Panel → User & Group → Edit "backup" → Applications** and **deny access to all applications**:
```
DSM: ✗ (prevents GUI login)
File Station: ✗
Synology Drive: ✗
Synology Photos: ✗
AFP: ✗
FTP: ✗
SFTP: ✗ (we use SSH with forced-command instead)
SMB: ✗
WebDAV: ✗
```

This ensures the backup user can ONLY connect via SSH with the forced-command - no GUI, no file sharing protocols, nothing else.

### Create Repository Directory

SSH to NAS as admin and create the laptop-specific directory. First, print the variables to copy-paste into the NAS session:

```bash
echo "REPO_PATH=\"$REPO_PATH\""
```

Copy the output, then SSH to NAS and paste it:

```bash
ssh admin@nas_ip
REPO_PATH="/volume1/backup/laptop"   # paste the output from above
sudo mkdir -p "$REPO_PATH"
sudo chown backup:users "$REPO_PATH"
sudo chmod 700 "$REPO_PATH"
```

## Step 4: SSH Key Setup with Forced Command

Generate an SSH key pair for backups on your laptop:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/backup_append_only -C "laptop-backup-append-only"
```

**Do not set a passphrase** for this key—it needs to run unattended. The forced-command restriction provides security.

Copy the public key to the NAS:

```bash
ssh-copy-id -i ~/.ssh/backup_append_only.pub $NAS
```

### Configure Forced Command (DSM 7.0+)

DSM 7.0+ mounts `/tmp` with `noexec` flag, which causes Borg to fail with library loading errors. We'll use a wrapper script to set a custom `TMPDIR`.

**On the NAS, SSH as the backup user:**

```bash
ssh $NAS

# Create custom temp directory
mkdir -p ~/.tmp

# Create wrapper script with correct borg path
BORG_PATH=$(which borg)
cat > ~/.ssh/borg-wrapper.sh <<EOF
#!/bin/bash
export TMPDIR="\$HOME/.tmp"
exec $BORG_PATH serve --append-only --restrict-to-repository /volume1/backup/laptop "\$@"
EOF

chmod +x ~/.ssh/borg-wrapper.sh

# Verify the script looks correct
cat ~/.ssh/borg-wrapper.sh
```

**Edit `~/.ssh/authorized_keys` to use the wrapper:**

```bash
nano ~/.ssh/authorized_keys
```

Find the line with your public key and prepend the forced-command. The full line should look like:

```
command="/var/services/homes/backup/.ssh/borg-wrapper.sh",restrict ssh-ed25519 AAAAC3Nz... laptop-backup-append-only
```

**What this does:**
- `command="..."`: Forces this exact command, ignoring what the SSH client requests
- Wrapper sets `TMPDIR` to writable location (bypasses /tmp noexec)
- `--append-only`: Deletions are soft-deleted only (see Security Model)
- `--restrict-to-repository`: Limits access to exactly this repository (more restrictive than `--restrict-to-path`)
- `restrict`: Disables port forwarding, X11, agent forwarding, PTY allocation

### Test the Connection

From your laptop, test SSH access:

```bash
ssh -i ~/.ssh/backup_append_only $NAS
```

You should see: `Remote: borg: Forced command: borg serve --append-only...` instead of a shell prompt. This confirms forced-command is working.

Try executing a command (this should fail):

```bash
ssh -i ~/.ssh/backup_append_only $NAS ls /
```

This should be blocked—proving the forced-command prevents arbitrary command execution.

## Step 5: Initialize Borg Repository

From your laptop, initialize the encrypted Borg repository on the NAS. You'll be prompted for a passphrase — choose a **strong one** (25+ characters, random, stored in password manager). This passphrase protects all your backups; without it, data is unrecoverable.

```bash
export BORG_RSH="ssh -i ~/.ssh/backup_append_only"
read -rsp "Borg passphrase: " BORG_PASSPHRASE && export BORG_PASSPHRASE && echo
borg init --encryption=repokey-blake2 ssh://${NAS}${REPO_PATH}

# Verify
borg info ssh://${NAS}${REPO_PATH}
```

You should see `Encrypted: Yes (repokey BLAKE2b)` and `Repository ID` in the output.

If you get `Permission denied` on subsequent operations, fix ownership on the NAS:

```bash
ssh admin@${NAS#*@} "sudo chown -R backup:users ${REPO_PATH}"
```

**Repository per device (recommended):**
Keep one Borg repository per device. If you ever store multiple devices in a single repo, you must scope pruning/maintenance with `--glob-archives` (or similar) so archives from different machines don't prune each other.

**About encryption modes:**
- `repokey-blake2`: Encryption key stored in repo, encrypted with passphrase
- Uses BLAKE2b hashing (faster than SHA256 on most modern CPUs)

## Step 6: Healthchecks.io Setup

1. Create a free account at [healthchecks.io](https://healthchecks.io)
2. Create a new check with:
   - Name: `Laptop Backup`
   - Schedule: **Simple**
   - Period: `1 days`
   - Grace Time: `1 days`
3. Copy the Ping URL (looks like `https://hc-ping.com/xxxx-xxxx-xxxx`)
4. Save this URL—you'll need it when configuring borgmatic

Healthchecks will alert you if:
- Backup fails (receives "fail" ping)
- Backup doesn't run (no ping received within schedule + grace time)
- Laptop is off during backup window (catches silent failures)

## Step 7: DR Metadata Collection Script

Create `/usr/local/bin/backup-dr-metadata.sh` to capture system metadata:

```bash
sudo tee /usr/local/bin/backup-dr-metadata.sh > /dev/null <<'EOF'
#!/bin/bash
# Disaster Recovery metadata collection
# Captures system layout for bare-metal recovery

DR_DIR="/var/backup/dr-metadata"
mkdir -p "$DR_DIR"

# Detect root disk (trace through LUKS/btrfs to physical disk)
ROOT_DEV=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
ROOT_DISK=$(lsblk -nso NAME,TYPE "$ROOT_DEV" | awk '$2=="disk" {gsub(/[^a-zA-Z0-9]/,"",$1); print $1}')

# Disk layout
lsblk -f > "$DR_DIR/lsblk.txt"
blkid > "$DR_DIR/blkid.txt"
sfdisk --dump "/dev/$ROOT_DISK" > "$DR_DIR/partition-table.sfdisk" 2>/dev/null

# LUKS metadata and header backups for all LUKS devices
for dev in $(blkid | grep crypto_LUKS | cut -d: -f1); do
    name=$(basename "$dev" | sed 's/[^a-zA-Z0-9]/_/g')
    cryptsetup luksDump "$dev" > "$DR_DIR/luks-$name.txt" 2>/dev/null
    # Binary header backup — required to recover from corrupted LUKS header
    # (luksDump above is text-only metadata, not enough for recovery)
    cryptsetup luksHeaderBackup "$dev" --header-backup-file "$DR_DIR/luks-header-$name.bin" 2>/dev/null
done

# System configuration
cp /etc/fstab "$DR_DIR/fstab"
cp /etc/crypttab "$DR_DIR/crypttab"
cat /proc/cmdline > "$DR_DIR/kernel-cmdline.txt"

# Btrfs layout
btrfs subvolume list / > "$DR_DIR/btrfs-subvolumes.txt" 2>/dev/null
btrfs filesystem show > "$DR_DIR/btrfs-filesystems.txt" 2>/dev/null

# LVM layout (if present)
if command -v pvdisplay &> /dev/null; then
    pvdisplay > "$DR_DIR/lvm-pv.txt" 2>/dev/null
    vgdisplay > "$DR_DIR/lvm-vg.txt" 2>/dev/null
    lvdisplay > "$DR_DIR/lvm-lv.txt" 2>/dev/null
fi

# Dracut config
tar -czf "$DR_DIR/dracut-config.tar.gz" /etc/dracut.conf.d/ 2>/dev/null

# Swap configuration
swapon --show > "$DR_DIR/swap.txt" 2>/dev/null

# Boot entries
efibootmgr -v > "$DR_DIR/efi-boot-entries.txt" 2>/dev/null

echo "DR metadata collected: $(date)" > "$DR_DIR/collection-timestamp.txt"
EOF

sudo chmod +x /usr/local/bin/backup-dr-metadata.sh
```

This script runs before each backup (via borgmatic's `commands` hook), ensuring you always have current system metadata in your backups.

Test it:

```bash
sudo /usr/local/bin/backup-dr-metadata.sh
ls -la /var/backup/dr-metadata/
```

## Step 8: Configure Borgmatic

Create borgmatic configuration:

```bash
# Set your Healthchecks.io ping URL (from Step 6)
HC_PING_URL="https://hc-ping.com/your-uuid-here"

sudo mkdir -p /etc/borgmatic
sudo tee /etc/borgmatic/config.yaml > /dev/null << EOF
repositories:
    - path: ssh://${NAS}${REPO_PATH}
      label: nas-laptop

source_directories:
    - /
    - /home
    - /boot
    - /boot/efi
    - /home/$USER/storage
    - /var/backup/dr-metadata

# Enable native btrfs snapshots (borgmatic 1.9.4+)
btrfs: {}

exclude_patterns:
    # System
    - /proc
    - /sys
    - /run
    - /dev
    - /tmp
    - /var/cache
    - /snap
    - /swap
    - '**/lost+found/'
    - /mnt
    - /media
    - '*/storage-nb/'

    # Home
    - '*/.local/share/Trash/'

    # Always junk - safe to exclude globally
    - '**/__pycache__/'
    - '**/.cache/'
    - '**/.gradle/'
    - '**/ccache/'
    - '**/.cargo/registry/'
    - '**/.m2/repository/'
    - '**/.npm/'
    - '**/.pnpm-store/'

    # Build artifacts - only in repos directory
    - '**/repos/**/build/'
    - '**/repos/**/out/'
    - '**/repos/**/dist/'
    - '**/repos/**/target/'
    - '**/repos/**/cmake-build-*/'
    - '**/repos/**/.next/'
    - '**/repos/**/.nuxt/'

exclude_if_present:
    - .nobackup

# Retention (laptop sends prune commands; NAS executes as soft-delete in append-only mode)
keep_daily: 7
keep_weekly: 4
keep_monthly: 6

# Consistency checks
checks:
    - name: repository
      frequency: 1 week
    - name: archives
      frequency: 1 month

# Hooks
commands:
    - before: action
      when: [create]
      run:
          - /usr/local/bin/backup-dr-metadata.sh

healthchecks:
    ping_url: $HC_PING_URL
    states:
        - start
        - finish
        - fail

compression: zstd
statistics: true
ssh_command: ssh -i /home/$USER/.ssh/backup_append_only
EOF
```

**Important:** Paste your Healthchecks.io ping URL into the `HC_PING_URL` variable before running.

### Secure Passphrase Storage with systemd Credentials

Instead of storing the Borg passphrase in plaintext, use systemd's encrypted credential store. The passphrase will be encrypted on disk (TPM-backed when available) and only accessible to the borgmatic service.

Create the encrypted credential:

```bash
# Create directory for encrypted credentials
sudo mkdir -p /etc/credstore.encrypted

# Store your Borg passphrase as encrypted credential
read -rsp "Borg passphrase: " BORG_PASS && echo
echo -n "$BORG_PASS" | sudo systemd-creds encrypt --name=borg-passphrase - /etc/credstore.encrypted/borg-passphrase
unset BORG_PASS

# Protect the credential file
sudo chmod 600 /etc/credstore.encrypted/borg-passphrase
```

The credential is now encrypted. The systemd service will decrypt it at runtime and pass it to borgmatic via environment variable (configured in Step 10).

**Important:** Store your passphrase in a password manager as backup. Without it and the repo key, backups are permanently unrecoverable.

## Step 9: Test Backup

Run a manual backup to verify everything works. For manual testing, you need to provide the passphrase (systemd credentials only work when running as a service):

```bash
read -rsp "Borg passphrase: " BORG_PASSPHRASE && echo
sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borgmatic --progress --verbosity 1
```

You should see:
1. Btrfs snapshots being created
2. DR metadata collection
3. Healthchecks "start" ping
4. Borg creating archive
5. Healthchecks "finish" ping

Check the Borg repository:

```bash
export BORG_RSH="ssh -i ~/.ssh/backup_append_only"
read -rsp "Borg passphrase: " BORG_PASSPHRASE && export BORG_PASSPHRASE && echo
borg list ssh://${NAS}${REPO_PATH}
```

## Step 10: Automate Backups

Create systemd timer and service for daily backups:

```bash
# Create timer
sudo tee /etc/systemd/system/borgmatic.timer > /dev/null << 'EOF'
[Unit]
Description=Run borgmatic backup daily

[Timer]
OnCalendar=*-*-* 18:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Create service
sudo tee /etc/systemd/system/borgmatic.service > /dev/null << 'EOF'
[Unit]
Description=borgmatic backup
After=network-online.target

[Service]
Type=oneshot

# Load encrypted passphrase credential
LoadCredentialEncrypted=borg-passphrase:/etc/credstore.encrypted/borg-passphrase

# Pass passphrase to borgmatic via environment variable
ExecStart=/bin/bash -c 'BORG_PASSPHRASE=$(cat ${CREDENTIALS_DIRECTORY}/borg-passphrase) /usr/local/bin/borgmatic --verbosity 1'

# Security settings (based on official borgmatic sample)
LockPersonality=true
MemoryDenyWriteExecute=no
NoNewPrivileges=yes
PrivateTmp=yes
ProtectClock=yes
ProtectControlGroups=yes
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Required for btrfs snapshots (CAP_SYS_ADMIN needed for btrfs subvolume operations)
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_NET_RAW CAP_SYS_ADMIN
AmbientCapabilities=CAP_SYS_ADMIN
EOF
```

The service loads the encrypted credential and makes it available in `${CREDENTIALS_DIRECTORY}`. At runtime, systemd decrypts it and passes the passphrase to Borg via the `BORG_PASSPHRASE` environment variable.

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now borgmatic.timer
sudo systemctl list-timers --all | grep borgmatic
```

Run backup manually:

```bash
# Trigger backup now (runs in background)
sudo systemctl start borgmatic.service

# Watch progress in real-time
journalctl -u borgmatic -f
```

## Step 11: NAS-Side Snapshot Protection (Synology DSM 7.2+)

This step implements the critical "NAS snapshots" layer from the Security Model above.

### Prerequisites

- Volume must be formatted as **Btrfs** (not EXT4—there's no in-place conversion, reformatting wipes data)
- **Snapshot Replication** package installed from Package Center
- DSM 7.2+ for immutable snapshots (DSM 7.3 carries forward the same feature)

### Enable Snapshot Schedule

1. Open **Snapshot Replication** → **Snapshots**
2. Select the shared folder containing your Borg repository (e.g., `backup`)
3. Click **Settings**
4. Check **Enable Snapshot Schedule**
5. **Schedule** tab: set to **Daily**, timed after your laptop backup runs (e.g., 6:00 AM if backup runs at 18:00)
6. **Advanced** tab: enable **Make snapshots visible** — snapshots appear in a read-only `#snapshot` subfolder, useful for quick manual recovery

### Configure Retention

In **Settings → Retention** tab:

- Set retention to keep **14 daily snapshots** (matches the 14-day recovery window)
- Alternatively, use **Advanced Retention Policy** (Grandfather-Father-Son) for longer history:
  - Keep all snapshots from last 24 hours
  - Keep 1 daily snapshot for 14 days
  - Keep 1 weekly snapshot for 4 weeks

### Enable Immutable Snapshots (WORM)

Immutable snapshots prevent deletion by anyone—including NAS administrators and compromised admin accounts—until the protection period expires.

1. In **Snapshot Replication → Snapshots → Settings**
2. Check **Immutable Snapshots**
3. Set **Protection Period: 14 days** (maximum is 30 days, Synology recommends 7–14)

**Warnings:**
- Once enabled, you **cannot disable immutability or reduce the protection period** until all existing immutable snapshots expire. This is by design—it prevents attackers from turning off protection.
- Immutability protects against snapshot deletion, **not volume/storage pool deletion**. Physical access to the NAS or DSM admin deleting the entire storage pool bypasses this. Mitigate by: using a dedicated admin account with strong 2FA, disabling SSH when not needed, and keeping the NAS on a separate VLAN if possible.
- Immutable snapshots are only available on [specific Synology models](https://www.synology.com/en-us/dsm/7.3/software_spec/snapshot_replication) (generally Plus-series and above).

### Verify Snapshots

After at least one scheduled snapshot runs:

1. **Snapshot Replication → Snapshots** — you should see snapshots listed with timestamps
2. **File Station** → navigate to `backup` shared folder → `#snapshot` subfolder — browse read-only snapshot contents
3. Check snapshot size: **Snapshot Replication → Snapshots → Action → Calculate Snapshot Size**

## Step 12: Automatic Pruning on NAS

Without pruning, your repo grows forever. `borg compact` must run on the NAS (without `--append-only`) to reclaim space—but this also makes soft-deletes permanent. The maintenance script below includes safety checks (see Security Model) to detect anomalies before finalizing deletions.

### Store Passphrase on NAS

The prune script needs the Borg passphrase to access the encrypted repo:

```bash
# On NAS (as root)
stty -echo; printf "Borg passphrase: "; read -r BORG_PASS; stty echo; echo
printf '%s' "$BORG_PASS" | sudo tee /root/.borg-passphrase > /dev/null
sudo chmod 600 /root/.borg-passphrase
unset BORG_PASS
```

### Create Maintenance Script

Create `/usr/local/bin/borg-maintenance.sh` on the NAS:

```bash
# On NAS
sudo tee /usr/local/bin/borg-maintenance.sh > /dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

REPO="/volume1/backup/laptop"
LOG="/var/log/borg-maintenance.log"
STATE_DIR="/var/lib/borg-maintenance"
MIN_ARCHIVES=5          # Abort if fewer archives than this (possible mass-delete attack)
COMPACT_THRESHOLD=10    # Skip compact if <10% reclaimable space (adjust if needed)

export BORG_PASSPHRASE="$(cat /root/.borg-passphrase)"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG"; }

mkdir -p "$STATE_DIR"

log "=== Maintenance started ==="

# --- Phase 1: Pre-flight checks ---

# Count current archives
BEFORE_COUNT=$(borg list --format '{archive}{NL}' "$REPO" 2>>"$LOG" | wc -l) || {
    log "ABORT: Failed to list archives. Repository may be locked or inaccessible."
    exit 1
}
log "Archives before: $BEFORE_COUNT"

# Archive count checks only activate once the repo has reached MIN_ARCHIVES.
# On a fresh setup it takes several days to accumulate enough archives — that's expected.
PREV_COUNT_FILE="$STATE_DIR/last-archive-count"
if [ -f "$PREV_COUNT_FILE" ]; then
    PREV_COUNT=$(cat "$PREV_COUNT_FILE")
    DROP=$((PREV_COUNT - BEFORE_COUNT))

    if [ "$PREV_COUNT" -ge "$MIN_ARCHIVES" ]; then
        # Check 1: Minimum archive count (catches mass soft-delete attacks)
        if [ "$BEFORE_COUNT" -lt "$MIN_ARCHIVES" ]; then
            log "ABORT: Only $BEFORE_COUNT archives found (expected >= $MIN_ARCHIVES). Possible attack or misconfiguration."
            exit 1
        fi

        # Check 2: Sudden drop since last maintenance (catches targeted deletions)
        if [ "$DROP" -gt "$((PREV_COUNT / 2))" ] && [ "$DROP" -gt 3 ]; then
            log "ABORT: Archive count dropped by $DROP since last maintenance ($PREV_COUNT -> $BEFORE_COUNT). Investigate before proceeding."
            exit 1
        fi
    else
        log "Repo still building up ($PREV_COUNT < $MIN_ARCHIVES last run) — skipping count checks"
    fi
    log "Previous maintenance count: $PREV_COUNT, current: $BEFORE_COUNT (delta: $((BEFORE_COUNT - PREV_COUNT)))"
else
    log "First run — skipping archive count checks"
fi

if [ "$BEFORE_COUNT" -lt "$MIN_ARCHIVES" ]; then
    log "Note: Only $BEFORE_COUNT archives exist (need $MIN_ARCHIVES for safety checks to activate)"
fi

# Check 3: Repository integrity (detect corruption/tampering before making anything permanent)
log "Running repository check (repository-only)..."
if ! borg check --repository-only "$REPO" 2>> "$LOG"; then
    log "ABORT: Repository check failed. Do NOT compact until resolved."
    exit 1
fi
log "Repository check passed"

# Check 4: Monthly data verification (first Sunday of month — checksums all chunks)
DAY_OF_MONTH=$(date +%d)
if [ "$DAY_OF_MONTH" -le 7 ]; then
    log "First week of month — running full data verification (--verify-data)..."
    if ! borg check --verify-data "$REPO" 2>> "$LOG"; then
        log "ABORT: Data verification failed. Chunks may be corrupted or tampered with."
        exit 1
    fi
    log "Data verification passed"
else
    log "Skipping monthly data verification (day $DAY_OF_MONTH, runs on first week only)"
fi

# --- Phase 2: Prune and compact ---

# Prune (mark archives for deletion per retention policy)
# NOTE: Keep these values in sync with borgmatic config (Step 8)
log "Pruning..."
borg prune --keep-daily=7 --keep-weekly=4 --keep-monthly=6 --list "$REPO" 2>&1 | tail -20 >> "$LOG" || {
    log "ABORT: Prune failed."
    exit 1
}

AFTER_COUNT=$(borg list --format '{archive}{NL}' "$REPO" 2>>"$LOG" | wc -l) || {
    log "ABORT: Failed to list archives after prune."
    exit 1
}
log "Archives after prune: $AFTER_COUNT (pruned $((BEFORE_COUNT - AFTER_COUNT)))"

# Compact (permanently removes soft-deleted data — no undo after this)
log "Compacting (threshold: ${COMPACT_THRESHOLD}%)..."
COMPACT_OUTPUT=$(borg compact --verbose --threshold "$COMPACT_THRESHOLD" "$REPO" 2>&1) || {
    log "ABORT: Compact failed."
    exit 1
}
if [ -n "$COMPACT_OUTPUT" ]; then
    echo "$COMPACT_OUTPUT" | tail -5 >> "$LOG"
else
    log "Compact: nothing to do (below ${COMPACT_THRESHOLD}% threshold)"
fi

# --- Phase 3: Save state ---

echo "$AFTER_COUNT" > "$PREV_COUNT_FILE"
log "=== Maintenance completed. Final archive count: $AFTER_COUNT ==="
EOF

sudo chmod +x /usr/local/bin/borg-maintenance.sh
```

**What the safety checks do:**

| Check | Catches | Action |
|-------|---------|--------|
| Minimum archive count | Attacker soft-deleted most/all archives | Aborts before compact |
| Historical comparison | Sudden drop since last maintenance | Aborts if >50% archives vanished |
| Repository integrity | Corruption, partial tampering | Aborts before compact finalizes damage |
| Monthly data verification | Chunk-level corruption/bit rot | Aborts before compact (runs first week of month only) |

Archive count checks (1 and 2) only activate once the repo has reached MIN_ARCHIVES (5 by default). On a fresh setup it takes several days of daily backups to accumulate enough archives — the script logs this and proceeds without checks until then.

If any check fails, the script exits with a non-zero code, which triggers DSM's email notification (configured below). All soft-deleted data remains recoverable from NAS immutable snapshots (Step 11) until you investigate and resolve the issue.

### Test Manually

```bash
# On NAS
sudo /usr/local/bin/borg-maintenance.sh
sudo tail -20 /var/log/borg-maintenance.log
```

### Schedule via DSM Task Scheduler

1. **Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script**
2. **General:** Task name: `Borg Maintenance`, User: `root`
3. **Schedule:** Weekly, Sunday 6:00 AM (after the daily backup and after the daily NAS snapshot from Step 11)
4. **Task Settings:**
   - Run command: `/usr/local/bin/borg-maintenance.sh`
   - Check **Send run details by email**
   - Check **Send run details only when the script terminates abnormally**
   - Enter your email address

This way you only get an email when a safety check fails—not on every successful run.

**Prerequisite:** Email notifications must be configured in **Control Panel → Notification → Email** (SMTP server, port, authentication). Send a test mail from that page to verify.

### Verify Pruning Works

After the first run, check the log:

```bash
# On NAS
tail -20 /var/log/borg-maintenance.log
```

Verify from laptop that archive count matches retention policy:

```bash
export BORG_RSH="ssh -i ~/.ssh/backup_append_only"
borg list ssh://${NAS}${REPO_PATH}
```

## Day-to-Day Operations

Common tasks for managing your backup system.

### Trigger Backup Manually

Run a backup outside the daily schedule (e.g., before a risky upgrade):

```bash
# Via systemd (recommended — uses encrypted credential, runs as service)
sudo systemctl start borgmatic.service

# Watch progress
journalctl -u borgmatic -f
```

### Check Repository Status

```bash
export BORG_RSH="ssh -i ~/.ssh/backup_append_only"
read -rsp "Borg passphrase: " BORG_PASSPHRASE && export BORG_PASSPHRASE && echo

# List all archives (name, date, size)
borg list ssh://${NAS}${REPO_PATH}

# Repository-level stats (total size, deduplication, encryption mode)
borg info ssh://${NAS}${REPO_PATH}

# Detailed info on a specific archive
borg info ssh://${NAS}${REPO_PATH}::archive-name
```

### Browse Archive Contents

Explore what's inside an archive without extracting:

```bash
# List top-level contents of an archive
borg list ssh://${NAS}${REPO_PATH}::archive-name

# List contents of a specific directory
borg list ssh://${NAS}${REPO_PATH}::archive-name home/yourusername/Documents

# Search for a file across an archive
borg list ssh://${NAS}${REPO_PATH}::archive-name | grep "filename"
```

### Extract Files

```bash
# Extract a single file (restores to current directory, preserving path)
borg extract ssh://${NAS}${REPO_PATH}::archive-name home/yourusername/Documents/file.txt

# Extract a directory
borg extract ssh://${NAS}${REPO_PATH}::archive-name home/yourusername/Documents/

# Extract to a specific location
cd /tmp/restore && borg extract ssh://${NAS}${REPO_PATH}::archive-name home/yourusername/Documents/
```

### Delete Archives

**From laptop (soft delete — tagged for deletion, not removed):**

```bash
# Delete a specific archive
borg delete ssh://${NAS}${REPO_PATH}::archive-name

# Delete multiple archives by prefix
borg delete --glob-archives 'laptop-2025-01-*' ssh://${NAS}${REPO_PATH}
```

In append-only mode, these are soft deletes. Data remains until `borg compact` runs on the NAS (Step 12).

**From NAS (permanent deletion — no undo):**

```bash
# SSH to NAS as root, then:
export BORG_PASSPHRASE="$(cat /root/.borg-passphrase)"

# Delete specific archive permanently
borg delete /volume1/backup/laptop::archive-name

# Delete ALL archives (keeps the repository and its encryption key intact)
borg delete --glob-archives '*' /volume1/backup/laptop

# Reclaim disk space
borg compact /volume1/backup/laptop
```

### Reset Entire Repository

If you need to start fresh (e.g., after encryption key change or corrupted repo):

```bash
# On NAS as root — delete and reinitialize
export BORG_PASSPHRASE="$(cat /root/.borg-passphrase)"

# List what's there first
borg list /volume1/backup/laptop

# Delete the repository directory
rm -rf /volume1/backup/laptop

# Reset the maintenance state
rm -f /var/lib/borg-maintenance/last-archive-count
```

Then re-run Step 5 (Initialize Borg Repository) from the laptop.

### Trigger NAS Maintenance Manually

```bash
# On NAS
sudo /usr/local/bin/borg-maintenance.sh
tail -20 /var/log/borg-maintenance.log
```

### Check Btrfs Snapshots

```bash
# List borgmatic's Btrfs snapshots (created during backup)
sudo btrfs subvolume list / | grep borgmatic

# Check disk usage
sudo btrfs filesystem usage /
```

### Check Healthchecks Status

Visit your [Healthchecks.io dashboard](https://healthchecks.io) — it shows the timestamp of your last successful backup and alerts on missed schedules.

## Recovery Procedures

### Recovery Vault (Prepare During Setup)

In a full disaster scenario (stolen laptop, dead disk, ransomware), you need a way to bootstrap recovery with nothing but a browser and your memory. The solution: a KeePassXC database stored on an encrypted paste service and as an email attachment.

**What you need to remember:**
1. KDBX master password
2. Where to find the file (ProtectedText URL + backup email account)

**What to store in the KDBX (one entry per row):**

| Title | Password | Notes |
|-------|----------|-------|
| Borg Backup | _(borg passphrase)_ | `NAS="backup@192.168.1.100"` <br> `REPO_PATH="/volume1/backup/laptop"` <br> (adjust to your setup) |
| SSH backup_append_only | | `mkdir -p ~/.ssh && cat > ~/.ssh/backup_append_only << 'EOF'` <br> _(your key content)_ <br> `EOF` <br> `chmod 600 ~/.ssh/backup_append_only` |
| WireGuard peer | | Peer config **without `Endpoint`** for security |

Replace _(your key content)_ with actual key from `~/.ssh/backup_append_only`. During recovery, paste entire Notes field into terminal.

**Create the vault:**

1. Open KeePassXC → **Database → New Database**
2. Set a strong master password (25+ chars, random, memorized)
3. On the encryption settings screen, click **Advanced Settings** and configure:
   - Encryption Algorithm: **AES 256-bit**
   - Key Derivation Function: **Argon2id (KDBX 4)**
   - Transform rounds: (click Benchmark to calibrate — and enter 5x number that was proposed)
   - Memory Usage: **256 MiB**
   - Parallelism: match your CPU thread count (e.g., 12 for a 6-core/12-thread CPU)

4. Add entries with the secrets listed above
5. Save, then encode for upload:
   ```bash
   base64 DisasterRecovery.kdbx
   ```
   Copy the output — you'll paste it into ProtectedText below.

**Store the vault (two independent copies):**

1. **Email attachment** (primary) — send `DisasterRecovery.kdbx` to your email account. Do not send the master password through the same channel. Gmail/Outlook won't disappear overnight; a free paste service might.

2. **ProtectedText** (backup) — encrypts in-browser, no account needed:
   - Go to `protectedtext.com/your-non-obvious-slug` (use a random-looking slug, not your name)
   - Paste a ready-to-run decode command (see below), set a page password
   - This gives you two layers: page password + KDBX password

   Content to paste on ProtectedText:
   ```
   base64 -d <<'KDBX' > DisasterRecovery.kdbx
   <paste base64 output here>
   KDBX
   ```

**Retrieve during recovery:**

From a live USB with a browser — download the KDBX attachment from your email, or copy the decode command from ProtectedText and paste it into a terminal. Then:

```bash
keepassxc DisasterRecovery.kdbx
```

Now you have your Borg passphrase, SSH key, and NAS connection details — enough to proceed with Pre-Flight below.

**Maintenance:** Update the vault whenever you change your Borg passphrase, SSH key, NAS IP, or WireGuard config. Re-upload to ProtectedText and re-send the email attachment.

### Pre-Flight (Before Any Restore)

Make sure you can actually access the repo from the recovery environment before doing any destructive steps:

```bash
# If Borg isn't installed in the live environment
sudo apt update && sudo apt install -y borgbackup keepassxc

export BORG_RSH="ssh -i ~/.ssh/backup_append_only"
read -rsp "Borg passphrase: " BORG_PASSPHRASE && export BORG_PASSPHRASE && echo

# Verify access and find an archive
borg list ssh://${NAS}${REPO_PATH} | tail -5
```

### Quick Restore Test (Monthly)

Restore a single file to a scratch directory. Start with a dry-run so you see exactly what would be restored:

```bash
mkdir -p ~/restore-test && cd ~/restore-test

# Preview (no changes)
borg extract --dry-run --list ssh://${NAS}${REPO_PATH}::archive-name path/to/file

# Real restore
borg extract ssh://${NAS}${REPO_PATH}::archive-name path/to/file
```

If you need to browse archives before extracting, you can mount the repository with `borg mount` and copy files out (requires FUSE).

### Full System Recovery to New Hardware

If you need to restore to new hardware after a disk failure or ransomware attack.

**Test this in a VM first.** Before you ever need this for real, validate the full flow in VirtualBox or similar. It's much easier to debug partition layouts and bootloader issues in a VM where you can snapshot and retry. VM-specific notes are marked with "**VM:**" below. Use a VM disk that is the same size or larger than your real disk; the DR partition table assumes the target disk is not smaller. If the VM disk is smaller, you must partition manually and may need to skip the storage volume for a quick test.

> **VM:** In VirtualBox, use a SATA controller for `/dev/sda` device names. Enable EFI: VM Settings → System → Motherboard → Enable EFI. Use Bridged Adapter networking so the VM can reach your NAS on the LAN. Take a VM snapshot before starting so you can retry quickly.

#### Boot from Kubuntu live USB

Open a terminal and switch to root (all recovery commands run as root—no need for `sudo` on every line):

```bash
sudo -i
```

#### Restore secrets from Recovery Vault, set variables

```bash
# From Recovery Vault KDBX — "SSH backup_append_only" entry (paste entire Notes field):

# From Recovery Vault KDBX — "Borg Backup" entry:
NAS="backup@192.168.1.100"           # from Notes field
REPO_PATH="/volume1/backup/laptop"   # from Notes field

export BORG_RSH="ssh -i ~/.ssh/backup_append_only"
read -rsp "Borg passphrase: " BORG_PASSPHRASE && export BORG_PASSPHRASE && echo  # from Password field

USERNAME="yourusername"              # your Linux username from the backed-up system

# Disk variables (adjust to match your hardware)
# For SATA drives (sda, sdb, etc.)
DISK=/dev/sda
EFI_PART=/dev/sda1
BOOT_PART=/dev/sda2
SWAP_PART=/dev/sda3
ROOT_PART=/dev/sda4
STORAGE_PART=/dev/sda5

# For NVMe drives, uncomment these instead:
# DISK=/dev/nvme0n1
# EFI_PART=/dev/nvme0n1p1
# BOOT_PART=/dev/nvme0n1p2
# SWAP_PART=/dev/nvme0n1p3
# ROOT_PART=/dev/nvme0n1p4
# STORAGE_PART=/dev/nvme0n1p5
```

#### Recreate partition layout

Using DR metadata from backup:

```bash
mkdir -p /mnt/restore
ARCHIVE=$(borg list ssh://${NAS}${REPO_PATH} | tail -1 | awk '{print $1}')
echo "Using archive: $ARCHIVE"
borg extract ssh://${NAS}${REPO_PATH}::$ARCHIVE var/backup/dr-metadata

# Review partition layout
cat var/backup/dr-metadata/partition-table.sfdisk
cat var/backup/dr-metadata/lsblk.txt

# Apply partition table (CAREFUL - this wipes the disk!)
sfdisk $DISK < var/backup/dr-metadata/partition-table.sfdisk
```

#### Create new LUKS containers with NEW passphrases

```bash
# Swap partition
cryptsetup luksFormat --type luks2 $SWAP_PART
cryptsetup open $SWAP_PART cryptswap
mkswap -L cryptswap /dev/mapper/cryptswap

# Root partition
cryptsetup luksFormat --type luks2 $ROOT_PART
cryptsetup open $ROOT_PART cryptroot

# Storage partition
cryptsetup luksFormat --type luks2 $STORAGE_PART
cryptsetup open $STORAGE_PART cryptstorage
```

#### Verify LUKS containers and swap

```bash
# Verify all containers are open
ls /dev/mapper/crypt*
# Should show: cryptroot cryptstorage cryptswap

# Verify swap has correct signature
blkid /dev/mapper/cryptswap
# Must show: TYPE="swap" LABEL="cryptswap"
# If TYPE="swap" is missing, mkswap failed - run it again:
# mkswap -L cryptswap /dev/mapper/cryptswap
```

#### Create filesystems, LVM, and subvolumes

```bash
# Btrfs for root
mkfs.btrfs -L kubuntu-root /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

# LVM for storage — read VG name and LV size from DR metadata
VG_NAME=$(awk '/VG Name/{print $3; exit}' var/backup/dr-metadata/lvm-vg.txt)
STORAGE_SIZE=$(awk '/LV Name  *storage$/{f=1} f && /LV Size/{gsub(",",".",$3); sub(/iB/,"",$4); print $3$4; exit}' var/backup/dr-metadata/lvm-lv.txt)
echo "VG name: $VG_NAME, storage LV size: $STORAGE_SIZE"
pvcreate /dev/mapper/cryptstorage
vgcreate $VG_NAME /dev/mapper/cryptstorage
lvcreate -L $STORAGE_SIZE -n storage $VG_NAME
lvcreate -l 100%FREE -n storage-nb $VG_NAME
mkfs.ext4 -L storage /dev/$VG_NAME/storage
mkfs.ext4 -L nobackup /dev/$VG_NAME/storage-nb

# Format boot partitions
mkfs.fat -F32 $EFI_PART
mkfs.ext4 $BOOT_PART
```

#### Mount subvolumes

```bash
mount -o subvol=@,compress=zstd:3,noatime /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount -o subvol=@home,compress=zstd:3,noatime /dev/mapper/cryptroot /mnt/home
# Storage volumes mount inside home
mkdir -p /mnt/home/$USERNAME/{storage,storage-nb}
mount /dev/$VG_NAME/storage /mnt/home/$USERNAME/storage
mount /dev/$VG_NAME/storage-nb /mnt/home/$USERNAME/storage-nb
# Boot — mkdir efi AFTER mounting boot (otherwise the mount hides it)
mkdir -p /mnt/boot
mount $BOOT_PART /mnt/boot
mkdir -p /mnt/boot/efi
mount $EFI_PART /mnt/boot/efi
```

#### Restore from Borg

```bash
cd /mnt
ARCHIVE=$(borg list ssh://${NAS}${REPO_PATH} | tail -1 | awk '{print $1}')
echo "Restoring archive: $ARCHIVE"

# Restore everything (borgmatic stores paths at original locations)
# Root files go to /mnt/*, home files go to /mnt/home/* (which is @home subvolume)
borg extract --numeric-ids --progress ssh://${NAS}${REPO_PATH}::$ARCHIVE

# If you prefer selective restore:
# borg extract --numeric-ids --progress ssh://${NAS}${REPO_PATH}::$ARCHIVE --exclude 'home'
# borg extract --numeric-ids --progress ssh://${NAS}${REPO_PATH}::$ARCHIVE home
```

#### Update /etc/fstab and /etc/crypttab

New LUKS containers and filesystems have different UUIDs. This script extracts old UUIDs from the restored configs, gets new ones from the current devices, and replaces them:

```bash
# Extract old UUIDs from restored config files
old_cryptswap=$(awk '/^cryptswap/ {sub("UUID=","",$2); print $2}' /mnt/etc/crypttab)
old_cryptroot=$(awk '/^cryptroot/ {sub("UUID=","",$2); print $2}' /mnt/etc/crypttab)
old_cryptstorage=$(awk '/^cryptstorage/ {sub("UUID=","",$2); print $2}' /mnt/etc/crypttab)
old_btrfs=$(awk '!/^#/ && $2=="/" {sub("UUID=","",$1); print $1}' /mnt/etc/fstab)
old_efi=$(awk '!/^#/ && $2=="/boot/efi" {sub("UUID=","",$1); print $1}' /mnt/etc/fstab)
old_boot=$(awk '!/^#/ && $2=="/boot" {sub("UUID=","",$1); print $1}' /mnt/etc/fstab)

# Get new UUIDs from freshly created devices
new_cryptswap=$(blkid -s UUID -o value $SWAP_PART)
new_cryptroot=$(blkid -s UUID -o value $ROOT_PART)
new_cryptstorage=$(blkid -s UUID -o value $STORAGE_PART)
new_btrfs=$(blkid -s UUID -o value /dev/mapper/cryptroot)
new_efi=$(blkid -s UUID -o value $EFI_PART)
new_boot=$(blkid -s UUID -o value $BOOT_PART)

# Show mapping for verification
printf "\n%-18s %-40s %s\n" "DEVICE" "OLD UUID" "NEW UUID"
printf "%-18s %-40s %s\n" "cryptswap (LUKS)" "$old_cryptswap" "$new_cryptswap"
printf "%-18s %-40s %s\n" "cryptroot (LUKS)" "$old_cryptroot" "$new_cryptroot"
printf "%-18s %-40s %s\n" "storage (LUKS)" "$old_cryptstorage" "$new_cryptstorage"
printf "%-18s %-40s %s\n" "btrfs root" "$old_btrfs" "$new_btrfs"
printf "%-18s %-40s %s\n" "EFI" "$old_efi" "$new_efi"
printf "%-18s %-40s %s\n" "boot" "$old_boot" "$new_boot"

# Replace in crypttab and fstab
sed -i "s/$old_cryptswap/$new_cryptswap/g" /mnt/etc/crypttab
sed -i "s/$old_cryptroot/$new_cryptroot/g" /mnt/etc/crypttab
sed -i "s/$old_cryptstorage/$new_cryptstorage/g" /mnt/etc/crypttab
sed -i "s/$old_btrfs/$new_btrfs/g" /mnt/etc/fstab
sed -i "s/$old_efi/$new_efi/g" /mnt/etc/fstab
sed -i "s/$old_boot/$new_boot/g" /mnt/etc/fstab

# Verify results
echo ""
echo "=== crypttab ==="
cat /mnt/etc/crypttab
echo ""
echo "=== fstab ==="
cat /mnt/etc/fstab
```

If any UUID in the mapping shows empty, check that the device variables (`$ROOT_PART`, etc.) match your disk layout.

#### Reinstall bootloader and regenerate initramfs

```bash
# Bind system directories (from outside chroot)
for i in dev dev/pts proc sys run; do mount --bind /$i /mnt/$i; done

# Make EFI variables visible in chroot (requires Live ISO booted in UEFI mode)
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || \
  echo "Warning: efivars not available. Reboot Live ISO in UEFI mode if grub-install fails."

chroot /mnt /bin/bash

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Kubuntu --uefi-secure-boot
update-grub

# Recreate dirs excluded from backup (borgmatic excludes /tmp)
mkdir -p /tmp
chmod 1777 /tmp

dracut -f --regenerate-all

exit
```

#### Unmount and reboot

```bash
cd /

umount /mnt/sys/firmware/efi/efivars 2>/dev/null
for i in run sys proc dev/pts dev; do umount -l /mnt/$i; done

umount /mnt/home/$USERNAME/storage-nb
umount /mnt/home/$USERNAME/storage
umount /mnt/home
umount /mnt/boot/efi
umount /mnt/boot
umount /mnt

vgchange -an $VG_NAME
cryptsetup close cryptstorage
cryptsetup close cryptroot
cryptsetup close cryptswap

reboot
```

#### Re-enroll TPM

After reboot into the restored system (unlock with LUKS passphrase), new hardware has different PCR values:

```bash
# Enroll all 3 LUKS partitions (swap first, then root, then storage)
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true $SWAP_PART
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true $ROOT_PART
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true $STORAGE_PART
sudo dracut -f --regenerate-all
```

> **VM:** Skip TPM re-enrollment — VMs typically don't have a TPM device. Just reboot and verify you can log in and that `/`, `/home`, `/boot`, `/boot/efi` are mounted correctly.

#### Re-create systemd encrypted credential

`systemd-creds encrypt` binds credentials to the TPM2 chip and host key (`/var/lib/systemd/credential.secret`). After restoring to new hardware, the borgmatic service will fail to decrypt the old credential. Re-create it:

```bash
sudo mkdir -p /etc/credstore.encrypted
read -rsp "Borg passphrase: " BORG_PASS && echo
echo -n "$BORG_PASS" | sudo systemd-creds encrypt --name=borg-passphrase - /etc/credstore.encrypted/borg-passphrase
unset BORG_PASS
sudo chmod 600 /etc/credstore.encrypted/borg-passphrase
```

Verify the borgmatic service can decrypt it:

```bash
sudo systemctl start borgmatic.service
journalctl -u borgmatic -n 20
```

### Partial Recovery (Single Directory)

Restore a specific directory without full system recovery:

```bash
export BORG_RSH="ssh -i ~/.ssh/backup_append_only"
ARCHIVE=$(borg list ssh://${NAS}${REPO_PATH} | tail -1 | awk '{print $1}')
borg extract ssh://${NAS}${REPO_PATH}::$ARCHIVE path/to/directory
```

## Notes

**Btrfs needs breathing room:**
Keep 15-20% free space for CoW operations. Monitor with `btrfs filesystem usage /`. Borgmatic automatically cleans up its snapshots after backup, but if space runs low, check for orphaned snapshots with `sudo btrfs subvolume list /`.

**TPM breaks after firmware updates:**
PCR 0 measures firmware code. After a BIOS/UEFI update, boot with your LUKS passphrase, then re-enroll all three LUKS containers (replace device paths with yours, e.g., `/dev/nvme0n1p3` for NVMe):
```bash
# Re-enroll swap partition
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/sda3
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true /dev/sda3

# Re-enroll root partition
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/sda4
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true /dev/sda4

# Re-enroll storage partition
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/sda5  # storage
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true /dev/sda5

sudo dracut -f --regenerate-all
```

**Test or regret later:**
Monthly: restore random files. Quarterly: boot from a restored VM or spare disk. Annually: full disaster recovery drill.

**Btrfs snapshots:**
Borgmatic 1.9.4+ has native btrfs snapshot support—no external tools (btrbk, snapper) needed. It auto-detects subvolumes from `source_directories` and creates/cleans up snapshots automatically.

**Borg check schedule:**
- Weekly: `--repository-only` (fast, checks metadata)
- Monthly: full check (verifies archive integrity)
- Quarterly: `--verify-data` (slow, checksums all data blocks)

**Storage layout rationale:**
- Separate LUKS swap partition simplifies hibernation setup and avoids Btrfs swapfile limitations
- `~/storage` on LVM provides flexible resizing without repartitioning
- Separate `~/storage-nb` volume for data you explicitly don't want backed up (real-time sync folders, large caches)
- All three LUKS containers (swap, root, storage) unlock with same PIN via TPM2
- LVM volumes mounted in home keeps all user data in one logical place (`~/repos`, `~/data`, `~/storage`)

## Troubleshooting

**Borgmatic fails with "Connection closed by remote host":**
Check key permissions (`chmod 600 ~/.ssh/backup_append_only`), verify forced-command on NAS, and test with `ssh -i ~/.ssh/backup_append_only -v $NAS`.

**Btrfs snapshot fails with "no space left":**
Run `btrfs filesystem usage /` to check actual usage. Delete old snapshots with `sudo btrfs subvolume delete /.borgmatic-snapshot-*` (borgmatic creates snapshots with this prefix). If still low, increase disk size or reduce retention period.

**Healthchecks.io not receiving pings:**
Verify network connectivity and check the ping URL in borgmatic config. Test manually: `curl -fsS --retry 3 https://hc-ping.com/your-uuid`.

**Cannot restore from append-only repository:**
The `borg extract` command works fine—only delete operations are blocked. If the forced-command interferes, run `borg extract` directly on the NAS.

**TPM unlock fails after system update:**
Boot with your LUKS passphrase. Check if PCR values changed (`sudo tpm2_pcrread`), then re-enroll TPM (see Notes section).

**Borg repository shows "No space" but NAS has space:**
Check the quota for your backup user (`quota -u backup`) and any filesystem quotas on the NAS. Compact the repository with `borg compact` directly on the NAS.

## References

- [Borg Backup Documentation](https://borgbackup.readthedocs.io/)
- [Borgmatic Configuration Reference](https://torsion.org/borgmatic/reference/configuration/)
- [Borgmatic Btrfs Snapshots](https://torsion.org/borgmatic/how-to/snapshot-your-filesystems/)
- [How I Use Borg for Ransomware-Resilient Backups](https://artemis.sh/2022/06/22/how-i-use-borg.html)
- [Ransomware Resistant Backups with Borg and Restic](https://www.marcusb.org/posts/ransomware-resistant-backups/)
- [Healthchecks.io Documentation](https://healthchecks.io/docs/)
- [Btrfs Snapshot Management](https://wiki.archlinux.org/title/Btrfs#Snapshots)
- [Borg Security Documentation](https://borgbackup.readthedocs.io/en/stable/internals/security.html)
- [Borg Init Documentation](https://borgbackup.readthedocs.io/en/stable/usage/init.html)
