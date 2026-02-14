# Install LazyVim on Ubuntu

This guide is generic for Linux and was validated on Ubuntu 24.04 on x86_64 using `bash`.

## Requirements

- Latest Neovim
- Latest Git
- A Nerd Font (optional, for icons)
- lazygit (optional)
- A C compiler and tree-sitter CLI (for nvim-treesitter)
- curl (for blink.cmp)
- Optional: fzf, ripgrep, fd (for fzf-lua), and a terminal with true color + undercurl

See the official LazyVim requirements list for details.

## Install required system tools

On Ubuntu, the following covers the common requirements and recommended extras:

```bash
sudo apt update
sudo apt install -y git curl build-essential ripgrep fd-find fzf
```

## Install and configure Neovim

### Download and install

Install the official AppImage and place it system-wide. This keeps updates simple and avoids distro lag:

```bash
curl -L https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz | sudo tar xz -C /opt 
sudo ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim
```

Verify installation:

```bash
nvim --version
```

### Set Neovim as your default editor

If you use bash, add these lines to `~/.bashrc` so tools like `git` and `sudoedit` use Neovim:

```bash
export EDITOR=nvim
export VISUAL=nvim
```

Reload your shell to apply the changes:

```bash
source ~/.bashrc
```

### Make Neovim the `vi` replacement

On Debian-based systems, `update-alternatives` is the system-wide way to select which editor provides `vi`. Set it to Neovim:

```bash
sudo update-alternatives --install /usr/bin/vi vi /usr/local/bin/nvim 60
sudo update-alternatives --set vi /usr/local/bin/nvim
```

If you want to switch interactively later:

```bash
sudo update-alternatives --config vi
```

### Use Neovim with sudo

Use `sudoedit` instead of running the full UI as root. It edits as your user and only elevates on save:

```bash
sudoedit /etc/hosts
```

## Install a Nerd Font (recommended)

### Most recommended fonts

Use the Nerd Font (NF) variants of these fonts. They are the most recommended options for coding and terminal use:

- JetBrains (ligatures): excellent for long coding sessions; tall x-height and distinct shapes reduce eye strain. It stays crisp on dark themes like Monokai and is highly editor-friendly.
- Hack: optimized for screen legibility; clear glyphs (including dotted zero) and solid weight make it easy to read on dark backgrounds and in small sizes.
- Source Code Pro: very clean, highly readable, and gentle on the eyes; medium weight renders well on dark themes and in dense code.
- Fira Code: popular among developers; great in editors and terminals. If you like ligatures, it is a strong choice. Original version does not implement italics.
- Cascadia Code (ligatures): Used in Windows Terminal, clean, medium-width letterforms with ligatures that make operator-heavy code feel smoother; compared to Iosevka Term it is less compact and less configurable, which many people find easier on the eyes at small sizes.
- Monaspace: A compatible family of styles you can mix without layout shifts; its contextual shaping can make long stretches of code feel smoother, which can reduce eyestrain for some readers. Compared to Iosevka Term it is less about tight density and more about texture and style.
- Lilex (ligatures): Based on IBM Plex Mono with ligatures and open shapes, giving it a relaxed, readable feel; compared to CaskaydiaCove it is less geometric and a bit softer. Compared to Iosevka Term it is wider and less compact, which can reduce eyestrain for long sessions but uses more horizontal space.

You can browse these fonts using: https://www.programmingfonts.org/

### Download all recommended fonts

Nerd Fonts publishes release archives for each font family. Download all four at once:

```bash
mkdir -p /tmp/nerd-fonts
cd /tmp/nerd-fonts
curl -LO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz
curl -LO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.tar.xz
curl -LO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/SourceCodePro.tar.xz
curl -LO https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.tar.xz
```

Note: Avoid ad-hoc downloads from the repo; use the release archives for the latest fonts.

### Install the fonts (system-wide)

```bash
sudo mkdir -p /usr/local/share/fonts/nerd-fonts/{JetBrainsMono,Hack,SourceCodePro,FiraCode}
sudo tar -xf JetBrainsMono.tar.xz -C /usr/local/share/fonts/nerd-fonts/JetBrainsMono
sudo tar -xf Hack.tar.xz -C /usr/local/share/fonts/nerd-fonts/Hack
sudo tar -xf SourceCodePro.tar.xz -C /usr/local/share/fonts/nerd-fonts/SourceCodePro
sudo tar -xf FiraCode.tar.xz -C /usr/local/share/fonts/nerd-fonts/FiraCode
```

### Refresh the font cache

```bash
sudo fc-cache -fv /usr/local/share/fonts
```

You may need to restart running applications to see the changes.

### Check font names and list installed fonts

List all installed font families and filter by name:

```bash
fc-list :family | sort -u | rg -i "nerd|jetbrains|fira|hack|source"
```

Verify the exact font family name you should use in terminal settings:

```bash
fc-match "Hack Nerd Font Mono"
```

### Select the font in your terminal

Open your terminal settings and choose the Nerd Font you installed (for example, "JetBrainsMono Nerd Font"). This is required to see icons in LazyVim and other tools.

## Install LazyVim

Back up any existing Neovim config:

```bash
mv ~/.config/nvim{,.bak}
mv ~/.local/share/nvim{,.bak}
mv ~/.local/state/nvim{,.bak}
mv ~/.cache/nvim{,.bak}
```

Clone the LazyVim starter and remove its git history:

```bash
git clone https://github.com/LazyVim/starter ~/.config/nvim
rm -rf ~/.config/nvim/.git
```

Start Neovim:

```bash
nvim
```

## Health check

Inside Neovim, run:

```
:LazyHealth
```

Address any missing dependencies it reports.

## Themes

### Example: Monokai Pro

Create the plugin spec:

```bash
cat <<'EOF' > ~/.config/nvim/lua/plugins/monokai-pro.lua
return {
  {
    "loctvl842/monokai-pro.nvim",
    config = function()
      require("monokai-pro").setup({
        filter = "spectrum", -- classic|octagon|pro|machine|ristretto|spectrum
      })
    end,
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "monokai-pro",
    },
  },
}
EOF
```

Restart Neovim or run:

```
:Lazy sync
```

If you want a different variant, change `filter` in the setup block. See the plugin README for all available options.

### Tweaks

#### One-time setup

Create the options file once:

```bash
mkdir -p ~/.config/nvim/lua/config
touch ~/.config/nvim/lua/config/options.lua
```

#### Disable relative line numbers

This command updates the setting if it already exists; otherwise it appends it:

```bash
f=~/.config/nvim/lua/config/options.lua
sed -i '/vim.opt.relativenumber/d' "$f"
echo 'vim.opt.relativenumber = false' >> "$f"
```

## Notes

- If you do not see icons, install and select a Nerd Font in your terminal.
- If Neovim does not start, re-check the version and PATH.

## References

- LazyVim installation: https://www.lazyvim.org/installation
- LazyVim requirements: https://www.lazyvim.org/
- Neovim install options: https://neovim.io/doc/install/
- Nerd Fonts downloads: https://www.nerdfonts.com/font-downloads
- Nerd Fonts releases: https://github.com/ryanoasis/nerd-fonts/releases


# Notes

In Konsole, Hack has 4 lines more at the same 10pt size than JetBrains.

Check ghostty supported fonts:

```
ghostty +list-fonts | grep FiraCode
```

FiraCode does not have italic by default.