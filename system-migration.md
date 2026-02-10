# Linux System Migration

How to migrate a Kubuntu/KDE Plasma system to a new installation — export configs from the old system, transfer them, and verify everything works. This covers the data and configuration side, not partitioning or OS installation.

**Related guides:**
- [System Backup & Disaster Recovery](system-backup-disaster-recovery.md) — partitioning, LUKS, Borg backups
- [Laptop Setup](laptop-setup.md) — hardware-specific tweaks (sleep, wake, power)
- [Tools](tools.md) — application installation lists
- [AI Setup](ai-setup.md), [LazyVim](lazyvim.md), [eza](eza.md), [Zellij](zellij.md) — individual tool configs

---

## Pre-Migration: Audit & Export

Run these on the **old system** before wiping anything. The goal is to capture what you have installed and what configs matter, so you don't discover missing things three weeks later.

### Export Installed Packages

```bash
mkdir -p ~/migration

# showmanual = only manually installed, skips auto-deps
apt-mark showmanual | sort > ~/migration/apt-packages.txt
snap list | awk 'NR>1 {print $1}' > ~/migration/snap-packages.txt
flatpak list --app --columns=application | sort > ~/migration/flatpak-packages.txt
ls ~/.cargo/bin/ > ~/migration/cargo-bins.txt
npm list -g --depth=0 2>/dev/null | awk 'NR>1 {print $2}' > ~/migration/npm-global.txt
pipx list --short 2>/dev/null > ~/migration/pipx-packages.txt
```

### Export Configs

```bash
mkdir -p ~/migration/.local
cp -r ~/.config ~/migration/.config
cp -r ~/.local/share ~/migration/.local/share
```

Don't restore these wholesale. Browse through both directories manually on the old system — the tables below are a starting point, but your setup will have app-specific data worth keeping that isn't listed here. Restore only what you need on the new system.

**Worth restoring from `~/.config`:**

| Path | What |
|------|------|
| `remmina/` | Remote desktop connections |
| `kwalletrc` | KDE Wallet config |
| `kglobalshortcutsrc` | Global keyboard shortcuts — review manually |
| `kcminputrc` | Mouse/touchpad/keyboard settings — review manually |
| `konsolerc` + `konsolesshconfig` | Konsole terminal settings |
| `lazygit` | Lazygit config |
| `calibre/` | Calibre settings, plugins, customizations, move `~/Calibre Library` as well |
| `~/.nx/config/` | NoMachine — `player.cfg` (settings) + `hosts.crt` (trusted server certs), copy `~/Documents/NoMachine/*.nxs` for saved connections |
| `VirtualBox/` | VM registry and settings — fix absolute paths in `VirtualBox.xml` if storage mount points changed, run `sudo /sbin/vboxconfig` to build kernel module |
| `FreeCAD/` | Preferences, toolbars, shortcuts (only for non-Flatpak installs) |
| `libreoffice/4/user/` | Entire profile — settings, extensions, macros, custom dictionaries, autocorrect, toolbar customizations. "4" is the profile format version (unchanged since LO 4), works across 7.x → 24.x. Some extensions may need reinstalling |
| `LibreCAD/` + `LibreCADrc` | Settings, also copy `~/.local/share/LibreCAD/` for custom hatches/fonts |

**Warning:** KDE config files (`kglobalshortcutsrc`, `kcminputrc`, `konsolerc`) can change structure between Plasma major versions (e.g. 5 → 6). Don't blindly copy — open both old and new files side by side and transfer the values you need.

**Worth restoring from `~/.local/share`:**

| Path | What |
|------|------|
| `color-schemes/` | Custom KDE color schemes |
| `kwalletd/` | KDE Wallet data (passwords, secrets) |
| `remmina/` | Saved remote desktop connections |
| `konsole/` | Konsole profiles and color schemes |
| `fonts/` | User-installed fonts |
| `applications/` | Custom `.desktop` files |
| `Anki2/` | Flashcard decks, study progress, media |

**Worth restoring from `~/.var/app` (Flatpak apps):**

| Path | What |
|------|------|
| `org.freecad.FreeCAD/config/FreeCAD/` | Preferences, toolbars, shortcuts — reinstall addons via Addon Manager |

### Review `~/`

Before you move on, `ls ~/` and check for anything not covered above:

- `~/Documents` — includes `NoMachine/*.nxs` (saved connections)
- `~/Downloads`
- `~/Desktop`
- `~/dev-tools`
- `~/projects`
- `~/Applications`
- `/opt` - system-wide manual installs
- `~/keys`, 
- `~/scripts`
- `~/Calibre Library` - Calibre book library
- `licenses` - browse your stored licenses

---

## Dotfiles

Key dotfiles to copy from the old `~` to the new one:

| File | Purpose |
|------|---------|
| `~/.bashrc` | Shell config, aliases, prompt |
| `~/.profile` | Login shell environment |
| `~/.inputrc` | Readline config (bash key bindings) |
| `~/.gitconfig` | Git identity, aliases, delta config |
| `~/.tmux.conf` | tmux layout and bindings |
| `~/.bash_history` | Command history |
| `~/.ssh/` | Keys + config |
| `~/.gnupg/` | GPG keys |

**About SSH permissions:** after copying, make sure permissions are correct — SSH refuses to use keys with wrong permissions:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_*
```

---

## System Configuration Files

These live outside `~` and require root to copy. Transfer them manually — don't blindly restore `/etc` across different OS versions.

### Export (old system)

Mirror the real paths so restoring is obvious:

```bash
sudo mkdir -p ~/migration/{etc/udev,var/lib,usr/lib/systemd,usr/local}

sudo cp -r /etc/NetworkManager ~/migration/etc/
sudo cp -r /etc/wireguard ~/migration/etc/
sudo cp -r /etc/logid.cfg ~/migration/etc/
sudo cp -r /etc/udev/rules.d ~/migration/etc/udev/
sudo cp -r /var/lib/bluetooth ~/migration/var/lib/
sudo cp -r /usr/lib/systemd/system-sleep ~/migration/usr/lib/systemd/
sudo cp -r /usr/local/sbin ~/migration/usr/local/
```

### Restore (new system)

Copy selectively — don't blindly restore everything, configs may differ between OS versions.

```bash
# Network (WiFi passwords, VPNs, WireGuard)
sudo cp -r ~/migration/etc/NetworkManager/system-connections/* /etc/NetworkManager/system-connections/
sudo chmod 600 /etc/NetworkManager/system-connections/*
sudo systemctl restart NetworkManager

sudo cp -r ~/migration/etc/wireguard/* /etc/wireguard/
sudo chmod 600 /etc/wireguard/*

# Bluetooth pairings — stop service first
sudo systemctl stop bluetooth
sudo cp -r ~/migration/var/lib/bluetooth/* /var/lib/bluetooth/
sudo systemctl start bluetooth

# Logitech device config (logiops) — install logiops first
sudo cp ~/migration/etc/logid.cfg /etc/logid.cfg

# If logid.cfg has custom DPI — add udev rule so the desktop also uses it
sudo tee /etc/udev/rules.d/99-mx-anywhere-dpi.rules << 'EOF'
ACTION=="add|change", KERNEL=="event*", ATTRS{name}=="MX Anywhere 3", ENV{MOUSE_DPI}="2000@1000"
EOF
# Restart the mouse (toggle power off/on) for udev to apply
sudo systemctl restart logid

# Custom scripts and hooks — review before copying
ls ~/migration/usr/local/sbin/
ls ~/migration/usr/lib/systemd/system-sleep/
```

**About Bluetooth:** if the new system has a different Bluetooth adapter MAC, pairing keys won't work — you'll need to re-pair.

---

## KDE Wallet

**Restore KWallet before opening any applications.** Apps like Chrome, Firefox, Remmina, and anything that stores passwords will try to access KWallet on first launch. If the wallet isn't there yet, they'll either prompt for credentials or create new empty wallet entries — overwriting what you want to restore later.

```bash
# Restore wallet data
cp -r ~/migration/.local/share/kwalletd/* ~/.local/share/kwalletd/

# Restore wallet config
cp ~/migration/.config/kwalletrc ~/.config/kwalletrc

# Restart the wallet service to pick up restored data
kquitapp6 kwalletd6
```

Open KDE Wallet Manager and verify your wallets are listed. If the wallet uses a password, it will ask you to unlock — use the same password as on the old system.

---

## Snap Application Migration

Snap apps store config in `~/snap/<app>/current/` instead of `~/.config/`. The exact path depends on confinement type:

| App | Config path | What to copy |
|-----|-------------|--------------|
| PyCharm | `~/.config/JetBrains/PyCharmCE<ver>/` (classic — standard path) | `keymaps/`, `colors/`, `codestyles/`, `options/`, `pycharm64.vmoptions`. Auto-imports from previous versions on first launch |
| Obsidian | `~/snap/obsidian/current/.config/obsidian/` | `obsidian.json` only — fix vault paths after copying |
| Discord | `~/snap/discord/current/.config/discord/` | `settings.json` only — session data is not portable |
| Zoom | `~/snap/zoom-client/current/.config/zoomus.conf` | `zoomus.conf` — meeting settings, audio/video preferences |

**Note:** PyCharm classic snap uses standard `~/.config/` paths (same as .deb), so migration between .deb and snap is seamless — no path changes needed. PyCharm also auto-imports settings from previous versions on first launch.

---

## Browser Migration

Full profile copy — migrates everything: bookmarks, passwords, history, extensions, extension data, cookies, site permissions, open tabs.

**Before restoring profiles, install the same browser versions as on the old system.** Profile format can change between major versions, and a version mismatch may corrupt the profile or lose extension data. The export steps below save the installer alongside the profile so you can install the exact same version on the new system.

### Google Chrome

**Export (old system):**

Download the latest .deb, install it to update the old system, and keep the .deb for the new system:

```bash
wget -O ~/migration/google-chrome-stable.deb \
  https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt install ~/migration/google-chrome-stable.deb
```

Close Chrome, then copy the profile:

```bash
cp -r ~/.config/google-chrome ~/migration/.config/google-chrome
```

This copies all profiles (Default, Profile 1, etc.). Typically 1-5 GB.

**Restore (new system):**

```bash
sudo apt install ~/migration/google-chrome-stable.deb
```

Run Chrome once and close it, then restore the profile:

```bash
cp -r ~/migration/.config/google-chrome ~/.config/google-chrome
```

Open Chrome — the .deb is already the latest version, so just verify everything works.

### Firefox

Figure out how Firefox is installed — it determines the profile path and migration method:

```bash
snap list firefox          # snap if this returns a result
ls ~/Applications/firefox  # manual binary if this exists
apt list --installed firefox 2>/dev/null  # .deb if installed from Mozilla APT repo
```

#### Snap

```bash
# Export (old system)
sudo snap refresh firefox
# close Firefox, then:
snap download firefox
mv firefox_*.snap firefox_*.assert ~/migration/
cp -r ~/snap/firefox/common/.mozilla ~/migration/firefox-snap-profile
firefox --ProfileManager   # select the old profile and set as default
```

```bash
# Restore (new system)
sudo snap ack ~/migration/firefox_*.assert
sudo snap install ~/migration/firefox_*.snap
# run Firefox once, close it, then:
cp -r ~/migration/firefox-snap-profile/.mozilla ~/snap/firefox/common/.mozilla
firefox --ProfileManager   # select the old profile and set as default
```

#### .deb (Mozilla APT repo)

```bash
# Export (old system)
sudo apt update && sudo apt upgrade firefox
# close Firefox, then:
cp /var/cache/apt/archives/firefox*.deb ~/migration/
cp -r ~/.mozilla ~/migration/.mozilla
```

```bash
# Restore (new system) — needs Mozilla APT repo set up first
sudo apt install ~/migration/firefox_*.deb
# run Firefox once, close it, then:
cp -r ~/migration/.mozilla ~/.mozilla
firefox --ProfileManager   # select the old profile and set as default
```

#### Manual binary

On the new system, switch to snap or [Mozilla's APT .deb](https://support.mozilla.org/en-US/kb/install-firefox-linux#w_install-firefox-deb-package-for-debian-based-distributions) — both auto-update, unlike a manual binary.

```bash
# Export (old system) — update first: Help → About Firefox
~/Applications/firefox/firefox --version > ~/migration/firefox-version.txt
cp -r ~/.mozilla ~/migration/.mozilla
```

```bash
# Restore (new system) — install matching snap revision
cat ~/migration/firefox-version.txt
snap info firefox   # find the revision matching that version
sudo snap install firefox --revision=<REVISION>
sudo snap refresh firefox --hold   # prevent auto-update until profile is restored
# run Firefox once, close it, then:
cp -r ~/migration/.mozilla ~/snap/firefox/common/.mozilla
firefox --ProfileManager   # select the old profile and set as default
sudo snap refresh firefox --unhold
```

### Thunderbird

Profiles are forward-compatible — no need to match versions.

Figure out how Thunderbird is installed:

```bash
snap list thunderbird
apt list --installed thunderbird 2>/dev/null
```

#### Snap

```bash
# Export (old system)
cp -r ~/.thunderbird ~/migration/.thunderbird
```

```bash
# Restore (new system)
sudo snap install thunderbird
# run Thunderbird once, close it, then:
cp -r ~/migration/.thunderbird/* ~/snap/thunderbird/common/.thunderbird/
thunderbird --ProfileManager   # select the old profile and set as default
```

#### .deb

```bash
# Export (old system)
cp -r ~/.thunderbird ~/migration/.thunderbird
```

```bash
# Restore (new system)
sudo apt install thunderbird
# run Thunderbird once, close it, then:
cp -r ~/migration/.thunderbird/* ~/.thunderbird/
thunderbird --ProfileManager   # select the old profile and set as default
```

### Verify

Open all browsers and Thunderbird and check:
- Bookmarks and history are present
- Saved passwords work (try logging into a site)
- Extensions are installed and functional

---

## Post-Migration Validation

Run through this after the new system is set up and configs are restored.

### Hardware & System

| Test | How | Pass |
|------|-----|------|
| Reboot stability | Reboot 5 times | No hangs, correct boot |
| Suspend/resume (docked, 30s) | Suspend, wait 30s, resume — repeat 5x | Session intact, displays reconfigure |
| Suspend/resume (docked, 5min) | Suspend, wait 5min, resume — repeat 5x | Same (monitors enter deep sleep) |
| Suspend/resume (undocked) | Suspend on battery, resume — repeat 5x | Session intact |
| Window recovery after docking | Undock, rearrange windows, re-dock | Windows return to correct monitors |
| Bluetooth | Connect known devices | Devices pair without re-pairing |
| Session restore | Log out and log back in | KDE session restored (windows, apps) |

### Applications

| Test | How | Pass |
|------|-----|------|
| Browser profiles | Open Chrome + Firefox | Bookmarks, passwords, extensions present |
| Chrome session restore | Open tabs, close Chrome, reopen | Tabs restored |
| Remote desktop | Open Remmina | Saved connections work |
| KDE Wallet | Open an app that uses KWallet | Auto-unlocks, passwords available |
| SSH | Connect to a known host | No host key warnings, auth works |
| VPN | Connect via WireGuard / NM | Traffic routes correctly |
