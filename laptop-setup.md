# Kubuntu Laptop Setup - ASUS Expertbook B9403

Hardware-specific tweaks for running Kubuntu on Expertbook B9403.

---

## Disable Spurious Wakeup Sources

Prevents laptop from randomly waking up from s2idle, especially with a Thunderbolt dock connected.

**Disabled:** XHCI (USB), TXHC/TDM0/TRP0/TRP1 (Thunderbolt), PEG0 (PCIe), GLAN (Ethernet), PXSX (Thunderbolt downstream, via sysfs).
**Left enabled:** Lid switch, ACPI alarm (AWAC).

The script checks current state before toggling (`/proc/acpi/wakeup` is toggle-based, not set-based). Duplicate ACPI names (PXSX has 5 entries) are handled via sysfs to avoid flipping all at once.

Runs via **system-sleep hook** before every suspend.

### Setup

```bash
sudo tee /usr/local/sbin/disable-wakeup-sources.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

# Disable ACPI wakeup sources that cause spurious wakeups from s2idle,
# especially with a Thunderbolt dock connected.
#
# /proc/acpi/wakeup is toggle-based (write flips state), so we check
# current state before writing to avoid accidentally enabling a source.
#
# Duplicate ACPI names (e.g. PXSX) cannot be toggled
# individually through /proc/acpi/wakeup — all entries flip at once.
# Those are handled via sysfs instead.
#
# Managed by: disable-wakeup-sources-sleep-hook.sh (system-sleep hook)

ACPI_WAKEUP=/proc/acpi/wakeup
# Sources safe to toggle via /proc/acpi/wakeup (unique names only)
ACPI_SOURCES=(
    XHCI # USB controller (Bluetooth/USB peripherals)
    TXHC # Thunderbolt host controller
    TDM0 # Thunderbolt DMA engine
    TRP0 # Thunderbolt PCIe root port 0
    TRP1 # Thunderbolt PCIe root port 1
    PEG0 # PCIe Graphics/NVMe slot
    GLAN # Ethernet (Wake-on-LAN)
)

# Sources with duplicate ACPI names — disable via sysfs path directly.
# Format: "sysfs_path  # comment"
SYSFS_SOURCES=(
    "/sys/devices/pci0000:00/0000:00:07.0/0000:02:00.0/power/wakeup  # PXSX - Thunderbolt PCIe downstream"
)

log() {
    echo "$1"
}

disabled=0
already_off=0
missing=0
errors=0

# --- ACPI toggle sources (unique names) ---

if [[ ! -f "$ACPI_WAKEUP" ]]; then
    log "ERROR: $ACPI_WAKEUP not found"
    exit 1
fi

for src in "${ACPI_SOURCES[@]}"; do
    line=$(grep -E "^${src}\s" "$ACPI_WAKEUP" || true)

    if [[ -z "$line" ]]; then
        log "MISSING: $src not in ACPI wakeup table"
        ((missing += 1))
        continue
    fi

    # Bail if there are multiple entries (ambiguous toggle)
    count=$(echo "$line" | wc -l)
    if ((count > 1)); then
        log "ERROR: $src has $count entries, cannot toggle safely — use SYSFS_SOURCES"
        ((errors += 1))
        continue
    fi

    if echo "$line" | grep -q '\*enabled'; then
        echo "$src" >"$ACPI_WAKEUP"
        log "DISABLED: $src (ACPI toggle)"
        ((disabled += 1))
    else
        log "OK: $src already disabled"
        ((already_off += 1))
    fi
done

# --- sysfs sources (for duplicates or fine-grained control) ---

for entry in "${SYSFS_SOURCES[@]}"; do
    # Split on "  # " delimiter (double-space + hash + space)
    path="${entry%%  #*}"
    comment="${entry#*# }"
    # Fallback if entry has no comment
    [[ "$comment" == "$entry" ]] && comment="$path"

    if [[ ! -f "$path" ]]; then
        log "MISSING: $path not found ($comment)"
        ((missing += 1))
        continue
    fi

    current=$(cat "$path")
    if [[ "$current" == "enabled" ]]; then
        echo "disabled" >"$path"
        log "DISABLED: $path ($comment)"
        ((disabled += 1))
    else
        log "OK: $path already disabled ($comment)"
        ((already_off += 1))
    fi
done

log "Done: disabled=$disabled already_off=$already_off missing=$missing errors=$errors"
SCRIPT
sudo chmod +x /usr/local/sbin/disable-wakeup-sources.sh

sudo tee /usr/lib/systemd/system-sleep/disable-wakeup-sources-sleep-hook.sh << 'EOF'
#!/bin/bash
# Re-run wakeup source disabling before suspend to catch
# dynamically attached devices (e.g. Thunderbolt dock).
case "$1" in
    pre) /usr/local/sbin/disable-wakeup-sources.sh ;;
esac
EOF
sudo chmod +x /usr/lib/systemd/system-sleep/disable-wakeup-sources-sleep-hook.sh
```

### Verify

```bash
# Manual test
sudo /usr/local/sbin/disable-wakeup-sources.sh

# All should show *disabled
cat /proc/acpi/wakeup | grep -E 'XHCI|TXHC|TDM0|TRP0|TRP1|PEG0|GLAN'
```

---

## Dynamic Sleep Mode (AC vs Battery)

Automatically switches between sleep modes:
- **On AC/dock**: `s2idle` - light sleep, fast wake (~1s), keeps connections
- **On battery**: `deep` - S3 sleep, saves more power, slower wake (~5s)

### Why Two Components?

1. **udev rule** - triggers when you plug/unplug charger while awake
2. **system-sleep hook** - runs on both `pre` and `post`:
   - `pre`: ensures correct mode right before sleep (backup if udev missed)
   - `post`: re-applies after wake (handles: slept on dock → woke off dock, or vice versa)

### Setup

```bash
# Create the script
sudo tee /usr/local/sbin/set-sleep-mode.sh << 'EOF'
#!/bin/bash
# Set sleep mode based on AC power status
# s2idle on AC (fast wake for docking), deep on battery (power saving)

if on_ac_power; then
    MODE="s2idle"
else
    MODE="deep"
fi

# Only write if mode is available and different
if grep -q "$MODE" /sys/power/mem_sleep; then
    CURRENT=$(cat /sys/power/mem_sleep | grep -oP '\[\K[^\]]+')
    if [ "$CURRENT" != "$MODE" ]; then
        echo "$MODE" > /sys/power/mem_sleep
        logger "Sleep mode set to $MODE (AC: $(on_ac_power && echo yes || echo no))"
    fi
fi
EOF
sudo chmod +x /usr/local/sbin/set-sleep-mode.sh

# udev rule - triggers on AC power change
sudo tee /etc/udev/rules.d/99-sleep-mode.rules << 'EOF'
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="/usr/local/sbin/set-sleep-mode.sh"
EOF

# system-sleep hook - runs before sleep and after wake
sudo tee /usr/lib/systemd/system-sleep/set-sleep-mode.sh << 'EOF'
#!/bin/bash
# pre:  ensure correct mode before sleep (in case udev missed something)
# post: re-apply after wake (AC state may have changed during sleep)
case "$1" in
    pre|post) /usr/local/sbin/set-sleep-mode.sh ;;
esac
EOF
sudo chmod +x /usr/lib/systemd/system-sleep/set-sleep-mode.sh

# Reload udev and apply now
sudo udevadm control --reload-rules
sudo /usr/local/sbin/set-sleep-mode.sh
```

### Verify

```bash
# Check current mode (bracketed = active)
cat /sys/power/mem_sleep

# Test by unplugging AC, then:
cat /sys/power/mem_sleep  # should show [deep]

# Check logs
journalctl -t root --since "5 minutes ago" | grep -i sleep
```

### Troubleshooting

```bash
# Manual test
sudo /usr/local/sbin/set-sleep-mode.sh && cat /sys/power/mem_sleep

# Check udev sees AC events
udevadm monitor --property --subsystem-match=power_supply
# (plug/unplug charger to see events)
```

---

## KDE Plasma Settings

Settings to configure after a fresh install. Paths follow Plasma 6 System Settings.

### Appearance & Style

- Colors & Themes → Global Theme → **Breeze Dark**
- Colors & Themes → Colors → **Sweet Custom New**
- Animations → Animation speed: **slightly faster** (`AnimationDurationFactor=0.70`)

### Apps & Windows

- Default Applications → Web browser: **Google Chrome**
- Window Management → Virtual Desktops → **4 desktops in 2×2 grid**: Main, Investments / Work, Learn
- Window Management → Virtual Desktops →  Switching Animation: **Slide**
- Window Management → Task Switcher → Visualization: **Thumbnail Grid**
- Window Management → Desktop Effects → enable **Remember Window Positions** (KWin Script)
- Window Management → Window Rules:
  - Obsidian — icon fix (snap tray icon mismatch)
  - Signal — icon fix (snap tray icon mismatch)

### Clipboard

- System Tray → Clipboard icon → Configure Clipboard → **Clipboard history size: 60**

### Security & Privacy

- Screen Locking → Lock screen automatically: **15 min**
- Screen Locking → Delay before password required: **10 seconds**

### Input & Output

**Keyboard:**

- Keyboard → Layouts: **Polish**, **Montenegrin** (Latin variant)
- Keyboard → Switching to another layout: **Meta+Space**
- Keyboard → Shortcuts:
  - Power Management → Sleep: `Meta+S`
  - KWin → Move Window to Center: `Meta+C`
  - Shortcuts → Add New → Command (name → command → shortcut):
    - **Clean Copy AI** → `wl-copy "$(wl-paste | sed 's/^  //; s/[[:space:]]*$//')"` → `Ctrl+Shift+X`
    - **KDE Smart Refresh** → `~/.local/bin/kde-refresh.sh` → `Meta+F9` (reconfigure KWin + reload animation effects + restart plasmashell — fixes stuck CPU after suspend/dock without logout, see [`scripts/kde-refresh.sh`](scripts/kde-refresh.sh))
    - **Restart KDE** → `systemctl --user restart plasma-kwin_wayland.service plasma-plasmashell.service plasma-powerdevil.service` → `Meta+F10`

**Mouse & Touchpad:**

- Mouse → Pointer acceleration: **Enabled**
- Touchpad → Invert scroll direction: **Natural scrolling**
- Screen Edges:
  - Top → Toggle Overview
  - Top-Left → Toggle Grid View
  - Activation delay: 100 ms
  - Reactivation delay: 250 ms
  - Edge barrier: **0** (disabled)

**Display & Monitor:**

- Display Configuration:

  | Display | Resolution | Scale | Refresh |
  |---|---|---|---|
  | ASUS laptop (eDP-1) | 2880×1800 | 150% | 90 Hz |
  | LG external (DP-6) | 2560×1440 | 100% | 165 Hz |

  Layout when docked: external monitor (primary) left, laptop right.

- Night Light → Custom times, **2500K**, 20:30–05:30, 30 min transition

### System

**Power Management:**

| Setting | AC | Battery |
|---|---|---|
| Dim screen | 15 min | 10 min |
| Turn off screen | off | 15 min |
| Suspend session | off | 90 min |

**Startup:**

- Session → Desktop Session → **Start with an empty session** (no session restore)
- Autostart: Discord, Dolphin, Kate, Mullvad VPN, Remmina, Signal, Synology Drive, Telegram, Thunderbird

---

## Rescue Account (admin)

A separate admin account for emergencies — accidentally removing yourself from `sudo`, breaking `.bashrc`/`.profile`, or needing to fix permissions from another session.

System → Users → **Add New User**:

- Name: `rescue`
- Account type: **Administrator**
- Password: same as main account (easier to remember in emergencies)

After creating, test via TTY: Ctrl+Alt+F2 → log in as `rescue` → `sudo whoami` → should return `root`.

---

## Full SysRq (REISUB)

Ubuntu's default sysrq bitmask (176) disables the keys you actually need when the desktop freezes: R (raw keyboard), E and I (kill processes). When kwin_wayland hangs, it holds the keyboard hostage, so Ctrl+Alt+F3 won't work. SysRq+R takes input back from the compositor and TTY switching starts working again.

The restricted default is a multi-user server thing. On a single-user laptop, `sysrq=1` is fine.

### Setup

```bash
# Takes effect immediately
echo 1 | sudo tee /proc/sys/kernel/sysrq

# Survives reboot
echo 'kernel.sysrq = 1' | sudo tee /etc/sysctl.d/90-sysrq.conf
```

### Verify

```bash
# Should return 1
cat /proc/sys/kernel/sysrq
```

### When the desktop freezes

**Step 1: Take keyboard back**

`Alt+SysRq+R`

**Step 2: Try switching to TTY**

`Ctrl+Alt+F3` — if you get a login prompt, the GPU recovered. Log in and restart the session:

```bash
sudo systemctl restart sddm
```

**Step 3: If TTY is black or unresponsive, do a clean reboot**

Hold Alt+SysRq and press each key with a few seconds between: `E` (SIGTERM all) → `I` (SIGKILL stragglers) → `S` (sync) → `U` (remount read-only) → `B` (reboot).

---

## Hardware Clock: UTC (Dual-Boot)

On dual-boot with Windows, clocks get out of sync — Windows uses localtime, Linux uses UTC, so each boot "corrects" the clock wrong.

```bash
timedatectl set-local-rtc 0

# Verify — should show "RTC in local TZ: no"
timedatectl
```

If Windows still resets the clock, tell it to use UTC too (admin PowerShell):

```powershell
reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

---
