#!/usr/bin/env python3
"""Borgmatic wrapper — throttles borg progress to periodic journal-friendly summaries.

Borg's --progress must be enabled via extra_borg_options in borgmatic config
(NOT via borgmatic's native progress option or CLI flag, which triggers
DO_NOT_CAPTURE and bypasses this wrapper):

    extra_borg_options:
        create: --progress

Borgmatic captures borg's JSON progress events (archive_progress) and emits
them as newline-delimited JSON on stderr. This wrapper detects those events,
throttles them to one human-readable line per INTERVAL seconds, and passes
all other output through unchanged.

Install: sudo install -m 755 borgmatic-wrapper.py /usr/local/bin/borgmatic-wrapper
systemd: replace 'borgmatic' with 'borgmatic-wrapper' in ExecStart
"""

import json
import os
import signal
import subprocess
import sys
import time

INTERVAL = 60  # seconds between progress summaries


def _format_size(nbytes: float) -> str:
    """Format bytes to human-readable."""
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if abs(nbytes) < 1000:
            if nbytes < 10:
                return f"{nbytes:.2f} {unit}"
            return f"{nbytes:.1f} {unit}"
        nbytes /= 1000
    return f"{nbytes:.1f} PB"


def _format_progress(data: dict) -> str:
    """Format archive_progress JSON into a readable one-liner."""
    orig = _format_size(data.get("original_size", 0))
    dedup = _format_size(data.get("deduplicated_size", 0))
    nfiles = data.get("nfiles", 0)
    path = data.get("path", "")
    # Truncate long paths
    if len(path) > 60:
        path = "..." + path[-57:]
    return f"O {orig} D {dedup} N {nfiles} {path}"


def main() -> int:
    proc = subprocess.Popen(
        ["borgmatic", *sys.argv[1:]],
        stdout=sys.stdout,
        stderr=subprocess.PIPE,
        bufsize=0,
    )

    # Forward signals to borgmatic so systemd stop/restart works cleanly
    def _forward_signal(signum: int, _frame: object) -> None:
        try:
            proc.send_signal(signum)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGTERM, _forward_signal)
    signal.signal(signal.SIGINT, _forward_signal)

    if proc.stderr is None:
        return proc.wait()

    stderr_fd = proc.stderr.fileno()
    last_progress_time = 0.0
    last_progress_line = ""
    buf = b""

    while True:
        try:
            chunk = os.read(stderr_fd, 4096)
        except OSError:
            break
        if not chunk:
            break

        buf += chunk

        while b"\n" in buf:
            pos = buf.find(b"\n")
            line = buf[:pos].decode("utf-8", errors="replace").strip()
            buf = buf[pos + 1 :]

            if not line:
                continue

            # Try to parse as JSON (borg/borgmatic --log-json output)
            is_progress = False
            if line.startswith("{"):
                try:
                    data = json.loads(line)
                    if data.get("type") == "archive_progress":
                        is_progress = True
                        if data.get("finished"):
                            continue
                        now = time.time()
                        formatted = _format_progress(data)
                        last_progress_line = formatted
                        if now - last_progress_time >= INTERVAL:
                            print(
                                f"[progress] {formatted}",
                                file=sys.stderr,
                                flush=True,
                            )
                            last_progress_time = now
                    elif data.get("type") == "progress_message":
                        # Cache init, etc. — pass through but not as spam
                        is_progress = True
                        msg = data.get("message", line)
                        if not data.get("finished"):
                            print(msg, file=sys.stderr, flush=True)
                    elif data.get("type") == "log_message":
                        # Borgmatic log messages — pass through
                        msg = data.get("message", line)
                        print(msg, file=sys.stderr, flush=True)
                        is_progress = True  # mark as handled
                except (json.JSONDecodeError, KeyError):
                    pass

            if not is_progress:
                # Non-JSON or unrecognized JSON — pass through as-is
                print(line, file=sys.stderr, flush=True)

        # Handle \r in buffer (borg progress without --log-json)
        while b"\r" in buf and b"\n" not in buf:
            pos = buf.find(b"\r")
            line = buf[:pos].decode("utf-8", errors="replace").strip()
            buf = buf[pos + 1 :]
            if line:
                now = time.time()
                last_progress_line = line
                if now - last_progress_time >= INTERVAL:
                    print(f"[progress] {line}", file=sys.stderr, flush=True)
                    last_progress_time = now

    # Flush remaining buffer
    if buf:
        line = buf.decode("utf-8", errors="replace").strip()
        if line:
            print(line, file=sys.stderr, flush=True)

    # Emit final progress snapshot if not recently printed
    if last_progress_line and (time.time() - last_progress_time) > 10:
        print(f"[progress] {last_progress_line}", file=sys.stderr, flush=True)

    return proc.wait()


if __name__ == "__main__":
    sys.exit(main())
