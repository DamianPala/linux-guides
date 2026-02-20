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

### Spectacle — screenshots don't land in clipboard on Wayland

Spectacle captures the screen but the image never makes it to the clipboard. You can save to file, but Ctrl+V into any app does nothing. This is a known bug in `KSystemClipboard` (part of KDE Frameworks `kguiaddons`). On Wayland, setting clipboard data requires a focused surface — Spectacle loses focus during capture and the clipboard write silently fails.

The fix landed in KDE Frameworks 6.22 (kguiaddons), authored by David Edmundson. Kubuntu 25.10 ships Frameworks 6.17, and the backports PPA only goes up to 6.20. So: build kguiaddons 6.22 from source.

**Before you start:** make a system snapshot (Btrfs, Timeshift, whatever you use). You're replacing a system library — easy to roll back if something breaks.

#### Add Kubuntu Backports PPA

Gets you closer to 6.22 (Plasma 6.5.5, Frameworks 6.20) and pulls in newer Qt6 headers needed for the build.

```bash
sudo add-apt-repository ppa:kubuntu-ppa/backports
sudo apt update && sudo apt full-upgrade
```

Log out and back in after upgrade.

#### Install build dependencies

```bash
sudo apt install -y \
    git cmake build-essential \
    qt6-wayland-dev \
    qt6-declarative-dev \
    qt6-base-dev \
    qt6-base-private-dev \
    libwayland-dev
```

#### Build ECM 6.22 (extra-cmake-modules)

kguiaddons 6.22 needs ECM >= 6.22. The PPA has 6.20 — not enough.

```bash
cd /tmp
git clone --branch v6.22.0 --depth 1 \
    https://invent.kde.org/frameworks/extra-cmake-modules.git
mkdir extra-cmake-modules/build && cd extra-cmake-modules/build

cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release
make
sudo make install
```

**About the warnings:** cmake may complain about missing Sphinx or Qt6ToolsTools. That's just docs generation — the build itself succeeds fine.

#### Build kguiaddons 6.22

```bash
cd /tmp
git clone --branch v6.22.0 --depth 1 \
    https://invent.kde.org/frameworks/kguiaddons.git
mkdir kguiaddons/build && cd kguiaddons/build

cmake .. \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_PYTHON_BINDINGS=OFF
make
sudo make install
```

#### Verification

```bash
ls -la /usr/lib/x86_64-linux-gnu/libKF6GuiAddons.so.6*
```

You should see:

```
libKF6GuiAddons.so.6 -> libKF6GuiAddons.so.6.22.0   # symlink points to new
libKF6GuiAddons.so.6.20.0                             # old, from package
libKF6GuiAddons.so.6.22.0                             # new, just built
```

Log out and back in — KDE needs to load the new library. Then test: PrtSc → capture → Ctrl+V somewhere.

#### Survive apt upgrades

When apt updates `libkf6guiaddons6`, dpkg will overwrite the symlink and point it back to the packaged version. A dpkg post-invoke hook handles this automatically — it re-applies our custom .so after every apt run, and cleans itself up when the packaged version catches up to >= 6.22.

```bash
# Cache the built library and install the restore script
sudo mkdir -p /usr/local/lib/kf6-custom
sudo cp /usr/lib/x86_64-linux-gnu/libKF6GuiAddons.so.6.22.0 /usr/local/lib/kf6-custom/

sudo tee /usr/local/lib/kf6-custom/restore-kguiaddons.sh << 'EOF'
#!/bin/bash
set -euo pipefail

CUSTOM_SO="/usr/local/lib/kf6-custom/libKF6GuiAddons.so.6.22.0"
TARGET_DIR="/usr/lib/x86_64-linux-gnu"
SYMLINK="$TARGET_DIR/libKF6GuiAddons.so.6"

[ -f "$CUSTOM_SO" ] || exit 0

# Check the PACKAGE version (dpkg database), not the symlink.
# The symlink may already point to our custom 6.22.0 — that doesn't
# mean the package caught up.
pkg_ver=$(dpkg-query -W -f='${Version}' libkf6guiaddons6 2>/dev/null | sed 's/-.*//' || echo "0")

# Package caught up — clean up everything
if dpkg --compare-versions "$pkg_ver" ge "6.22.0" 2>/dev/null; then
    rm -f "$CUSTOM_SO"
    rm -f /usr/local/lib/kf6-custom/restore-kguiaddons.sh
    rmdir --ignore-fail-on-non-empty /usr/local/lib/kf6-custom 2>/dev/null || true
    rm -f /etc/apt/apt.conf.d/99-restore-kguiaddons
    exit 0
fi

# Package still behind — restore if needed
current=$(readlink "$SYMLINK" 2>/dev/null || echo "")
if [ "$current" != "libKF6GuiAddons.so.6.22.0" ]; then
    cp "$CUSTOM_SO" "$TARGET_DIR/"
    ln -sf libKF6GuiAddons.so.6.22.0 "$SYMLINK"
fi
EOF
sudo chmod +x /usr/local/lib/kf6-custom/restore-kguiaddons.sh

# Install the apt hook
echo 'DPkg::Post-Invoke { "/usr/local/lib/kf6-custom/restore-kguiaddons.sh 2>/dev/null || true"; };' \
    | sudo tee /etc/apt/apt.conf.d/99-restore-kguiaddons
```

**What this does:** after every `apt install`/`upgrade`, dpkg runs the script. It checks the *package* version from the dpkg database (not the symlink, which we control). If the package is still < 6.22, it ensures our .so is in place. Once the PPA ships >= 6.22, the script deletes itself, the cached .so, and the hook.

#### Notes

- Build dirs at `/tmp/kguiaddons` and `/tmp/extra-cmake-modules` can be deleted after installing the apt hook.
- KDE bugs: https://bugs.kde.org/show_bug.cgi?id=463199, https://bugs.kde.org/show_bug.cgi?id=512178
