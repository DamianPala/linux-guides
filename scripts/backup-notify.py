#!/usr/bin/python3
"""Borgmatic backup notification bridge.

Usage:
    backup-notify.py start          # notification + tray icon
    backup-notify.py finish         # kill tray + success notification (transient)
    backup-notify.py fail           # kill tray + error notification (persistent)
    backup-notify.py demo [ICON]    # simulate: start -> 3s -> finish
    backup-notify.py demo-fail [ICON]  # simulate: start -> 3s -> fail
"""
import os
import signal
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TRAY_SCRIPT = os.path.join(SCRIPT_DIR, "backup-tray-icon.py")
PID_FILE = "/tmp/borgmatic-tray-icon.pid"
START_FILE = "/tmp/borgmatic-notify.start"


def send_notification(summary, body="", icon="dialog-information", urgency="normal"):
    """Send desktop notification via notify-send."""
    cmd = [
        "notify-send",
        "--app-name=Borgmatic",
        f"--icon={icon}",
        f"--urgency={urgency}",
        summary,
    ]
    if body:
        cmd.append(body)
    subprocess.run(cmd, stderr=subprocess.DEVNULL)


def start_tray_icon(icon_name=None):
    """Launch tray icon as background process."""
    stop_tray_icon()  # clean up any leftover

    cmd = [sys.executable, TRAY_SCRIPT]
    if icon_name:
        cmd.append(icon_name)
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    with open(PID_FILE, "w") as f:
        f.write(str(proc.pid))


def stop_tray_icon():
    """Kill all tray icon processes."""
    # Kill by PID file
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE) as f:
                pid = int(f.read().strip())
            os.kill(pid, signal.SIGTERM)
        except (ValueError, ProcessLookupError, PermissionError):
            pass
        try:
            os.remove(PID_FILE)
        except FileNotFoundError:
            pass

    # Kill any remaining tray icon processes (defensive cleanup)
    subprocess.run(
        ["pkill", "-f", "backup-tray-icon\\.py"],
        stderr=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
    )


def format_duration(seconds):
    """Format seconds as 'Xm Ys' or 'Ys'."""
    m, s = divmod(int(seconds), 60)
    return f"{m}m {s}s" if m > 0 else f"{s}s"


def get_duration():
    """Read start timestamp, compute duration, clean up."""
    if not os.path.exists(START_FILE):
        return ""
    try:
        with open(START_FILE) as f:
            start_ts = float(f.read().strip())
        elapsed = time.time() - start_ts
        return format_duration(elapsed)
    except (ValueError, OSError):
        return ""
    finally:
        try:
            os.remove(START_FILE)
        except FileNotFoundError:
            pass


def do_start(tray_icon=None):
    with open(START_FILE, "w") as f:
        f.write(str(time.time()))
    start_tray_icon(tray_icon)
    send_notification(
        "Backup started",
        "Borgmatic backup is running...",
        icon="state-sync",
    )


def do_finish():
    stop_tray_icon()
    dur = get_duration()
    send_notification(
        f"Backup completed{f' ({dur})' if dur else ''}",
        "Borgmatic backup finished successfully.",
        icon="security-high",
        urgency="normal",
    )


def do_fail():
    stop_tray_icon()
    dur = get_duration()
    send_notification(
        f"Backup FAILED{f' after {dur}' if dur else ''}",
        "Check: journalctl -u borgmatic",
        icon="dialog-error",
        urgency="critical",  # persistent on KDE — stays until dismissed
    )


def demo(fail=False, tray_icon=None):
    print(">> start")
    do_start(tray_icon)
    print(">> backup running (3s)...")
    time.sleep(3)
    if fail:
        print(">> fail")
        do_fail()
    else:
        print(">> finish")
        do_finish()
    print(">> done")


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(1)

    action = sys.argv[1]
    icon_arg = sys.argv[2] if len(sys.argv) > 2 else None

    if action == "start":
        do_start(icon_arg)
    elif action == "finish":
        do_finish()
    elif action == "fail":
        do_fail()
    elif action == "demo":
        demo(fail=False, tray_icon=icon_arg)
    elif action == "demo-fail":
        demo(fail=True, tray_icon=icon_arg)
    else:
        print(f"Unknown action: {action}")
        print(__doc__.strip())
        sys.exit(1)


if __name__ == "__main__":
    main()
