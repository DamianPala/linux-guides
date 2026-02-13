# Workarounds

Fixes for bugs and quirks that don't have a proper upstream solution yet.

---

## Kubuntu 25.10

### Gwenview — slow/laggy on Wayland

Gwenview renders poorly under Wayland — stuttering, slow zoom, laggy scrolling. Forcing X11 (XCB) backend fixes it.

```bash
mkdir -p ~/.local/share/applications && cp /usr/share/applications/org.kde.gwenview.desktop ~/.local/share/applications/ && sed -i 's/Exec=gwenview/Exec=env QT_QPA_PLATFORM=xcb gwenview/g' ~/.local/share/applications/org.kde.gwenview.desktop
```

This copies the `.desktop` file to user dir (overrides system one) and injects `QT_QPA_PLATFORM=xcb` into the Exec line.
