# System Snapshot & Rollback: Btrfs + Snapper

Hourly filesystem snapshots with automatic cleanup. Accidentally `rm -rf` something? Grab it back from a local snapshot in seconds, no NAS restore needed.

This guide sets up Snapper on a Btrfs system with flat subvolume layout (`@` and `@home`). Snapshots are taken hourly and automatically thinned (retention depends on whether you have remote backups). An apt hook captures system state before and after every package operation.

## How it works

Btrfs snapshots are Copy-on-Write references to a subvolume at a given point in time. Creating one is instant and takes no disk space. Space usage grows only as the original blocks get overwritten, because CoW preserves the old version in the snapshot.

Snapper automates snapshot creation, cleanup, and comparison. After setup you get:

- Hourly snapshots of `/` (root) and `/home`
- Configurable retention (two policies provided: with and without remote backups)
- Optional pre/post snapshots on `apt install`/`upgrade`
- `snapper diff` to compare any two points in time
- `snapper undochange` to restore individual files or directories
- Btrfs Assistant GUI for visual browsing and management (optional, Step 2)

This does not replace remote backups. Snapshots live on the same disk. If the disk dies, the snapshots go with it. Btrfs snapshots also don't cross subvolume boundaries (relevant if you use Incus/LXD with a Btrfs storage pool, see Notes).

### Snapshot storage layout

Snapshots go into dedicated top-level subvolumes, mounted separately from `@` and `@home`. This prevents recursive snapshots (a snapshot of `@` including its own snapshots directory).

```
btrfs top-level (subvolid=5)
├── @                    → /
├── @home                → /home
├── @snapshots           → /.snapshots        (root snapshots)
└── @home_snapshots      → /home/.snapshots   (home snapshots)
```

## Prerequisites

- Btrfs with flat subvolume layout (`@` at `/`, `@home` at `/home`)
- Root access
- ~40-70 GB free space for snapshot overhead (varies with how much data changes daily)

Check your layout:

```bash
findmnt -t btrfs
```

Look for `/@` at `/` and `/@home` at `/home`.

## Step 1: Install Snapper from source

Ubuntu 25.10 repos have Snapper 0.10.6. Upstream is at v0.13.0 with better Debian/Ubuntu compatibility and a new `snbk` backup utility. Build from source to get 0.13.0.

### Dependencies

```bash
sudo apt install git cmake make automake autoconf libtool g++ xsltproc \
  libmount-dev libdbus-1-dev libacl1-dev docbook-xsl libxml2-dev \
  libbtrfs-dev libsystemd-dev libboost-dev libboost-thread-dev \
  libncurses-dev libjson-c-dev libpam0g-dev libselinux1-dev
```

### Build and install

```bash
git clone https://github.com/openSUSE/snapper.git /tmp/snapper
cd /tmp/snapper
git checkout "$(git describe --tags --abbrev=0)"
make -f Makefile.repo configure
make -j$(nproc)
```

`make -f Makefile.repo configure` runs autoreconf and then `./configure` with sane defaults. The separate `make` builds everything.

**Ubuntu `install` bug:** `make install` fails on the bash completion script because Ubuntu's coreutils `install` doesn't accept the mode string `a+r,u+w` that the Makefile uses. Copy the completion file manually, then run install with `-k` to continue despite the error:

```bash
sudo mkdir -p /usr/share/bash-completion/completions
sudo cp scripts/completion/snapper-completion.bash /usr/share/bash-completion/completions/snapper
sudo make install -k
```

Verify:

```bash
snapper --version
```

## Step 2: Install Btrfs Assistant from source (optional)

Qt6 GUI for managing snapshots, subvolumes, scrub and balance. Looks native on KDE Plasma. Skip this if you prefer CLI-only.

### Dependencies

```bash
sudo apt install cmake g++ qt6-base-dev qt6-base-dev-tools qt6-tools-dev \
  qt6-svg-dev libbtrfs-dev libbtrfsutil-dev fonts-noto
```

### Build and install

```bash
git clone https://gitlab.com/btrfs-assistant/btrfs-assistant.git /tmp/btrfs-assistant
cd /tmp/btrfs-assistant
git checkout "$(git describe --tags --abbrev=0)"
cmake -B build -S . -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release
make -C build -j$(nproc)
sudo make -C build install
```

Launch with `btrfs-assistant` (polkit will ask for your password).

## Step 3: Create snapshot subvolumes

Mount the Btrfs top-level (subvolid=5) temporarily to create the subvolumes. You only need to do this once. Replace `/dev/mapper/cryptroot` below with your Btrfs device if different (check `findmnt -no SOURCE /`).

```bash
sudo mkdir -p /mnt/btrfs-toplevel
sudo mount -o subvolid=5 /dev/mapper/cryptroot /mnt/btrfs-toplevel
sudo btrfs subvolume create /mnt/btrfs-toplevel/@snapshots
sudo btrfs subvolume create /mnt/btrfs-toplevel/@home_snapshots
sudo umount /mnt/btrfs-toplevel
sudo rmdir /mnt/btrfs-toplevel
```

### Add to fstab

```bash
# Get your Btrfs UUID
BTRFS_UUID=$(findmnt -no UUID /)

sudo tee -a /etc/fstab << EOF

# Snapper snapshot subvolumes
UUID=$BTRFS_UUID  /.snapshots       btrfs  subvol=@snapshots,compress=zstd:1,noatime  0 0
UUID=$BTRFS_UUID  /home/.snapshots  btrfs  subvol=@home_snapshots,compress=zstd:1,noatime  0 0
EOF
```

Mount them:

```bash
sudo mkdir -p /.snapshots /home/.snapshots
sudo mount /.snapshots
sudo mount /home/.snapshots
```

## Step 4: Configure Snapper

`snapper create-config` always creates a `.snapshots` subvolume nested inside the target. It fails if anything already exists at that path (directory or subvolume). We want our dedicated top-level subvolumes instead. The sequence: unmount ours, remove the mount point, let Snapper create its config (and its nested subvolume), delete the nested one, re-create the mount point, re-mount ours.

On Ubuntu, Snapper also needs `/etc/sysconfig/snapper` to store the config list (openSUSE convention, not created by default on Debian/Ubuntu):

```bash
sudo tee /etc/sysconfig/snapper << 'EOF'
SNAPPER_CONFIGS=""
EOF

# Root config
sudo umount /.snapshots
sudo rmdir /.snapshots
sudo snapper -c root create-config /
sudo btrfs subvolume delete /.snapshots
sudo mkdir -p /.snapshots
sudo mount /.snapshots

# Home config
sudo umount /home/.snapshots
sudo rmdir /home/.snapshots
sudo snapper -c home create-config /home
sudo btrfs subvolume delete /home/.snapshots
sudo mkdir -p /home/.snapshots
sudo mount /home/.snapshots
```

### Set retention policy

Pick a policy based on whether you have remote backups. Snapper doesn't need to duplicate what backup already covers.

**With remote backups** (your backup tool handles weekly/monthly retention):

```bash
for config in root home; do
    sudo snapper -c "$config" set-config \
        TIMELINE_CREATE=yes \
        TIMELINE_LIMIT_HOURLY=12 \
        TIMELINE_LIMIT_DAILY=7 \
        TIMELINE_LIMIT_WEEKLY=0 \
        TIMELINE_LIMIT_MONTHLY=0
done
```

**Without remote backups** (snapshots are your only safety net):

```bash
# Root — changes mostly on apt updates, leaner policy
sudo snapper -c root set-config \
    TIMELINE_CREATE=yes \
    TIMELINE_LIMIT_HOURLY=12 \
    TIMELINE_LIMIT_DAILY=7 \
    TIMELINE_LIMIT_WEEKLY=4 \
    TIMELINE_LIMIT_MONTHLY=1

# Home — user data, needs longer coverage
sudo snapper -c home set-config \
    TIMELINE_CREATE=yes \
    TIMELINE_LIMIT_HOURLY=24 \
    TIMELINE_LIMIT_DAILY=14 \
    TIMELINE_LIMIT_WEEKLY=4 \
    TIMELINE_LIMIT_MONTHLY=1
```

### Disable quota

Btrfs quota (qgroup) tracking adds significant I/O overhead. With quota enabled, every snapshot deletion triggers qgroup accounting for every freed extent, stalling disk I/O for minutes or hours even on modern kernels. On a desktop workload, quota provides no practical benefit: count-based retention (hourly/daily limits) handles cleanup well enough, and `btrfs filesystem usage` shows overall space.

Disable it and clear Snapper's QGROUP references (stale QGROUP values can silently prevent snapshot creation on some kernels):

```bash
sudo btrfs quota disable /
sudo snapper -c root set-config QGROUP=""
sudo snapper -c home set-config QGROUP=""
```

Some tools enable quota automatically without telling you (e.g. Incus enables it when creating a btrfs storage pool). After setup, verify it's off:

```bash
sudo btrfs quota status /
```

### Enable timers

```bash
# Verify the unit files were installed by make install
systemctl cat snapper-timeline.timer > /dev/null && systemctl cat snapper-cleanup.timer > /dev/null

sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
```

The default cleanup timer runs hourly, which is unnecessary. Once daily is enough. Override:

```bash
sudo systemctl edit snapper-cleanup.timer
```

Add:

```ini
[Timer]
OnBootSec=
OnUnitActiveSec=
OnCalendar=*-*-* 22:00:00
Persistent=true
```

This runs cleanup at 22:00 daily. `Persistent=true` catches up after sleep/shutdown.

Check they're scheduled:

```bash
systemctl list-timers | grep snapper
```

`snapper-timeline.timer` fires hourly, `snapper-cleanup.timer` fires once daily at 22:00.

## Step 5: System integration

Several things will cause problems if not addressed right after setup.

### Exclude snapshots from indexers

Both `plocate`/`locate` and KDE's Baloo file indexer will crawl snapshot directories by default. With 20+ snapshots this means indexing every file 20+ times, burning CPU and producing duplicate search results.

updatedb:
```bash
sudo sed -i 's/^# PRUNENAMES=".git .bzr .hg .svn"/PRUNENAMES=".git .bzr .hg .svn .snapshots"/' /etc/updatedb.conf
```

Baloo (KDE Plasma): `balooctl6 config add` overwrites the list instead of appending (Plasma 6 bug), so append directly:
```bash
if grep -q '^exclude folders' ~/.config/baloofilerc 2>/dev/null; then
    sed -i '/^exclude folders/s|$|,/.snapshots/,/home/.snapshots/|' ~/.config/baloofilerc
else
    mkdir -p ~/.config
    printf '[General]\nexclude folders[$e]=/.snapshots/,/home/.snapshots/\n' >> ~/.config/baloofilerc
fi
```

### Verify cleanup timer is running

`snapper-cleanup.timer` can silently stop firing after systemd updates. If it dies, snapshots accumulate without limit. Check periodically:

```bash
systemctl list-timers snapper-cleanup.timer
```

The `NEXT` column should show a future timestamp. If it shows `-`, restart:

```bash
sudo systemctl restart snapper-cleanup.timer
```

## Step 6: Apt hook (optional)


Pre/post snapshots on every `apt install`/`upgrade`, so you can diff or roll back a bad update. Useful but not required if hourly timeline snapshots already give you enough coverage. Skip this step if you want to keep things minimal.

Building from source means no Debian/Ubuntu apt hook ships automatically. To enable:

```bash
sudo tee /etc/apt/apt.conf.d/80snapper << 'HOOK'
DPkg::Pre-Invoke {"if [ -x /usr/bin/snapper ]; then snapper --no-dbus -c root create -d apt -t pre --print-number > /run/snapper-apt-pre; fi"};
DPkg::Post-Invoke {"if [ -x /usr/bin/snapper -a -f /run/snapper-apt-pre ]; then snapper --no-dbus -c root create -d apt -t post --pre-number $(cat /run/snapper-apt-pre); rm -f /run/snapper-apt-pre; fi"};
HOOK
```

**About `--no-dbus`:** apt hooks run as root during dpkg transactions. The Snapper DBus daemon may not be available at that point, so `--no-dbus` operates directly on the filesystem.

The pre hook saves its snapshot number to `/run/snapper-apt-pre`. The post hook reads it back via `--pre-number` so Snapper can link the two as a proper pre/post pair.

Install any package to test, then:

```bash
sudo snapper -c root list --disable-used-space
```

The output should show a linked pre/post pair with description "apt".

## Step 7: Verify

### Test file restore

```bash
# Create a test file under /home (covered by @home snapshots)
echo "important data" > ~/snapper-test.txt

# Snapshot
sudo snapper -c home create -d "before-test"

# Delete the file
rm ~/snapper-test.txt

# Find the snapshot number (--disable-used-space speeds up listing on large filesystems)
sudo snapper -c home list --disable-used-space

# Restore (replace N with your snapshot number)
sudo snapper -c home undochange N..0 ~/snapper-test.txt

# Check
cat ~/snapper-test.txt

# Clean up
rm ~/snapper-test.txt
sudo snapper -c home delete N
```

### Check overhead

```bash
sudo btrfs filesystem usage /
```

Initial overhead is near zero. It grows over days as CoW accumulates changed blocks in older snapshots. After a week of normal use, expect 20-40 GB depending on workload.

### Browse snapshots directly

Each snapshot is a read-only directory tree:

```bash
# Root snapshots
ls /.snapshots/
ls /.snapshots/1/snapshot/etc/

# Home snapshots
ls /home/.snapshots/
ls /home/.snapshots/1/snapshot/yourusername/Documents/
```

You can browse and `cp` files directly. Faster than `snapper undochange` for grabbing individual files.

## Day-to-day operations

### List snapshots

```bash
sudo snapper -c root list --disable-used-space
sudo snapper -c home list --disable-used-space
```

Without `--disable-used-space`, listing can take 20-30s on large filesystems (it walks the extent tree to calculate each snapshot's size).

### Compare two points in time

```bash
# Between two snapshots
sudo snapper -c home diff 5..8

# Between a snapshot and the current state (0 = now)
sudo snapper -c home diff 5..0
```

### Restore files

```bash
# Copy directly from snapshot
sudo cp /.snapshots/N/snapshot/path/to/file /path/to/file

# Or revert all differences between two snapshots for a specific path
sudo snapper -c home undochange 5..0 /home/user/accidentally-deleted-dir
```

### Manual snapshot before a risky change

```bash
sudo snapper -c home create -d "before risky operation"
```

### Delete a snapshot

```bash
sudo snapper -c root delete 5
```

### Pause snapshots for N hours

Stops the timeline timer and schedules automatic resume. Uses realtime clock with `Persistent=true`, so it works correctly across sleep/suspend.

```bash
# Pause for 24 hours (change the number as needed)
sudo systemctl stop snapper-timeline.timer && \
sudo systemd-run --on-calendar="$(date -d '+24 hours' '+%Y-%m-%d %H:%M')" \
    --timer-property=Persistent=true \
    --unit=snapper-resume \
    systemctl start snapper-timeline.timer && \
echo "Snapshots paused until $(date -d '+24 hours' '+%Y-%m-%d %H:%M')"
```

To check status or cancel early:

```bash
# Check when resume is scheduled
systemctl list-timers | grep snapper

# Resume manually (cancels the scheduled resume)
sudo systemctl stop snapper-resume.timer 2>/dev/null
sudo systemctl start snapper-timeline.timer
```

## Notes

**Incus / LXD containers:** Incus with Btrfs storage creates nested subvolumes for containers under `@`. Root snapshots don't include that data (Btrfs doesn't snapshot recursively across subvolume boundaries). Worse, rolling back `@` would revert Incus's database while leaving container subvolumes at their current state, causing inconsistency. If you plan full root rollbacks, isolate `/var/lib/incus` as a separate top-level subvolume.

**Backup tools with Btrfs snapshots:** Some backup tools (e.g. borgmatic with `btrfs: {}`) create their own temporary Btrfs snapshots for consistency during backup. These are independent from Snapper and cleaned up automatically. The two don't interfere.

**Space pressure:** Keep 15-20% free on your Btrfs volume. Count limits (hourly/daily) are the only automatic control. Manual cleanup if needed:

```bash
sudo snapper -c root cleanup timeline
sudo snapper -c home cleanup timeline
```

**Disk full recovery:** If snapshots fill the disk and the system can't boot, boot from a live USB:
```bash
cryptsetup open /dev/nvmeXnYpZ cryptroot
mount /dev/mapper/cryptroot /mnt -o subvol=@snapshots
# Find and delete old snapshots
ls /mnt/
btrfs subvolume delete /mnt/N/snapshot  # repeat for old snapshot numbers
umount /mnt
```
If Btrfs is completely stuck (can't write metadata to delete), run a null rebalance: `btrfs balance start -musage=0 -dusage=0 /mnt`

**Full rollback caveats on Ubuntu:** `snapper rollback` changes the Btrfs default subvolume. Ubuntu's fstab has `subvol=@` hardcoded, which overrides that. Full system rollback requires either removing `subvol=@` from fstab (and using `btrfs subvolume set-default` instead) or using `grub-btrfs` to boot from snapshots. None of this matters for file-level recovery, where `undochange` and manual copy from `/.snapshots/` work without fstab changes.

**Updating Snapper:** Built from source, so `apt upgrade` won't touch it. To update, repeat Step 1 (clone or `git fetch --tags`, checkout latest tag, build, install).

## References

- https://github.com/openSUSE/snapper
- https://gitlab.com/btrfs-assistant/btrfs-assistant
- https://wiki.archlinux.org/title/Snapper
- http://snapper.io
- https://doc.opensuse.org/documentation/leap/reference/html/book-reference/cha-snapper.html
