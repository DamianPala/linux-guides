#!/usr/bin/env bash
set -uo pipefail

# KDE Smart Refresh — safe recovery without logout
# Fixes: stuck animations, compositor glitches, panel bugs after suspend/dock/hotplug
# Usage: bind to a keyboard shortcut (e.g. Meta+F9)

NOTIFY_ICON="start-here-kde"
NOTIFY_TIMEOUT=3000

# Animation effects to reload (clears stuck TimeLine timers)
# Excludes session effects (login/logout/sessionquit) — unsafe to unload mid-session
ANIMATION_EFFECTS=(
    slidingpopups
    squash
    fadingpopups
    blendchanges
    slide
    maximize
    fullscreen
    windowaperture
    scale
)

notify() {
    notify-send -i "$NOTIFY_ICON" -t "$NOTIFY_TIMEOUT" "KDE Refresh" "$1" 2>/dev/null || true
}

log() {
    echo "[kde-refresh] $1"
}

die() {
    log "ERROR: $1"
    notify "Error: $1"
    exit 1
}

# --- Preflight: check KWin is reachable via D-Bus ---
if ! qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation &>/dev/null; then
    die "KWin not reachable via D-Bus"
fi

# --- Step 1: Reconfigure KWin (reloads config from disk) ---
log "Step 1/4: Reconfiguring KWin..."
qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || log "reconfigure failed (non-fatal)"
sleep 0.3

# --- Step 2: Unload animation effects (kills stuck timers) ---
log "Step 2/4: Unloading animation effects..."
for effect in "${ANIMATION_EFFECTS[@]}"; do
    qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect "$effect" 2>/dev/null || true
done
sleep 0.5

# --- Step 3: Reload animation effects (clean state) ---
log "Step 3/4: Reloading animation effects..."
failed_effects=()
for effect in "${ANIMATION_EFFECTS[@]}"; do
    if ! qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect "$effect" &>/dev/null; then
        failed_effects+=("$effect")
    fi
done
if ((${#failed_effects[@]} > 0)); then
    log "Warning: failed to reload: ${failed_effects[*]}"
fi
sleep 0.3

# --- Step 4: Restart plasmashell (fixes panel/tray/desktop issues) ---
log "Step 4/4: Restarting plasmashell..."
systemctl --user restart plasma-plasmashell.service || log "plasmashell restart failed"

# Wait for plasmashell to be ready (needed for notify-send to work)
for _ in {1..10}; do
    if qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentDesktop &>/dev/null; then
        break
    fi
    sleep 0.5
done

# --- Done ---
notify "KDE refreshed ✓"
log "Done."
