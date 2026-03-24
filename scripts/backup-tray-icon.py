#!/usr/bin/python3
"""Borgmatic backup tray icon.

Minimal system tray icon shown during backup.
Killed via SIGTERM when backup finishes.
"""
import signal
import sys

from PyQt6.QtCore import QTimer
from PyQt6.QtGui import QIcon
from PyQt6.QtWidgets import QApplication, QSystemTrayIcon

DEFAULT_ICON = "state-sync"
TOOLTIP = "Borgmatic backup in progress..."


def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)

    signal.signal(signal.SIGTERM, lambda *_: app.quit())
    signal.signal(signal.SIGINT, lambda *_: app.quit())

    # Timer wakes Python from Qt's C event loop so signal handlers fire
    timer = QTimer()
    timer.start(500)
    timer.timeout.connect(lambda: None)

    if not QSystemTrayIcon.isSystemTrayAvailable():
        sys.exit(0)

    icon_name = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ICON
    icon = QIcon.fromTheme(icon_name)
    if icon.isNull():
        icon = QIcon.fromTheme("document-save")

    tray = QSystemTrayIcon(icon)
    tray.setToolTip(TOOLTIP)
    tray.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
