# Full-Disk Encryption: LUKS2 + TPM2 PIN Unlock Guide

> Tested on Kubuntu 25.10. Should work on any Ubuntu-based distro with dracut and systemd-cryptenroll support.

## What you get

- **Full-disk encryption** — all data at rest (root, home, swap) is encrypted with LUKS2. A stolen or lost laptop leaks nothing.
- **Single PIN at boot** — the TPM chip stores the encryption key and releases it after you type a short PIN. No long passphrase, no typing it twice (swap + root unlock automatically together).
- **Tamper-aware unlock policy** — the TPM key is bound to PCRs **0+7+14** (firmware code, Secure Boot policy, shim/MOK state). If those measurements change, TPM auto-unlock is denied and you fall back to a recovery passphrase.
- **Unencrypted `/boot` with measured integrity** — `/boot` and ESP are readable (not encrypted), but with Secure Boot + TPM policy, unauthorized boot-chain changes block automatic unlock.
- **Predictable update behavior** — kernel/initramfs updates usually do not affect PCR 0+7+14. Firmware updates, Secure Boot key/policy changes, or MOK changes can require TPM re-enrollment.
- **Encrypted swap (hibernation-ready)** — swap lives in its own LUKS2 partition. If you enable suspend-to-disk later, the RAM image is written only to encrypted storage.
- **Btrfs or ext4 + LVM** — your choice of filesystem inside the encrypted container. Btrfs gives you snapshots and compression; ext4 + LVM gives you a proven, simple stack.
- **Dual-boot friendly** — the Windows ESP and partitions stay untouched. Linux gets its own partitions in the remaining free space.

## Choosing a filesystem

This tutorial supports two layouts. Pick one and follow the matching blocks throughout.

| | **Btrfs** | **ext4 + LVM** |
|---|---|---|
| Snapshots | Native, instant, near-zero cost. Subvolumes share free space — no pre-allocation needed. | Classic LVM snapshots — CoW at block level. Require free space in VG (this guide reserves 10 GiB). Performance degrades while a snapshot is active. |
| Compression | Built-in (`zstd:1`). Transparent, saves 20–40 % on typical desktop data. | None at filesystem level. |
| Data integrity | Checksums on data + metadata. Detects silent corruption (bit rot). | Journaling protects metadata only. No checksums on data. |
| Resize | Online grow **and** shrink. | ext4 grow is online. **Shrink requires unmount** (problematic for `/`). |
| `/home` isolation | Subvolume `@home` — shares pool with `@`, no fixed size split. | Separate LV `/dev/vg0/home` — fixed allocation, can grow online into VG free space. |
| Maturity | Default in Fedora, openSUSE since ~2020. Well-tested on desktop. RAID 5/6 still unstable. | ext4 is the oldest and most battle-tested Linux filesystem. LVM is a kernel staple since 2.6. |
| Performance | CoW causes **write amplification** (1.1–4.2×) — random writes to large files (databases, VM images) can be significantly slower. Workaround: `chattr +C` disables CoW per-file (also disables compression + checksums for that file). Note: when a snapshot exists, Btrfs forces CoW even on `nodatacow` files to protect snapshot data. Reads benefit from `zstd:1` compression (less I/O). Everyday desktop use: no noticeable difference. | Fastest raw I/O — no CoW overhead, no checksums. Consistently low latency on all write patterns. Best for write-heavy workloads (databases, large VM images). |
| Recovery | Snapshots make rollback trivial — restore a broken system in seconds. `btrfs check`, `btrfs restore` for filesystem-level repair. Backup tools (borg, restic) work equally well on both. | `e2fsck`, `testdisk`, `photorec` — mature low-level repair tools. No native snapshot rollback — recovery means restoring from backup or `e2fsck`. |
| Best for | Users who want snapshots, compression, and flexible storage without managing volumes. | Users who prefer a proven, simple filesystem and only need occasional snapshots (e.g., before backup). |

**TL;DR:** Btrfs is more capable out of the box. ext4 + LVM is a conservative choice when you want maximum compatibility and simple recovery.

---

## Swap size

Simple rule of thumb:

- **RAM ≤ 8 GiB** → swap = **2 × RAM**
- **RAM > 8 GiB** → swap = **RAM + 8 GiB**

This always leaves enough room for **hibernation** (suspend-to-disk), which writes all RAM contents to swap. If you don't plan to hibernate, you could get away with much less (4–8 GiB), but encrypted swap is a dedicated LUKS partition — you can't easily resize it later, so it's better to over-allocate slightly.

The partition table below uses **8 GiB** as the example (`p3`). **Adjust to match your RAM** — e.g., 32 GiB for 16 GiB RAM, 40 GiB for 32 GiB RAM.

---

## Why this workflow

- Calamares manual install cannot target LUKS/DM devices directly (LP #2137154).
- cryptsetup-initramfs ignores TPM2 for root (LP #1980018), so we use dracut.

---

## How to use this guide

- **Single-line commands** — copy and paste one by one.
- **Multi-line blocks with `EOF`/heredocs** (e.g., `cat <<EOF ... EOF`) — copy and paste the **entire block at once**, including the closing `EOF`. If you paste line by line, the shell will wait for `EOF` and the command won't execute.
- **Blocks with variables** (e.g., `$DISK`, `$SWAP_GIB`) — make sure the variables are set earlier in the same shell session. If you closed the terminal or rebooted, re-export them.
- **Btrfs / ext4 + LVM blocks** — run only the block matching your chosen filesystem, skip the other.

---

## Testing in VirtualBox

You can practice this entire tutorial in a VM before touching real hardware.

**VM settings (before first boot):**

**Required (security + boot flow):**
- **VirtualBox version:** use **7.x** (older versions may not expose TPM 2.0 / Secure Boot in GUI).
- **System → Motherboard:** enable **EFI** (check *Enable EFI*).
- **System → Motherboard:** enable **Secure Boot** (check *Enable Secure Boot*; requires EFI).
- **System → Motherboard:** enable **TPM**, version **2.0**.
- **Storage:** attach the Kubuntu ISO as an optical drive.

**Recommended (for smooth testing):**
- **General:** Type `Linux`, Version `Ubuntu (64-bit)`.
- **System:** 4 vCPUs, 4-8 GiB RAM.
- **Disk:** at least 50 GiB (enough for ESP + boot + swap + LUKS + temp). If testing the **ext4 + LVM** path, use a larger disk (~100 GiB+) — the root LV alone needs >= 50 GiB and you still need space for home LV + 10 GiB snapshot reserve.
- **Display:** set Graphics Controller to **VBoxSVGA** and Video Memory to **128 MB**.

**If the installed system doesn't boot (black screen / no display):**

Change **Display → Graphics Controller** to **VBoxSVGA**. The default VMSVGA sometimes doesn't initialize the framebuffer correctly after GRUB hands off to the kernel.

---

## Step 0: Firmware prep

Enable in BIOS/UEFI:

- UEFI mode (no CSM)
- Secure Boot **enabled**
- TPM 2.0 **enabled**

---

## Partition layout (example)

| Partition | Size | Filesystem | Mount | Notes |
|-----------|------|------------|-------|-------|
| p1 | 1 GiB | FAT32 | /boot/efi | ESP (reuse on dual-boot) |
| p2 | 1 GiB | ext4 | /boot | Unencrypted |
| p3 | 8 GiB | LUKS2 → swap | — | Encrypted swap |
| p4 | Remaining - 20 GiB | LUKS2 → Btrfs / ext4+LVM | — | Main encrypted container |
| p5 | 20 GiB | ext4 (encrypted) | / | TEMP install (deleted later) |

---

## Step 1: Verify firmware settings

Boot the Live ISO (Try Kubuntu) and confirm Secure Boot + TPM are active:

```bash
sudo -i

mokutil --sb-state
# Expected: SecureBoot enabled

if [ -e /dev/tpm0 ] || [ -e /dev/tpmrm0 ]; then
  ls /dev/tpm0 /dev/tpmrm0 2>/dev/null
else
  echo "No TPM device found"
fi
# Expected: at least one device path listed above — if not, enable TPM in BIOS
```

If either check fails, reboot into BIOS/UEFI and fix it (see Step 0).

---

## Step 2: Create partitions

Use your real disk device. Replace sizes to fit your disk.

> **SATA vs NVMe naming:**
> - SATA drives: `/dev/sda`, partitions: `/dev/sda1`, `/dev/sda2`, ...
> - NVMe drives: `/dev/nvme0n1`, partitions: `/dev/nvme0n1p1`, `/dev/nvme0n1p2`, ...

Check disk size and free space first:

```bash
# Adjust device name for your hardware
sudo parted /dev/sda unit GiB print
# or: sudo parted /dev/nvme0n1 unit GiB print
```

> **Note:** On a fresh disk with no partition table you will see `Error: unrecognised disk label` — this is expected and safe to ignore. The `mklabel gpt` command below creates the partition table.

### A) Fresh disk

```bash
# ============================================
# DISK VARIABLES - adjust to match your hardware!
# ============================================
# SATA drive:
DISK=/dev/sda
# NVMe drive (uncomment if needed):
# DISK=/dev/nvme0n1
DISK_SIZE=$(parted -s $DISK unit GiB print | awk '/^Disk \/dev/{gsub("GiB",""); printf "%d", $3}')
echo "Disk size: ${DISK_SIZE} GiB"

# Swap size — see "Swap size" section above; adjust if needed
SWAP_GIB=8

# Calculate partition boundaries
SWAP_END=$((2 + SWAP_GIB))
LUKS_END=$((DISK_SIZE - 20))
echo "Swap: 2–${SWAP_END} GiB, LUKS: ${SWAP_END}–${LUKS_END} GiB"

# Create partitions (scripted mode so variables expand)
parted -s $DISK mklabel gpt
parted -s $DISK mkpart ESP fat32 0% 1GiB
parted -s $DISK set 1 esp on
parted -s $DISK mkpart BOOT ext4 1GiB 2GiB
parted -s $DISK mkpart SWAP 2GiB ${SWAP_END}GiB
parted -s $DISK mkpart LUKS ${SWAP_END}GiB ${LUKS_END}GiB
parted -s $DISK unit GiB print
```

### B) Dual-boot (Windows)

**Prerequisites (do this in Windows first):**

1. **Disable Fast Startup and hibernation** — otherwise Windows locks the disk and Linux can't safely access shared partitions.
2. **Shrink the Windows partition** — open Disk Management (`diskmgmt.msc`), right-click the main NTFS partition → Shrink Volume. Free up at least ~100 GiB (more is better). The free space must appear as "Unallocated" in Disk Management.

**In the Live ISO:**

The script below auto-detects the largest free space block on the disk and creates Linux partitions there. The existing ESP is reused (not formatted).

```bash
# ============================================
# DISK VARIABLES - adjust to match your hardware!
# ============================================
# SATA drive:
DISK=/dev/sda
# NVMe drive (uncomment if needed):
# DISK=/dev/nvme0n1

# Show current layout with free space
parted -s $DISK unit GiB print free

# Auto-detect largest free space block
eval $(parted -s $DISK unit GiB print free | awk '/Free Space/{gsub("GiB",""); size=$3+0; if(size>max){max=size; s=$1+0; e=$2+0}} END{printf "FREE_START=%d\nFREE_END=%d\nFREE_SIZE=%d", s, e, max}')
echo "Largest free block: ${FREE_START}–${FREE_END} GiB (${FREE_SIZE} GiB)"

# Swap size — see "Swap size" section above; adjust if needed
SWAP_GIB=8

# Calculate partition boundaries (within free space)
BOOT_END=$((FREE_START + 1))
SWAP_END=$((BOOT_END + SWAP_GIB))
LUKS_END=$((FREE_END - 20))
echo "BOOT: ${FREE_START}–${BOOT_END} GiB, SWAP: ${BOOT_END}–${SWAP_END} GiB"
echo "LUKS: ${SWAP_END}–${LUKS_END} GiB, TEMP: ${LUKS_END}–${FREE_END} GiB"

# Create Linux partitions in free space (existing partitions untouched)
parted -s $DISK mkpart BOOT ext4 ${FREE_START}GiB ${BOOT_END}GiB
parted -s $DISK mkpart SWAP ${BOOT_END}GiB ${SWAP_END}GiB
parted -s $DISK mkpart LUKS ${SWAP_END}GiB ${LUKS_END}GiB
parted -s $DISK unit GiB print
```

**Verify:** the new partitions should appear after the Windows partitions. The existing Windows ESP (`boot, esp` flags) is reused as `/boot/efi` — note its partition number for Step 3 (typically `sda1` or `sda2`). The 20 GiB of free space at the end is for the TEMP install.

---

## Step 3: Temporary install

This is only to get a working Kubuntu system to copy later.

Start the installer from the live session (terminal):

```bash
calamares -d
```

**Installer choices (Manual partitioning):**

> Calamares does not show GPT partition names — use size and filesystem type to identify each partition:
>
> | Partition | Size | Filesystem | Action in Calamares |
> |-----------|------|------------|---------------------|
> | sda1 / nvme0n1p1 | ~1 GiB | FAT32 | Mount `/boot/efi`. Fresh disk: format FAT32. Dual-boot: **do not format**. Flags: **boot/esp**. |
> | sda2 / nvme0n1p2 | 1 GiB | ext4 | Mount `/boot`, format ext4 |
> | sda3 | 8 GiB | LUKS2 | **Do not touch** (swap — configured later) |
> | sda4 | remaining | LUKS2 | **Do not touch** (root — configured later) |
> | Free Space | 20 GiB | — | Select → create **encrypted ext4** partition, mount `/` (this is TEMP) |
>
> Dual-boot: partition numbers will be higher — match by size and type.

If the installer crashes, check the terminal output (`-d` gives verbose logging). A common error is `Could not close encrypted partition on the target system` — Calamares tries to `cryptsetup close` the LUKS container during cleanup but it's already been unmounted. If the install reached the final cleanup stage (you'll see `umount` and `cryptsetup close` lines in the log), the system was written successfully and you can safely ignore the crash and continue to Step 4.

**After booting into the temp system:**

```bash
sudo apt update
sudo apt install -y \
  cryptsetup cryptsetup-initramfs \
  btrfs-progs lvm2 rsync efibootmgr \
  dracut tpm2-tools
```

After the packages are installed, reboot back into the Live ISO for Step 4.

---

## Step 4: Create LUKS2 containers (Live ISO)

This builds the final encrypted layout: separate LUKS for swap and root.

**Reboot into the Live ISO** (Try Kubuntu) and open a terminal. Do **not** run these commands inside the temporary install.

> **VirtualBox:** The disk takes priority after install. To boot from Live ISO, run from the temp system:
> ```bash
> systemctl reboot --firmware-setup
> ```
> In the EFI menu select **Boot Manager** → optical drive.

```bash
sudo -i

# ============================================
# PARTITION VARIABLES - adjust to match your hardware!
# Set these ONCE at the start of this Live ISO session
# ============================================
# SATA drive (fresh install):
export EFI_PART=/dev/sda1
export BOOT_PART=/dev/sda2
export SWAP_PART=/dev/sda3
export SYSTEM_PART=/dev/sda4
export TEMP_PART=/dev/sda5

# NVMe drive (uncomment all if needed):
# export EFI_PART=/dev/nvme0n1p1
# export BOOT_PART=/dev/nvme0n1p2
# export SWAP_PART=/dev/nvme0n1p3
# export SYSTEM_PART=/dev/nvme0n1p4
# export TEMP_PART=/dev/nvme0n1p5

# Dual-boot: partition numbers will differ! Use 'lsblk' to verify.
# ============================================

# Swap partition
cryptsetup luksFormat --type luks2 "$SWAP_PART"
cryptsetup open "$SWAP_PART" cryptswap
mkswap -L cryptswap /dev/mapper/cryptswap

# Root partition
cryptsetup luksFormat --type luks2 "$SYSTEM_PART"
cryptsetup open "$SYSTEM_PART" cryptroot
```

**Btrfs:**

```bash
mkfs.btrfs -L kubuntu-root /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

mount -o subvol=@,compress=zstd:1,noatime /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home /mnt/boot /mnt/boot/efi
mount -o subvol=@home,compress=zstd:1,noatime /dev/mapper/cryptroot /mnt/home
```

**ext4 + LVM**:

```bash
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot

# Check available space
VG_G=$(vgs --noheadings --nosuffix --units g -o vg_size vg0 | awk '{printf "%d", $1}')
echo "VG size: ${VG_G}G"

# Root LV — fixed size (min 50 GiB; 100 GiB recommended for 500 GB+ disks)
lvcreate -L 100G -n root vg0  # VirtualBox: use 30G instead

# Home LV — rest minus 10 GiB (reserved for LVM snapshots)
lvcreate -l 100%FREE -n home vg0
lvreduce -L -10G /dev/vg0/home -y

mkfs.ext4 -L kubuntu-root /dev/vg0/root
mkfs.ext4 -L kubuntu-home /dev/vg0/home

mount /dev/vg0/root /mnt
mkdir -p /mnt/home /mnt/boot /mnt/boot/efi
mount /dev/vg0/home /mnt/home
```

---

## Step 5: Copy the temporary system

Copy the temp system into the new LUKS root.

```bash
mount "$BOOT_PART" /mnt/boot
mount "$EFI_PART" /mnt/boot/efi

mkdir -p /tmp/src
cryptsetup open "$TEMP_PART" temp_crypt
mount -o ro /dev/mapper/temp_crypt /tmp/src

rsync -aAXH --numeric-ids --sparse --info=progress2 \
  --exclude='/dev/*' \
  --exclude='/proc/*' \
  --exclude='/sys/*' \
  --exclude='/run/*' \
  --exclude='/mnt/*' \
  --exclude='/media/*' \
  --exclude='/swap/*' \
  /tmp/src/ /mnt/

umount /tmp/src
cryptsetup close temp_crypt
```

---

## Step 6: Chroot + config

Fix mounts and initramfs so the new system can unlock root at boot.

At this point you should have:

- `/mnt` → Btrfs subvol **@** on `/dev/mapper/cryptroot`, or ext4 on `/dev/vg0/root`
- `/mnt/home` → Btrfs subvol **@home**, or ext4 on `/dev/vg0/home`
- `/mnt/boot` → unencrypted **/boot** partition
- `/mnt/boot/efi` → **ESP**
- `/dev/mapper/cryptswap` → encrypted swap (not mounted yet)

**Enter chroot:**

```bash
for i in dev dev/pts proc sys run; do mount --bind /$i /mnt/$i; done

# Make EFI variables visible in chroot (requires Live ISO booted in UEFI mode)
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || \
  echo "Warning: efivars not available. Reboot Live ISO in UEFI mode if grub-install fails."

chroot /mnt /bin/bash
```

**Verify variables carried from Step 4:**

```bash
echo "SWAP_PART=$SWAP_PART  SYSTEM_PART=$SYSTEM_PART"
# If empty — re-export them (see Step 4)
```

### /etc/fstab

Replace the temporary install mounts for `/`, `/home`. Keep existing `/boot` and `/boot/efi` entries.

```bash
cp /etc/fstab /etc/fstab.bak

# Keep /boot and /boot/efi, remove old /, /home, and swap lines
grep -E '^\s*(#|$)|/boot' /etc/fstab.bak > /etc/fstab
```

**Btrfs:**

```bash
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
cat <<EOF >> /etc/fstab
UUID=$ROOT_UUID  /      btrfs  subvol=@,compress=zstd:1,noatime      0 0
UUID=$ROOT_UUID  /home  btrfs  subvol=@home,compress=zstd:1,noatime  0 0
/dev/mapper/cryptswap  none  swap  sw  0 0
EOF
```

**ext4 + LVM:**

```bash
cat <<EOF >> /etc/fstab
/dev/vg0/root  /      ext4  noatime,errors=remount-ro  0 1
/dev/vg0/home  /home  ext4  noatime                    0 2
/dev/mapper/cryptswap  none  swap  sw  0 0
EOF
```

```bash
cat /etc/fstab
```

**Verify fstab:**
- ✅ `/boot/efi` → `vfat` (EFI partition)
- ✅ `/boot` → `ext4` (unencrypted boot)
- ✅ `/` → Btrfs: UUID of cryptroot, or ext4+LVM: `/dev/vg0/root`
- ✅ `/home` → Btrfs: `subvol=@home` with same UUID, or ext4+LVM: `/dev/vg0/home`
- ✅ swap → `/dev/mapper/cryptswap`
- ❌ No references to old `luks-*` UUIDs or temp install

### /etc/crypttab

```bash
# Uses SWAP_PART and SYSTEM_PART set above
SWAP_UUID=$(cryptsetup luksUUID "$SWAP_PART")
SYSTEM_UUID=$(cryptsetup luksUUID "$SYSTEM_PART")

# Remove any existing entries
sed -i '/^luks-/d' /etc/crypttab
sed -i '/^cryptroot/d' /etc/crypttab
sed -i '/^cryptswap/d' /etc/crypttab

cat >> /etc/crypttab <<EOF
cryptswap UUID=$SWAP_UUID none luks,discard
cryptroot UUID=$SYSTEM_UUID none luks,discard
EOF

cat /etc/crypttab
```

**Verify crypttab:**
- ✅ `cryptswap` → UUID of your SWAP partition (sda3 or nvme0n1p3)
- ✅ `cryptroot` → UUID of your SYSTEM partition (sda4 or nvme0n1p4)
- ✅ Both have `luks,discard`
- ❌ No old `luks-*` entries from temp install

**Quick UUID check:**
```bash
echo "crypttab swap UUID: $(grep cryptswap /etc/crypttab | grep -oP 'UUID=\K[^ ]+')"
echo "actual swap UUID:   $(cryptsetup luksUUID $SWAP_PART)"
echo "crypttab root UUID: $(grep cryptroot /etc/crypttab | grep -oP 'UUID=\K[^ ]+')"
echo "actual root UUID:   $(cryptsetup luksUUID $SYSTEM_PART)"
```

### Dracut + GRUB

Build the initramfs and install GRUB:

```bash
# Remove any leftover rd.luks.uuid=... from the temp install
sed -i 's/ rd.luks.uuid=[^ ]*//g' /etc/default/grub
```

**Btrfs:**

```bash
cat > /etc/dracut.conf.d/10-crypt-tpm2.conf <<'CONF'
hostonly="yes"
add_dracutmodules+=" crypt tpm2-tss systemd "
install_items+=" /etc/crypttab "
CONF
```

**ext4 + LVM:**

```bash
cat > /etc/dracut.conf.d/10-crypt-tpm2.conf <<'CONF'
hostonly="yes"
add_dracutmodules+=" crypt tpm2-tss systemd lvm "
install_items+=" /etc/crypttab "
CONF
```

```bash
dracut -f --regenerate-all

grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=Kubuntu --uefi-secure-boot

update-grub
```

**Verify initramfs was created:**

```bash
ls -la /boot/initrd.img-*
```

### Exit chroot + unmount

```bash
exit

umount /mnt/sys/firmware/efi/efivars
for i in run sys proc dev/pts dev; do umount -l /mnt/$i; done

umount /mnt/home
umount /mnt/boot/efi
umount /mnt/boot
umount /mnt

vgchange -an vg0 2>/dev/null   # ext4 + LVM only
cryptsetup close cryptswap
cryptsetup close cryptroot
```

**Reboot into the new system:**

```bash
reboot
```

You will be prompted for the LUKS passphrase **twice** (root + swap) if passphrases are different. After successful boot, continue to Step 7.

---

## Step 7: Enroll TPM2 with PIN

PCR set: **0+7+14** (firmware code + Secure Boot policy + shim/MOK state).

**Note:** PCR 0 changes on firmware updates, PCR 7 on Secure Boot key/policy changes, PCR 14 on MOK changes. Keep your LUKS passphrase for recovery and re-enroll TPM after such changes.

```bash
# Verify TPM is available
sudo tpm2_getcap properties-fixed | head

# ============================================
# PARTITION VARIABLES - adjust to match your hardware!
# ============================================
# SATA (fresh install):
SWAP_PART=/dev/sda3
SYSTEM_PART=/dev/sda4

# NVMe (uncomment if needed):
# SWAP_PART=/dev/nvme0n1p3
# SYSTEM_PART=/dev/nvme0n1p4
# ============================================

# Wipe any existing TPM slots first (may fail if none exists)
sudo systemd-cryptenroll --wipe-slot=tpm2 "$SWAP_PART" 2>/dev/null || true
sudo systemd-cryptenroll --wipe-slot=tpm2 "$SYSTEM_PART" 2>/dev/null || true

# Enroll TPM with PIN (same PIN for both)
sudo systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=0+7+14 \
  --tpm2-with-pin=true \
  "$SWAP_PART"

sudo systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=0+7+14 \
  --tpm2-with-pin=true \
  "$SYSTEM_PART"

# Update crypttab to use TPM (idempotent per-entry)
# Adds tpm2-device=auto to cryptroot/cryptswap only if missing
sudo sed -i -E '/^(cryptswap|cryptroot)[[:space:]]/ {/tpm2-device=auto/! s@([[:space:]]+[^[:space:]]+[[:space:]]+none[[:space:]]+[^[:space:]]+)@\1,tpm2-device=auto@ }' /etc/crypttab

# Rebuild initramfs
sudo dracut -f --regenerate-all
```

**Verify enrollment:**

```bash
sudo systemd-cryptenroll "$SWAP_PART"
sudo systemd-cryptenroll "$SYSTEM_PART"
```

You should see both a `password` slot and a `tpm2` slot for each partition.

Reboot to test TPM + PIN unlock:

```bash
reboot
```

---

## Step 8: Backup LUKS headers (critical)

LUKS header stores keyslots and encryption metadata. If this header gets corrupted, data may be unrecoverable even if you still know the passphrase. Do this right after TPM enrollment and repeat after any key-management change (`luksAddKey`, `luksKillSlot`, `systemd-cryptenroll --wipe-slot`, etc.).

**1. Set output directory (path only):**

```bash
export OUT_DIR="$HOME/luks-header-backups-$(date +%Y%m%d-%H%M%S)"
echo "$OUT_DIR"
```

**2. Run backup script (auto-detects all LUKS devices):**

```bash
bash <<'EOF'
set -euo pipefail

: "${OUT_DIR:?Set OUT_DIR first. Example: export OUT_DIR=\"\$HOME/luks-header-backups-\$(date +%Y%m%d-%H%M%S)\"}"
mkdir -p "$OUT_DIR"

mapfile -t LUKS_DEVS < <(lsblk -rpo NAME,FSTYPE | awk '$2=="crypto_LUKS" {print $1}')
if [ "${#LUKS_DEVS[@]}" -eq 0 ]; then
  echo "No LUKS devices detected (FSTYPE=crypto_LUKS)."
  exit 1
fi

echo "Detected LUKS devices:"
printf ' - %s\n' "${LUKS_DEVS[@]}"

for dev in "${LUKS_DEVS[@]}"; do
  name=$(basename "$dev" | sed 's/[^A-Za-z0-9._-]/_/g')
  sudo cryptsetup luksHeaderBackup "$dev" --header-backup-file "$OUT_DIR/luks-header-$name.bin"
  sudo cryptsetup luksDump "$dev" > "$OUT_DIR/luks-$name.txt"
done

# Header files are typically root-owned (created by sudo cryptsetup),
# so compute checksums as root and save SHA256SUMS as root too.
sudo sha256sum "$OUT_DIR"/luks-header-*.bin | sudo tee "$OUT_DIR/SHA256SUMS" > /dev/null
echo "LUKS header backup complete: $OUT_DIR"
sudo ls -lh "$OUT_DIR"
EOF
```

Store these files in at least two places outside the encrypted system disk (for example: encrypted USB + secure cloud vault).

If you also use [`system-backup-disaster-recovery.md`](./system-backup-disaster-recovery.md), its script already runs `cryptsetup luksHeaderBackup` for all detected LUKS devices.

---

## Step 9: Remove temp partition + expand LUKS

Boot into Live ISO (VirtualBox: see `systemctl reboot --firmware-setup` tip in Step 4):

```bash
sudo -i

# ============================================
# PARTITION VARIABLES - adjust to match your hardware!
# ============================================
# SATA drive (fresh install):
DISK=/dev/sda
LUKS_PART_NUM=4
TEMP_PART_NUM=5
SYSTEM_PART=/dev/sda4

# NVMe drive (uncomment if needed):
# DISK=/dev/nvme0n1
# LUKS_PART_NUM=4
# TEMP_PART_NUM=5
# SYSTEM_PART=/dev/nvme0n1p4

# Dual-boot: partition numbers will differ!
# ============================================

# Get TEMP partition end position BEFORE deleting
TEMP_END=$(parted -s $DISK unit MiB print | awk "/^ *$TEMP_PART_NUM /{ print \$3 }")
echo "TEMP ends at: $TEMP_END"

# Delete temp and expand LUKS to that position (scripted mode so variables expand)
parted -s $DISK rm $TEMP_PART_NUM
parted -s $DISK resizepart $LUKS_PART_NUM $TEMP_END
parted -s $DISK unit MiB print

# Resize LUKS container
cryptsetup open "$SYSTEM_PART" cryptroot
cryptsetup resize cryptroot
```

**Btrfs:**

```bash
mount -o subvol=@ /dev/mapper/cryptroot /mnt
btrfs filesystem resize max /mnt
```

**ext4 + LVM:**

```bash
vgchange -ay vg0
pvresize /dev/mapper/cryptroot
lvextend -l +100%FREE /dev/vg0/home  # all new space goes to home
lvreduce -L -10G /dev/vg0/home -y    # keep 10 GiB free for snapshots
mount /dev/vg0/root /mnt
mount /dev/vg0/home /mnt/home
resize2fs /dev/vg0/home
```

**Verify and clean up:**

```bash
df -h /mnt

umount /mnt/home 2>/dev/null
umount /mnt
vgchange -an vg0 2>/dev/null   # ext4 + LVM only
cryptsetup close cryptroot

reboot
```

---

## Optional: Enable hibernation

With a separate LUKS swap partition, hibernation setup is straightforward.

**1. Add `x-initrd.attach` for cryptswap (idempotent):**

```bash
sudo sed -i -E '/^cryptswap[[:space:]]/ {/x-initrd\.attach/! s@([[:space:]]+[^[:space:]]+[[:space:]]+none[[:space:]]+[^[:space:]]+)@\1,x-initrd.attach@ }' /etc/crypttab
grep -E '^cryptswap\s' /etc/crypttab
# Expected: cryptswap line includes x-initrd.attach
```

**2. Update kernel cmdline in `/etc/default/grub`:**

```bash
RESUME_UUID=$(sudo blkid -s UUID -o value /dev/mapper/cryptswap)

# Replace existing resume=UUID=... (if any), then append current one
sudo sed -i -E '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s@ resume=UUID=[^" ]+@@g' /etc/default/grub
sudo sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ resume=UUID=$RESUME_UUID\"/" /etc/default/grub
grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
```

**3. Rebuild boot config:**

```bash
sudo update-grub
sudo dracut -f --regenerate-all
```

---

## Verify final setup

```bash
# Partition layout
lsblk -f

# Btrfs: verify subvolumes
sudo btrfs subvolume list / 2>/dev/null

# ext4 + LVM: verify LV and free space for snapshots
sudo lvs vg0 2>/dev/null
sudo vgs vg0 2>/dev/null

# Swap status
swapon --show

# LUKS slots (reads device paths from crypttab)
SWAP_DEV=$(awk '/^cryptswap/{print $2}' /etc/crypttab)
ROOT_DEV=$(awk '/^cryptroot/{print $2}' /etc/crypttab)
sudo systemd-cryptenroll "/dev/disk/by-uuid/${SWAP_DEV#UUID=}"
sudo systemd-cryptenroll "/dev/disk/by-uuid/${ROOT_DEV#UUID=}"

# Crypttab + Fstab
cat /etc/crypttab
cat /etc/fstab

# Mount options
mount | grep -E 'btrfs|ext4'
```

---

## Troubleshooting

### Boot fails with "No key available with this passphrase"

TPM state may have changed (firmware update, Secure Boot change). Boot with LUKS passphrase, then re-enroll both partitions:

```bash
# Get device paths from crypttab
SWAP_DEV=$(awk '/^cryptswap/{print $2}' /etc/crypttab)
ROOT_DEV=$(awk '/^cryptroot/{print $2}' /etc/crypttab)
SWAP_PATH="/dev/disk/by-uuid/${SWAP_DEV#UUID=}"
ROOT_PATH="/dev/disk/by-uuid/${ROOT_DEV#UUID=}"

sudo systemd-cryptenroll --wipe-slot=tpm2 "$SWAP_PATH"
sudo systemd-cryptenroll --wipe-slot=tpm2 "$ROOT_PATH"

sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true "$SWAP_PATH"
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true "$ROOT_PATH"
sudo dracut -f --regenerate-all
```

### Dracut fails to find crypt module

```bash
sudo apt install --reinstall dracut cryptsetup
sudo dracut -f --regenerate-all
```

### GRUB doesn't see the new system

Verify EFI boot entry:

```bash
efibootmgr -v
```

Re-run grub-install if needed (from chroot with efivars mounted).

### System won't boot at all (Live ISO recovery)

If you get dracut errors, drop to busybox, or never reach the passphrase prompt (e.g., after a Secure Boot policy change or broken initramfs), boot a Live ISO and fix from there.

**1. Open LUKS and mount:**

```bash
sudo -i
lsblk -f

# ============================================
# PARTITION VARIABLES - adjust to match your hardware!
# ============================================
# SATA drive (fresh install):
export EFI_PART=/dev/sda1
export BOOT_PART=/dev/sda2
export SWAP_PART=/dev/sda3
export SYSTEM_PART=/dev/sda4

# NVMe drive (uncomment if needed):
# export EFI_PART=/dev/nvme0n1p1
# export BOOT_PART=/dev/nvme0n1p2
# export SWAP_PART=/dev/nvme0n1p3
# export SYSTEM_PART=/dev/nvme0n1p4

# Dual-boot: partition numbers will differ!
# ============================================

cryptsetup open $SWAP_PART cryptswap
cryptsetup open $SYSTEM_PART cryptroot
```

**Btrfs:**

```bash
mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home /mnt/boot /mnt/boot/efi
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
```

**ext4 + LVM:**

```bash
vgchange -ay vg0
mount /dev/vg0/root /mnt
mkdir -p /mnt/home /mnt/boot /mnt/boot/efi
mount /dev/vg0/home /mnt/home
```

**Common — mount /boot, chroot:**

```bash
mount $BOOT_PART /mnt/boot
mount $EFI_PART /mnt/boot/efi

for i in dev dev/pts proc sys run; do mount --bind /$i /mnt/$i; done
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars

chroot /mnt /bin/bash
```

**2. Verify crypttab and fstab UUIDs (inside chroot):**

```bash
echo "SWAP_PART=$SWAP_PART  SYSTEM_PART=$SYSTEM_PART"
# If empty — re-export them (see block above)

# Compare crypttab UUIDs with actual LUKS UUIDs
echo "=== crypttab ===" && cat /etc/crypttab
echo "crypttab swap UUID: $(grep cryptswap /etc/crypttab | grep -oP 'UUID=\K[^ ]+')"
echo "actual swap UUID:   $(cryptsetup luksUUID $SWAP_PART)"
echo "crypttab root UUID: $(grep cryptroot /etc/crypttab | grep -oP 'UUID=\K[^ ]+')"
echo "actual root UUID:   $(cryptsetup luksUUID $SYSTEM_PART)"

echo "=== fstab ===" && cat /etc/fstab
```

If any UUID doesn't match, fix it — replace the wrong UUID with the actual one in `/etc/crypttab` or `/etc/fstab`.

**3. Re-enroll TPM2 and rebuild initramfs:**

```bash
# Ensure TPM tools are available inside chroot
apt install -y tpm2-tools

SWAP_DEV=$(awk '/^cryptswap/{print $2}' /etc/crypttab)
ROOT_DEV=$(awk '/^cryptroot/{print $2}' /etc/crypttab)
SWAP_PATH="/dev/disk/by-uuid/${SWAP_DEV#UUID=}"
ROOT_PATH="/dev/disk/by-uuid/${ROOT_DEV#UUID=}"

systemd-cryptenroll --wipe-slot=tpm2 "$SWAP_PATH"
systemd-cryptenroll --wipe-slot=tpm2 "$ROOT_PATH"

systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true "$SWAP_PATH"
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7+14 --tpm2-with-pin=true "$ROOT_PATH"

dracut -f --regenerate-all
update-grub
```

**4. Exit and reboot:**

```bash
exit
umount /mnt/sys/firmware/efi/efivars
for i in run sys proc dev/pts dev; do umount -l /mnt/$i; done
umount /mnt/home
umount /mnt/boot/efi /mnt/boot /mnt
vgchange -an vg0 2>/dev/null   # ext4 + LVM only
cryptsetup close cryptswap
cryptsetup close cryptroot
reboot
```
