# Quick Tools Reference

Short setup notes for tools that don't need a full guide. Each entry covers install, basic config, and key settings.

---

## lazygit

Terminal UI for Git. Makes staging, committing, branching, and rebasing faster than raw git commands.

### Install

```bash
curl -sL $(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep -Po '"browser_download_url": "\K[^"]*Linux_x86_64.tar.gz') | tar xz lazygit && sudo install lazygit /usr/local/bin && rm lazygit && cargo install git-delta
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

- `cat` → plain output with colors (syntax highlighting only)
- `bat` → full UI (line numbers, git changes, grid, pager)




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
  baobab \
  gimp \
  keepassxc \
  meld \
  qtqr \
  sqlitebrowser \
  p7zip-full p7zip-rar \
  simplescreenrecorder \
  k3b \
  obs-studio \
  remmina \
  build-essential cmake ninja-build \
  clang clang-format clang-tidy \
  git gh \
  jq fzf \
  qemu-system-x86 qemu-utils \
  htop iotop nload iftop nethogs \
  nmap socat iperf3 \
  sshfs sshpass wireguard \
  tmux screen \
  pv \
  trash-cli \
  qbittorrent
```

### cargo

```bash
cargo install --locked \
  ripgrep \
  fd-find \
  bat \
  eza \
  du-dust \
  git-delta \
  bottom \
  tealdeer
```

### snap

```bash
sudo snap install discord
sudo snap install pycharm-community --classic
sudo snap install telegram-desktop
sudo snap install zoom-client
sudo snap install code --classic
sudo snap install chromium
sudo snap install audacity
sudo snap install glow
sudo snap install sublime-text --classic
```

### npx

```bash
sudo npm install -g @anthropic-ai/claude-code@latest
sudo npm install -g @openai/codex@latest
sudo npm install -g ccusage
```

### Separate

| App | Download |
|-----|----------|
| Anki | https://apps.ankiweb.net/ |
| VirtualBox | https://www.virtualbox.org/wiki/Linux_Downloads |
| LibreCAD | https://github.com/LibreCAD/LibreCAD/releases |
| FreeCAD | https://www.freecad.org/downloads.php (AppImage) |
| Calibre | https://calibre-ebook.com/download_linux |
| Obsidian | https://obsidian.md/download |
| Chrome | https://www.google.com/chrome/ |
| Signal | https://signal.org/download/linux/ |
| Mullvad VPN | https://mullvad.net/en/download/vpn/linux |
| Synology Drive | https://www.synology.com/en-global/support/download |
| NoMachine | https://www.nomachine.com/download |
| Speedtest CLI | https://www.speedtest.net/apps/cli |
| KiCad | https://www.kicad.org/download/linux/ |









