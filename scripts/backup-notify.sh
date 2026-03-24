#!/bin/bash
# Borgmatic backup notification bridge (root → user session)
#
# Called by borgmatic hooks:
#   backup-notify.sh start    — notification + tray icon
#   backup-notify.sh finish   — kill tray + success notification
#   backup-notify.sh fail     — kill tray + persistent error notification
#
# Switch: set BORGMATIC_NOTIFY=0 in borgmatic.service to disable.
# Silently exits if no graphical session is found (e.g., headless server).

[[ "${BORGMATIC_NOTIFY:-0}" == "1" ]] || exit 0
command -v notify-send &>/dev/null || exit 0

TRAY_SCRIPT="/usr/local/bin/backup-tray-icon.py"
TRAY_UNIT="borgmatic-tray-icon"
START_FILE="/run/borgmatic-notify.start"

# --- Find active graphical session (wayland or x11) ---
find_graphical_session() {
    local session_id uid user _rest type
    while read -r session_id uid user _rest; do
        type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null) || continue
        if [[ "$type" == "wayland" || "$type" == "x11" ]]; then
            SESSION_ID="$session_id"
            SESSION_UID="$uid"
            SESSION_USER="$user"
            SESSION_TYPE="$type"
            return 0
        fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    return 1
}

# --- Send desktop notification as the session user ---
# D-Bus session bus rejects uid 0, so we run notify-send as the user via systemd-run.
send_notification() {
    local summary="$1" body="${2:-}" icon="${3:-dialog-information}" urgency="${4:-normal}"
    local -a cmd=(
        notify-send --app-name=Borgmatic "--icon=$icon" "--urgency=$urgency" "$summary"
    )
    [[ -n "$body" ]] && cmd+=("$body")
    timeout 10 systemd-run --quiet --collect --wait \
        --uid="$SESSION_USER" \
        --setenv="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${SESSION_UID}/bus" \
        -- "${cmd[@]}" 2>/dev/null || true
}

# --- Tray icon management via systemd transient unit ---
start_tray_icon() {
    stop_tray_icon

    local -a env_args=(
        "--setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${SESSION_UID}/bus"
        "--setenv=XDG_RUNTIME_DIR=/run/user/${SESSION_UID}"
        "--setenv=XDG_DATA_DIRS=/usr/share:/usr/local/share"
        "--setenv=QT_QPA_PLATFORMTHEME=kde"
    )

    if [[ "$SESSION_TYPE" == "wayland" ]]; then
        env_args+=("--setenv=QT_QPA_PLATFORM=wayland")
        local wayland_display="" f
        for f in /run/user/${SESSION_UID}/wayland-*.lock; do
            [[ -f "$f" ]] && wayland_display=$(basename "$f" .lock) && break
        done
        [[ -n "$wayland_display" ]] && env_args+=("--setenv=WAYLAND_DISPLAY=$wayland_display")
    else
        # X11 — pass DISPLAY so Qt can connect to the X server
        local display
        display=$(loginctl show-session "$SESSION_ID" -p Display --value 2>/dev/null)
        [[ -n "$display" ]] && env_args+=("--setenv=DISPLAY=$display")
    fi

    systemd-run --quiet --collect \
        --unit="$TRAY_UNIT" \
        --uid="$SESSION_USER" \
        --description="Borgmatic backup tray icon" \
        "${env_args[@]}" \
        /usr/bin/python3 "$TRAY_SCRIPT" 2>/dev/null || true
}

stop_tray_icon() {
    systemctl stop "$TRAY_UNIT.service" 2>/dev/null || true
    systemctl reset-failed "$TRAY_UNIT.service" 2>/dev/null || true
    pkill -f 'backup-tray-icon\.py' 2>/dev/null || true
}

# --- Duration tracking ---
format_duration() {
    local s=$1 m=$((s / 60))
    s=$((s % 60))
    ((m > 0)) && echo "${m}m ${s}s" || echo "${s}s"
}

get_duration() {
    [[ -f "$START_FILE" ]] || return 0
    local ts
    ts=$(<"$START_FILE") 2>/dev/null || return 0
    rm -f "$START_FILE" 2>/dev/null
    local now elapsed
    now=$(date +%s)
    elapsed=$((now - ts))
    format_duration "$elapsed"
}

# --- Actions ---
do_start() {
    date +%s > "$START_FILE" 2>/dev/null || true
    start_tray_icon
    send_notification "Backup started" "Borgmatic backup is running..." "state-sync"
}

do_finish() {
    stop_tray_icon
    local dur
    dur=$(get_duration)
    send_notification "Backup completed${dur:+ ($dur)}" \
        "Borgmatic backup finished successfully." "security-high" "normal"
}

do_fail() {
    stop_tray_icon
    local dur
    dur=$(get_duration)
    send_notification "Backup FAILED${dur:+ after $dur}" \
        "Check: journalctl -u borgmatic" "dialog-error" "critical"
}

# --- Main ---
find_graphical_session || exit 0

case "${1:-}" in
    start)  do_start ;;
    finish) do_finish ;;
    fail)   do_fail ;;
    *)      echo "Usage: $0 {start|finish|fail}" >&2; exit 1 ;;
esac
