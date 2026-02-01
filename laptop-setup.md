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
