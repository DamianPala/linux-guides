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
git config --global delta.side-by-side false
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
  qbittorrent qtqr remmina simplescreenrecorder sqlitebrowser \
  build-essential clang clang-format clang-tidy cmake git gh ninja-build pkg-config \
  libacl1-dev liblz4-dev libxxhash-dev libzstd-dev python3-dev \
  dislocker fzf htop iftop iotop jq lm-sensors logiops nethogs nload npm p7zip-full p7zip-rar pv \
  iperf3 nmap picocom qemu-system-x86 qemu-utils socat sshfs sshpass traceroute wireguard \
  screen tmux trash-cli
```

### cargo

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
cargo install --locked \
  bat bottom du-dust eza fd-find git-delta ripgrep tealdeer uv
```

### uv

```bash
uv python install --default
python -m pip install --break-system-packages argcomplete  # pure Python, no deps — safe
sudo "$(dirname "$(readlink -f "$(which python)")")/activate-global-python-argcomplete"
uv tool install hatch
```

### flatpak

```bash
sudo apt install -y flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
# Restart session after first flatpak install

flatpak install flathub org.freecad.FreeCAD
```

### snap

```bash
sudo snap install audacity
sudo snap install chromium
sudo snap install code --classic
sudo snap install discord
sudo snap install glow
sudo snap install pycharm-community --classic
sudo snap install obsidian --classic
sudo snap install sublime-text --classic
sudo snap install telegram-desktop
sudo snap install zoom-client
```

### npm

```bash
npm config set prefix ~/.local
npm install -g @anthropic-ai/claude-code@latest
npm install -g @openai/codex@latest
npm install -g ccusage
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

