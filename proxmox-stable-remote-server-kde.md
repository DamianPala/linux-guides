# Build a Stable Remote Server on Proxmox with a KDE Desktop

Kubuntu can work well as a "server + desktop" VM, but the setup needs a few practical choices to stay smooth under load. This guide documents a production-oriented setup for Proxmox VE 9 with KDE Plasma, full-disk encryption, and XRDP access tuned for low overhead.

The focus is not maximum features. The focus is predictable behavior, low idle CPU usage, and good remote UX.

## What you'll get

- Kubuntu 25.10 VM on Proxmox VE 9
- LUKS full-disk encryption inside the VM
- XRDP with Plasma X11 session, H.264 encoding (custom xrdp 0.10.5 build)
- Reduced background services and lower memory pressure
- A repeatable baseline you can snapshot

## Prerequisites

- Proxmox VE 9 host
- Kubuntu 25.10 ISO uploaded to PVE storage
- VM ID (examples below use `113`)
- noVNC access for first-boot bootstrap (installing SSH)
- Remmina (or another RDP client) on your laptop

## Step 1: Create the VM in Proxmox

In Proxmox VE, create the VM through the wizard and set values per tab.

### General tab

- Node: your target PVE node
- VM ID: fixed ID
- Name: stable hostname-like name

### OS tab

- Use CD/DVD disc image file (iso): select Kubuntu ISO
- Guest OS type: `Linux`
- Guest OS version: `6.x - 2.6 Kernel`

### System tab

- Graphic card: `Default`
- Machine: `q35`
- BIOS: `OVMF (UEFI)`
- Add EFI Disk: `Yes`
- SCSI Controller: `VirtIO SCSI single`
- QEMU Guest Agent: `Enabled`

### Disks tab

- Bus/Device: `SCSI`
- Storage: your VM datastore (example: `local-zfs`)
- Disk size: `64 GB` or larger
- Enable: `Discard`, `IO thread`, `SSD emulation`
- Leave cache at default (`No cache`) unless you have a specific storage policy

### CPU tab

- Type: `host`
- Sockets: `1`
- Cores: `4` to start
- NUMA: `Off` unless you are doing explicit NUMA pinning

### Memory tab

Use one of these profiles depending on host RAM pressure:

- **Profile A - host has plenty of free RAM, recommended for predictable performance:**
  Memory: `8192 MB`
  Minimum Memory: `8192 MB`
  Ballooning Device: `Disabled`

- **Profile B - host runs many VMs and can hit RAM pressure:**
  Memory: `8192 MB`
  Minimum Memory: `4096 MB`
  Ballooning Device: `Enabled`

### Network tab

- Bridge: your VM bridge (example: `vmbr0`)
- Model: `VirtIO (paravirtualized)`
- Firewall: `Enabled` if you manage rules in PVE firewall

### Confirm tab

- Review all tabs and create VM
- After creation, verify in `VM -> Options` that `QEMU Guest Agent` is still enabled

## Step 2: Install Kubuntu with encryption

Use Calamares manual partitioning for a simple encrypted layout without LVM.

Target layout (UEFI/GPT):

- `EFI` - 1 GiB, `FAT32`, mount point `/boot/efi`
- `/boot` - 1 GiB, `ext4`, mount point `/boot` (unencrypted)
- `ROOT` - remaining space, `LUKS2`, mount point `/`

Calamares click path:

1. On `Partitions`, choose `Manual partitioning`.
2. If needed, create a `GPT` partition table.
3. Create the EFI partition:
   - File system: `FAT32`
   - Mount point: `/boot/efi`
   - Flag: `boot` (Calamares uses this for ESP in manual mode)
4. Create `/boot`:
   - File system: `ext4`
   - Mount point: `/boot`
   - Flags: none
5. Create root as encrypted:
   - File system/type: `LUKS2`
   - Mount point: `/`
   - Label: `ROOT` (optional, for readability)
   - Set a strong passphrase
6. Continue with user/timezone/hostname and install.

**Important:** do not set the `boot` flag on `/boot` or `/`. Keep it only on the EFI partition.

**Security note:** encryption inside the VM protects data at rest (especially when the VM is powered off and LUKS is locked), but it does not protect against a hostile or compromised Proxmox host while the VM is running.

## Step 3: Bootstrap SSH via noVNC, then continue over SSH

After first boot, use noVNC only to install SSH access. Do not continue full system setup in noVNC.

### 3A. In noVNC console (bootstrap only)

```bash
sudo apt install -y openssh-server
```

### 3B. Reconnect over SSH and continue setup

```bash
ssh <user>@<vm_ip>
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now fstrim.timer qemu-guest-agent
sudo reboot
```

### Verification (after reboot, over SSH)

```bash
systemctl status ssh qemu-guest-agent --no-pager
```

From this point, prefer administration over SSH. Keep noVNC as an emergency console path.

## Step 4: Ensure Plasma X11 session for XRDP

Kubuntu 25.10 may need explicit X11 session packages for stable XRDP behavior.

```bash
sudo apt install -y plasma-session-x11 kwin-x11 dbus-x11

cat > ~/.xsession << 'EOF'
setxkbmap pl -option altwin:swap_lalt_lwin
startplasma-x11
EOF

chmod 644 ~/.xsession
sudo reboot
```

`setxkbmap pl -option altwin:swap_lalt_lwin` fixes Alt/Meta modifier swap that xrdp introduces on session start.

After the reboot, test a fresh XRDP login from Remmina (do not reuse an old client session).

## Step 5: Apply low-overhead tuning

Disable services you don't need:

```bash
sudo systemctl disable --now bluetooth.service avahi-daemon.service ModemManager.service 2>/dev/null || true
sudo systemctl disable --now cups.socket cups.path cups-browsed.service 2>/dev/null || true
```

Disable Baloo indexing (KDE Plasma 6):

```bash
balooctl6 status
balooctl6 disable
balooctl6 purge
```

Set conservative VM memory behavior:

```bash
cat <<'EOF_SYSCTL' | sudo tee /etc/sysctl.d/99-vm-tuning.conf
vm.swappiness=10
vm.vfs_cache_pressure=100
EOF_SYSCTL

sudo sysctl --system
```

### Swapfile: create or resize to 8G

Use this as the default path for this VM profile. The block below handles both cases: existing `/swapfile` (resize) and missing `/swapfile` (create). It also normalizes `fstab` to a single canonical swapfile entry.

```bash
if [ -f /swapfile ]; then
  sudo swapoff /swapfile || true
else
  sudo touch /swapfile
fi

sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile

# Keep only one /swapfile entry in fstab, then append canonical line.
sudo sed -i '/^[[:space:]]*\/swapfile[[:space:]]\+/d' /etc/fstab
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

sudo swapon -a
swapon --show
```

## Step 6: Build xrdp 0.10.5 + xorgxrdp 0.10.5 with H.264

The Ubuntu repo xrdp does not include H.264 support. Building from upstream source with `--enable-x264` and `--enable-openh264` enables GFX H.264 encoding, which significantly improves visual quality and bandwidth efficiency for RDP connections.

### Enable source repos (if not already enabled)

Kubuntu 25.10 uses deb822 format. Enable source repos so `apt-get source` works:

```bash
sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
sudo apt update
```

### Install build dependencies

```bash
sudo apt install -y build-essential devscripts debhelper dh-autoreconf \
  autoconf automake libtool pkg-config nasm \
  libssl-dev libpam0g-dev libjpeg-dev libfuse3-dev libopus-dev \
  libx264-dev libopenh264-dev \
  libepoxy-dev libgbm-dev xserver-xorg-dev
```

### Build xrdp

```bash
mkdir -p ~/build/xrdp-0.10.5-h264 && cd ~/build/xrdp-0.10.5-h264

# Download upstream source
curl -sL https://github.com/neutrinolabs/xrdp/releases/download/v0.10.5/xrdp-0.10.5.tar.gz | tar xz
cd xrdp-0.10.5

# Get debian packaging from repo (requires deb-src repos enabled)
apt-get source --download-only xrdp
dpkg-source -x xrdp_*.dsc xrdp-deb-src
cp -a xrdp-deb-src/debian .

# Disable patches that don't apply to 0.10.5
sed -i 's/^config.diff/#config.diff/' debian/patches/series
sed -i 's/^document-certs.diff/#document-certs.diff/' debian/patches/series

# Add --enable-x264 and --enable-openh264 to debian/rules
sed -i '/--enable-vsock/a\          --enable-x264 \\\n\t    --enable-openh264 \\' debian/rules

# Update changelog
dch -v "0.10.5-1+h264" "New upstream 0.10.5 with x264 and openh264 support"

# Clean old artifacts and build
rm -f debian/files debian/*.substvars debian/debhelper-build-stamp
rm -rf debian/xrdp debian/.debhelper
dpkg-buildpackage -us -uc -b
```

Output: `~/build/xrdp-0.10.5-h264/xrdp_0.10.5-1+h264_amd64.deb`

### Build xorgxrdp

```bash
mkdir -p ~/build/xorgxrdp-0.10.5-h264 && cd ~/build/xorgxrdp-0.10.5-h264

# Download upstream source
curl -sL https://github.com/neutrinolabs/xorgxrdp/releases/download/v0.10.5/xorgxrdp-0.10.5.tar.gz | tar xz
cd xorgxrdp-0.10.5

# Get debian packaging from repo
apt-get source --download-only xorgxrdp
dpkg-source -x xorgxrdp_*.dsc xorgxrdp-deb-src
cp -a xorgxrdp-deb-src/debian .

# Refresh fix_perms.diff (line offset changed in 0.10.5)
sed -i 's/@@ -1552,7 +1552,7 @@/@@ -1567,7 +1567,7 @@/' debian/patches/fix_perms.diff

# Update changelog
dch -v "1:0.10.5-1+h264" "New upstream 0.10.5"

# Build
dpkg-buildpackage -us -uc -b
```

Output: `~/build/xorgxrdp-0.10.5-h264/xorgxrdp_0.10.5-1+h264_amd64.deb`

### Install

```bash
sudo dpkg -i ~/build/xrdp-0.10.5-h264/xrdp_0.10.5-1+h264_amd64.deb
sudo dpkg -i ~/build/xorgxrdp-0.10.5-h264/xorgxrdp_0.10.5-1+h264_amd64.deb
sudo apt-mark hold xrdp xorgxrdp
sudo adduser xrdp ssl-cert
sudo systemctl daemon-reload
sudo systemctl enable --now xrdp
```

### Verify

```bash
# Check x264 is linked
ldd /usr/sbin/xrdp | grep x264

# Check service is running
systemctl status xrdp
ss -tlnp | grep 3389

# After connecting a client, check logs for H.264 negotiation
journalctl -u xrdp --since "1 min ago" | grep -E 'Matched H264|x264|encoder'
```

H.264 encoder tuning is covered in Step 7 (`gfx.toml`).

## Step 7: Tune XRDP

Two files to configure: `xrdp.ini` (connection settings) and `gfx.toml` (H.264 encoder profiles).

### 7A. Deploy gfx.toml

Replace the default `gfx.toml` with a clean config. Profiles are selected by the client's Network connection type setting (LAN, WAN, etc.).

Key changes from default:
- `veryfast` instead of `ultrafast` (enables CABAC + B-frames, big quality jump, ~5-10% CPU on Ryzen 3700X)
- `threads = 2` (better throughput, safe on 8-core CPU)
- Per-profile bitrate limits for WAN/mobile connections

```bash
sudo cp /etc/xrdp/gfx.toml /etc/xrdp/gfx.toml.bak.$(date +%F-%H%M%S)

sudo tee /etc/xrdp/gfx.toml << 'EOF'
[codec]
order = [ "H.264", "RFX" ]
h264_encoder = "x264"

[x264.default]
preset = "veryfast"
tune = "zerolatency"
profile = "main"
vbv_max_bitrate = 0
vbv_buffer_size = 0
fps_num = 60
fps_den = 1
threads = 2

[x264.lan]
# inherits default, no bitrate limit

[x264.wan]
vbv_max_bitrate = 20_000
vbv_buffer_size = 2_000

[x264.broadband_high]
preset = "superfast"
vbv_max_bitrate = 10_000
vbv_buffer_size = 1_000

[x264.satellite]
preset = "superfast"
vbv_max_bitrate = 5_000
vbv_buffer_size = 500

[x264.broadband_low]
vbv_max_bitrate = 2_000
vbv_buffer_size = 200
fps_num = 30

[x264.modem]
preset = "fast"
vbv_max_bitrate = 1_200
vbv_buffer_size = 100
fps_num = 30
EOF
```

Bandwidth requirements per profile:

| Profile | Bitrate limit | Min link speed | Use case |
|---------|--------------|----------------|----------|
| `lan` | unlimited | 100+ Mb/s | Ethernet, WiFi 5GHz |
| `wan` | 20 Mb/s | ~25 Mb/s | LTE hotspot, good signal |
| `broadband_high` | 10 Mb/s | ~15 Mb/s | Average LTE |
| `satellite` | 5 Mb/s | ~8 Mb/s | High-latency links |
| `broadband_low` | 2 Mb/s | ~3 Mb/s | Weak signal, 3G |
| `modem` | 1.2 Mb/s | ~2 Mb/s | Emergency |

### 7B. Tune xrdp.ini

Instead of editing `xrdp.ini` by hand, run this block on the VM. It is idempotent:

- existing key with wrong value -> updated
- commented key -> uncommented and updated
- missing key in existing section -> added
- missing section -> created

```bash
sudo bash <<'EOF_XRDP'
set -euo pipefail

FILE=/etc/xrdp/xrdp.ini

if [[ ! -f "$FILE" ]]; then
  echo "Error: $FILE not found" >&2
  exit 1
fi

backup="$FILE.bak.$(date +%F-%H%M%S)"
cp "$FILE" "$backup"
echo "Backup saved: $backup"

set_ini_key() {
  local file=$1 section=$2 key=$3 value=$4
  local tmp
  tmp=$(mktemp)

  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN { in_section=0; section_found=0; key_written=0 }
    function write_key_once() {
      if (!key_written) {
        print key "=" value
        key_written = 1
      }
    }
    {
      if ($0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$") {
        section_found=1
        in_section=1
        print
        next
      }
      if (in_section && $0 ~ "^[[:space:]]*\\[[^]]+\\][[:space:]]*$") {
        write_key_once()
        in_section=0
        print
        next
      }
      if (in_section && $0 ~ "^[[:space:]]*[#;]?[[:space:]]*" key "[[:space:]]*=") {
        write_key_once()
        next
      }
      print
    }
    END {
      if (in_section) write_key_once()
      if (!section_found) {
        print ""
        print "[" section "]"
        print key "=" value
      }
    }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}

# [Globals]
set_ini_key "$FILE" "Globals" "tcp_nodelay" "true"
set_ini_key "$FILE" "Globals" "tcp_keepalive" "true"
set_ini_key "$FILE" "Globals" "use_fastpath" "both"
set_ini_key "$FILE" "Globals" "max_bpp" "32"
set_ini_key "$FILE" "Globals" "security_layer" "tls"
set_ini_key "$FILE" "Globals" "crypt_level" "high"
set_ini_key "$FILE" "Globals" "ssl_protocols" "TLSv1.2,TLSv1.3"
set_ini_key "$FILE" "Globals" "bitmap_cache" "true"
set_ini_key "$FILE" "Globals" "bitmap_compression" "true"
set_ini_key "$FILE" "Globals" "bulk_compression" "true"

# [Channels]
set_ini_key "$FILE" "Channels" "rdpdr" "true"
set_ini_key "$FILE" "Channels" "rdpsnd" "true"
set_ini_key "$FILE" "Channels" "drdynvc" "true"
set_ini_key "$FILE" "Channels" "cliprdr" "true"
set_ini_key "$FILE" "Channels" "rail" "false"
set_ini_key "$FILE" "Channels" "xrdpvr" "false"

# [Xorg]
set_ini_key "$FILE" "Xorg" "h264_frame_interval" "16"
set_ini_key "$FILE" "Xorg" "rfx_frame_interval" "32"
set_ini_key "$FILE" "Xorg" "normal_frame_interval" "40"

systemctl daemon-reload
reboot
EOF_XRDP
```

Changes from the stock xrdp.ini:
- `max_bpp=32` (GFX pipeline negotiates 32bpp)
- `bitmap_cache/compression/bulk_compression=true` (faster fallback path)
- `rfx_frame_interval=32` (~30fps, RFX uses more bandwidth than H.264, 60fps is wasteful)
- `normal_frame_interval=40` (~25fps for legacy bitmap mode)
- `drdynvc=true` (required for GFX pipeline, without it H.264/RFX won't work)

### Verification

After reboot, connect from Remmina and check which codec was negotiated:

```bash
journalctl -u xrdp --since "5 min ago" | grep -iE 'h264|rfx|gfx|codec'
```

You should see H.264 selected. If you see RFX or no GFX messages, check that Remmina's color depth is set to `GFX AVC420` and network type to `LAN`.

## Step 8: Configure Remmina client (Flatpak)

The apt version of Remmina does not include H.264 support. Use the Flatpak version.

### 8A. Install

```bash
flatpak install -y flathub org.remmina.Remmina
```

### 8B. Fix Wayland crash

Remmina GTK3 crashes under Wayland ([bug #3122](https://gitlab.com/Remmina/Remmina/-/issues/3122)). Force XWayland:

```bash
flatpak override --user --socket=fallback-x11 --nosocket=wayland org.remmina.Remmina
```

### 8C. Dark theme (KDE Plasma)

```bash
flatpak install -y flathub org.gtk.Gtk3theme.Breeze-Dark
flatpak override --user --env=GTK_THEME=Breeze-Dark org.remmina.Remmina
```

### 8D. Connection profile settings

- Protocol: `RDP`
- Server: `VM_IP:3389`
- Color depth: `GFX AVC420 (32bpp)` (xrdp 0.10.5 does not support AVC444)
- Network connection type: `LAN` (home/office) or `WAN` (mobile hotspot)
- Quality: `Best` or `Good`

## Step 9: Tools

Baseline toolset for a remote dev/admin server. Snapshot the VM before installing tools.

### apt

```bash
sudo add-apt-repository -y ppa:git-core/ppa
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt update

sudo apt install -y \
  build-essential clang clang-format clang-tidy cmake git gh ninja-build pkg-config \
  fzf htop iotop iftop jq lm-sensors nethogs nload npm p7zip-full pv \
  sd shellcheck shfmt tmux \
  apparmor-utils iperf3 nmap socat sshfs traceroute wireguard \
  fail2ban nftables
```

### Rust toolchain + cargo

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
cargo install --locked \
  ast-grep bat bottom difftastic du-dust eza fd-find \
  ripgrep tealdeer uv

# delta: oniguruma uses old-style C that GCC 15 (C23 default) rejects, force C17
CFLAGS="-std=gnu17" cargo install --locked git-delta

sudo ln -s ~/.cargo/bin/{eza,bat,fd,rg} /usr/local/bin/
```

### uv (Python)

```bash
uv python install --default
python -m pip install --break-system-packages argcomplete  # pure Python, no deps — safe
sudo "$(dirname "$(readlink -f "$(which python)")")/activate-global-python-argcomplete"
uv tool install hatch
uv tool install ruff
uv tool install pyright
uv tool install pip-audit
uv tool install trash-cli
```

### Go

```bash
GO_VERSION=$(curl -s 'https://go.dev/dl/?mode=json' | jq -r '.[0].version')
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" | sudo tar -C /usr/local -xzf -
echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

```bash
go install github.com/charmbracelet/glow/v2@latest
go install github.com/mikefarah/yq/v4@latest
```

### Neovim

```bash
curl -L https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz | sudo tar xz -C /opt
sudo ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim
```

### lazygit + delta

```bash
curl -sL $(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep -Po '"browser_download_url": "\K[^"]*linux_x86_64.tar.gz') | tar xz lazygit && sudo install lazygit /usr/local/bin && rm lazygit

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

git config --global core.pager delta
git config --global interactive.diffFilter "delta --color-only"
git config --global delta.navigate true
git config --global delta.line-numbers true
git config --global delta.side-by-side false
git config --global alias.dlog '-c diff.external=difft log --ext-diff'
git config --global alias.dshow '-c diff.external=difft show --ext-diff'
git config --global alias.ddiff '-c diff.external=difft diff'
```

### Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
newgrp docker
```

### lazydocker

Terminal UI for Docker (like lazygit for git):

```bash
curl -sL $(curl -s https://api.github.com/repos/jesseduffield/lazydocker/releases/latest | grep -Po '"browser_download_url": "\K[^"]*Linux_x86_64.tar.gz') | tar xz lazydocker && sudo install lazydocker /usr/local/bin && rm lazydocker
```

### ctop

Real-time container metrics (`htop` for containers):

```bash
curl -sL $(curl -s https://api.github.com/repos/bcicen/ctop/releases/latest | grep -Po '"browser_download_url": "\K[^"]*linux-amd64"') -o ctop && sudo install ctop /usr/local/bin && rm ctop
```

### Caddy

Reverse proxy for microservices with automatic HTTPS:

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

### npm

```bash
npm config set prefix ~/.local
npm install -g @anthropic-ai/claude-code@latest
npm install -g @openai/codex@latest
npm install -g agent-browser oxlint ccusage
agent-browser install --with-deps
```

### glow config

```bash
mkdir -p ~/.config/glow
cat > ~/.config/glow/glow.yml << 'EOF'
width: 0
EOF
```

### Bashrc

```bash
cp ~/.bashrc ~/.bashrc.bak 2>/dev/null
wget -qO ~/.bashrc https://raw.githubusercontent.com/DamianPala/linux-guides/main/dotfiles/bashrc-server
sudo cp ~/.bashrc /root/.bashrc
source ~/.bashrc
```

## Step 10: Security

### fail2ban

fail2ban works out of the box for SSH. Verify it's running:

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

### AppArmor: fix WireGuard

Kubuntu 25.10 ships an AppArmor profile for `wg-quick` that is too restrictive (blocks `/proc/*/mounts` reads and `cap_net_bind_service` for `ip`). This prevents `wg-quick up` from working. Disable the profile:

```bash
sudo aa-disable /usr/bin/wg-quick
```

### SSH hardening

Requires SSH key already deployed (`ssh-copy-id` from client).

```bash
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh
```

### Firewall (nftables)

```bash
sudo systemctl enable --now nftables
```

Install `nftables-apply` (safe remote rule changes with automatic rollback on timeout):

```bash
sudo wget -O /usr/sbin/nftables-apply \
  https://gist.githubusercontent.com/fbouynot/00f89f4bcaa2b1fa4b9f70b24ebc8cc6/raw/78039c92341f84f8e53651497cbd24ba627f5483/nftables-apply
sudo chmod a+x /usr/sbin/nftables-apply
```

Usage: edit `/etc/nftables-candidate.conf`, then run `sudo nftables-apply`. If you don't confirm within 30s (e.g. you got locked out), it rolls back to the previous ruleset. On confirm, candidate becomes the active `/etc/nftables.conf`.

Deploy and apply:

```bash
sudo tee /etc/nftables-candidate.conf << 'EOF'
#!/usr/sbin/nft -f
flush ruleset

define WAN_IF = "ens18"
define WG_IF  = "wg0"
define WG_NET = 10.0.11.0/24

table inet filter {

    set wan_tcp_ports {
        type inet_service
        elements = { 22, 443 }     # SSH, HTTPS
    }

    set wan_udp_ports {
        type inet_service
        elements = { 443 }         # WireGuard
    }

    chain input {
        type filter hook input priority 0; policy drop;

        # Allow existing connections, drop broken packets, allow loopback
        ct state established,related accept
        ct state invalid drop
        iif lo accept

        # Anti-spoof: drop private/bogon sources on WAN
        iifname $WAN_IF ip saddr {
            10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
            169.254.0.0/16, 127.0.0.0/8
        } drop

        # Anti-flood
        tcp flags & (fin|syn|rst|ack) != syn ct state new drop
        tcp flags == 0x0 drop

        # ICMP (rate-limited)
        ip protocol icmp icmp type {
            echo-request, destination-unreachable, time-exceeded
        } limit rate 5/second burst 10 packets accept

        # WireGuard tunnel — trust authenticated peers
        iifname $WG_IF ip saddr $WG_NET accept

        # Public services (edit sets above)
        iifname $WAN_IF tcp dport @wan_tcp_ports accept
        iifname $WAN_IF udp dport @wan_udp_ports accept

        # Note: IPv6 not used on this host
        reject
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        # Allow existing connections, drop broken packets
        ct state established,related accept
        ct state invalid drop

        # Anti-spoof on WAN ingress
        iifname $WAN_IF ip saddr {
            10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
            169.254.0.0/16, 127.0.0.0/8
        } drop
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

sudo nftables-apply -t 5
sudo nft list ruleset
```

## References

https://www.proxmox.com/en/news/press-releases/proxmox-virtual-environment-9-0
https://kubuntu.org/download/
https://manpages.debian.org/unstable/xrdp/xrdp.ini.5.en.html
https://answers.launchpad.net/ubuntu/questing/%2Bpackage/plasma-session-x11
https://docs.kernel.org/admin-guide/sysctl/vm.html
https://pve.proxmox.com/wiki/VM_Backup_Consistency
https://neon.kde.org/faq.php
