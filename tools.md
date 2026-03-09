# Quick Tools Reference

Short setup notes for tools that don't need a full guide. Each entry covers install, basic config, and key settings.

---

## lazygit

Terminal UI for Git. Makes staging, committing, branching, and rebasing faster than raw git commands.

### Install

```bash
curl -sL $(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep -Po '"browser_download_url": "\K[^"]*linux_x86_64.tar.gz') | tar xz lazygit && sudo install lazygit /usr/local/bin && rm lazygit && cargo install git-delta
```

### Configuration

```bash
mkdir -p ~/.config/lazygit && cat > ~/.config/lazygit/config.yml << 'EOF'
promptToReturnFromSubprocess: false

gui:
  showIcons: true
git:
  paging:
    colorArg: always
    pager: delta --paging=never
os:
  editPreset: "nvim"
EOF
# delta config:
git config --global core.pager delta
git config --global interactive.diffFilter "delta --color-only"
git config --global delta.navigate true
git config --global delta.line-numbers true
git config --global delta.side-by-side false
# difftastic aliases (AST-aware diffs alongside delta):
git config --global alias.dlog '-c diff.external=difft log --ext-diff'
git config --global alias.dshow '-c diff.external=difft show --ext-diff'
git config --global alias.ddiff '-c diff.external=difft diff'
```

---

## bat

`cat` with syntax highlighting and line numbers. Integrates with git to show inline changes.

### Install

```bash
cargo install --locked bat
```

### Setup

```bash
cat >> ~/.bashrc << 'EOF'
alias cat='bat -pp'
eval "$(bat --completion bash)"
EOF
source ~/.bashrc
```

- `cat` → plain output with colors
- `bat` → full UI (line numbers, git changes, pager)

---

## zvm + Zig

[ZVM](https://github.com/tristanisham/zvm) (Zig Version Manager) — install and switch between Zig versions. Single static binary, only dependency is `tar`.

### Install

```bash
curl https://www.zvm.app/install.sh | bash
source ~/.bashrc
```

### Usage

```bash
zvm install master       # latest dev build
zvm install 0.14.0       # specific release
```

---

## WireGuard

Interactive setup script for WireGuard VPN — server or client mode, peer management (add/remove/list), QR codes, preshared keys, policy routing, iptables/nftables auto-detect.

### Install

```bash
mkdir -p ~/.local/bin && curl -sL https://raw.githubusercontent.com/DamianPala/linux-guides/main/scripts/setup-wireguard.sh -o ~/.local/bin/setup-wireguard && chmod 755 ~/.local/bin/setup-wireguard
```

### Usage

```bash
setup-wireguard              # First run: setup wizard. Next runs: management menu
setup-wireguard -l           # List peers
setup-wireguard --help       # Full feature list
```

---

## Misc Apps

### apt

```bash
sudo add-apt-repository -y ppa:git-core/ppa
sudo add-apt-repository -y ppa:obsproject/obs-studio
sudo add-apt-repository -y ppa:phoerious/keepassxc
sudo add-apt-repository -y ppa:qbittorrent-team/qbittorrent-stable
sudo add-apt-repository -y ppa:kitware/cmake
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt update

sudo apt install -y \
  baobab gimp k3b keepassxc meld obs-studio \
  qbittorrent qtqr simplescreenrecorder sqlitebrowser \
  build-essential clang clang-format clang-tidy cmake git gh ninja-build pkg-config \
  libacl1-dev liblz4-dev libxxhash-dev libzstd-dev python3-dev \
  gdisk dislocker fzf htop iftop iotop jq lm-sensors logiops nethogs nload npm p7zip-full p7zip-rar pv \
  sd shellcheck shfmt \
  iperf3 nmap picocom qemu-system-x86 qemu-utils socat sshfs sshpass traceroute wireguard \
  screen tmux
```

### cargo

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
cargo install --locked \
  ast-grep bat bottom cargo-careful cargo-deny difftastic du-dust eza fd-find \
  git-delta prek ripgrep tealdeer uv worktrunk
sudo ln -s ~/.cargo/bin/{eza,bat,fd,rg} /usr/local/bin/
```

### uv

```bash
uv python install --default
python -m pip install --break-system-packages argcomplete  # pure Python, no deps — safe
sudo "$(dirname "$(readlink -f "$(which python)")")/activate-global-python-argcomplete"
uv tool install hatch
uv tool install ruff
uv tool install pip-audit
uv tool install pyright
uv tool install trash-cli
uv tool install yt-dlp
```

### go

```bash
# Official installer — https://go.dev/dl/
GO_VERSION=$(curl -s 'https://go.dev/dl/?mode=json' | jq -r '.[0].version')
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" | sudo tar -C /usr/local -xzf -
echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

```bash
go install github.com/charmbracelet/glow/v2@latest
go install github.com/mikefarah/yq/v4@latest
```

Glow config — render at full terminal width (default 80 cols is too narrow):

```bash
mkdir -p ~/.config/glow
cat > ~/.config/glow/glow.yml << 'EOF'
width: 0
EOF
```

### flatpak

```bash
sudo apt install -y flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
# Restart session after first flatpak install

flatpak install flathub org.freecad.FreeCAD
flatpak install flathub org.remmina.Remmina
```

**Remmina** — apt version has no H.264 support, Flatpak does. Remove apt version first: `sudo apt remove remmina remmina-plugin-rdp`

```bash
# GTK3 crash on Wayland (bug #3122) — fallback to XWayland
flatpak override --user --socket=fallback-x11 --nosocket=wayland org.remmina.Remmina
# Dark theme for KDE Plasma
flatpak install -y flathub org.gtk.Gtk3theme.Breeze-Dark
flatpak override --user --env=GTK_THEME=Breeze-Dark org.remmina.Remmina
```

Set Color depth to **GFX AVC444** (best quality, needs H.264 on server) or **Automatic**. Migrating connections from apt → see [system-migration.md](system-migration.md#flatpak-application-migration).

### snap

```bash
sudo snap set system refresh.timer=sun,03:00-04:00
snap refresh --time
sudo snap install audacity
sudo snap install chromium
sudo snap install code --classic
sudo snap install discord
sudo snap install pycharm-community --classic
sudo snap install obsidian --classic
sudo snap install sublime-text --classic
sudo snap install telegram-desktop
sudo snap install zoom-client
```

### npm

```bash
npm config set prefix ~/.local
corepack enable --install-directory ~/.local/bin pnpm
npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest agent-browser oxlint ccusage
agent-browser install --with-deps
```

### Separate

| App | Download |
|-----|----------|
| Anki | https://apps.ankiweb.net/ |
| Calibre | https://calibre-ebook.com/download_linux |
| Chrome | https://www.google.com/chrome/ |
| KiCad | https://www.kicad.org/download/linux/ |
| LibreCAD | https://github.com/LibreCAD/LibreCAD/releases |
| Mullvad VPN | https://mullvad.net/en/download/vpn/linux |
| NoMachine | https://www.nomachine.com/download |
| Signal | https://signal.org/download/linux/ |
| Speedtest CLI | https://www.speedtest.net/apps/cli |
| Synology Drive | https://www.synology.com/en-global/support/download |
| VirtualBox | https://www.virtualbox.org/wiki/Linux_Downloads |

