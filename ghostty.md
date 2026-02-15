# Install Ghostty on Kubuntu

Ghostty is a GPU-accelerated terminal emulator built in Zig with a GTK frontend on Linux. Fast rendering, a flat config file, built-in shell integration, and native Wayland support. No Electron, no web stack.

---

## Install

### PPA

Mike Kasberg maintains an unofficial PPA that tracks Ghostty stable releases:

```bash
sudo add-apt-repository ppa:mkasberg/ghostty-ubuntu
sudo apt update
sudo apt install ghostty
```

### Build from source

For the latest features or when the PPA doesn't cover your Ubuntu version. Requires Zig via ZVM (see [tools.md](tools.md#zvm--zig)).

**Dependencies:**

```bash
sudo apt install -y libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev blueprint-compiler gettext
```

**Build:**

```bash
# Check required Zig version in build.zig.zon (field .minimum_zig_version)
zvm install 0.15.2
zvm use 0.15.2

git clone https://github.com/ghostty-org/ghostty.git ~/src/ghostty
cd ~/src/ghostty
git pull --tags --force
git checkout "$(git describe --tags --abbrev=0)"
zig build -Doptimize=ReleaseFast
```

Binary lands in `zig-out/bin/ghostty`. Install it:

```bash
sudo install -m 0755 zig-out/bin/ghostty /usr/bin/
```

To update later — pull the latest tag and rebuild:

```bash
cd ~/src/ghostty
git pull --tags --force
git checkout "$(git describe --tags --abbrev=0)"
zig build -Doptimize=ReleaseFast
sudo install -m 0755 zig-out/bin/ghostty /usr/bin/
```

### Verification

```bash
ghostty --version
```

---

## Configuration

Ghostty reads `~/.config/ghostty/config` — a flat key-value file, no TOML/YAML nesting. Comments start with `#`.

To install the config from this repo:

```bash
mkdir -p ~/.config/ghostty/themes
cp dotfiles/ghostty/config ~/.config/ghostty/config
cp dotfiles/ghostty/themes/* ~/.config/ghostty/themes/
```

See [dotfiles/ghostty/config](dotfiles/ghostty/config) for the full file. Key sections below.

---

## SSH and TERM

Remote hosts don't have the `xterm-ghostty` terminfo entry, which causes broken rendering (missing colors, garbled output). Two approaches:

**Override TERM on connect** (used in [aliases.sh](dotfiles/bashrc.d/aliases.sh)):

```bash
function ssh { TERM=xterm-256color command ssh "$@"; }
export -f ssh
```

**Copy terminfo to remote host** (preserves Ghostty-specific features):

```bash
infocmp -x xterm-ghostty | ssh user@host -- tic -x -
```

The TERM override is simpler and works everywhere. Copying terminfo is better for servers you use frequently — it keeps features like undercurl and styled underlines.

---

## What the config gives you

**Splits** — `Ctrl+Shift+L` split right, `Ctrl+Shift+O` split down, `Ctrl+Shift+Arrow` navigate, `Ctrl+Shift+Enter` zoom/unzoom a split, `Ctrl+Shift+E` equalize sizes. Resize with `Ctrl+Shift+Alt+Arrow`.

**Prompt jumping** — `Alt+Up` / `Alt+Down` jumps between command prompts in the scrollback instead of scrolling line-by-line. Requires shell integration.

**Word deletion** — `Ctrl+Backspace` deletes previous word, `Ctrl+Delete` deletes next word. Works in bash, zsh, and most TUIs.

**Copy on select** — selecting text copies it to clipboard immediately (Konsole behavior). Paste protection warns before pasting text with newlines or control characters.

**Shell integration** — auto-detected for bash/zsh/fish. Cursor shape changes at prompt, window title tracks cwd, new tabs inherit working directory.

**128 MB scrollback** — for heavy log tailing. Scrollback limit is in bytes, not lines. `Ctrl+Home` / `Ctrl+End` jump to top/bottom.

**Transparent background** — `background-opacity = 0.9` with `background-blur`. Tweak opacity to taste; blur intensity is controlled by KWin, not Ghostty.

**Tabs in titlebar** — no window decoration, tabs serve as the title bar. Drag by the tab bar on KDE Plasma.

**Font fallback chain** — Hack Nerd Font Mono primary, Hack and Noto Sans Mono as fallbacks for missing glyphs. Nerd Font is needed for icons in eza, Starship, zellij — install from https://www.nerdfonts.com/

## Useful commands

```bash
ghostty +list-fonts            # installed fonts Ghostty can see
ghostty +list-themes           # built-in themes
ghostty +show-config           # dump effective config (with defaults)
```
