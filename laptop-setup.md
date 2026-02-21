# Kubuntu Laptop Setup - ASUS Expertbook B9403

Hardware-specific tweaks for running Kubuntu on Expertbook B9403.

---

## Disable USB/Bluetooth Wake from Sleep

Prevents laptop from randomly waking up due to Bluetooth or USB interrupts.

### Setup

```bash
# Create the script
sudo tee /usr/local/sbin/disable-xhci-wake.sh << 'EOF'
#!/bin/bash
echo XHCI > /proc/acpi/wakeup
EOF
sudo chmod +x /usr/local/sbin/disable-xhci-wake.sh

# Create systemd service
sudo tee /etc/systemd/system/disable-xhci-wake.service << 'EOF'
[Unit]
Description=Disable XHCI wake from Bluetooth/USB
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disable-xhci-wake.sh

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable --now disable-xhci-wake.service
```

### Verify

```bash
# Check service status
systemctl status disable-xhci-wake.service

# Check XHCI is disabled (should show "disabled")
cat /proc/acpi/wakeup | grep XHCI
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
    - **Restart Plasmashell** → `systemctl --user restart plasma-plasmashell.service` → `Meta+F9`
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
