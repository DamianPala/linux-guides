# Install Zellij on Ubuntu

Zellij is a fast, modern terminal workspace that feels like tmux with batteries included. This guide gets it installed cleanly on Ubuntu 24.04 for x86_64. If you already have Rust, there is a one-command alternative near the end.

## My own requirements

1. Scrollback like in normal terminal.
    1. Scroll using mouse wheel.
    1. Copy on select.
    1. Long buffer.
    1. Clickable links - `Ctrl+Shift+Click` in Zellij.
    1. Working search on scrollback. In Zellij we can use `vi` for this.
    1. Selection with scrolling - currently not workin in Zellij.
1. Tabs
    1. Tab movements.
    1. Descriptive default names.
1. Custom session names.
1. New line when pressed `Shift + Enter` or `Alt + Enter`. The latter works in Zellij.

## Prerequisites
- `curl` and `tar` installed (we'll install them below if needed)

## Step-by-step (recommended: prebuilt binary)

3) **Download the latest Linux x86_64 tarball**

Run:
```bash
cd ~/Downloads
curl -fL -O https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz
```
4) **Extract and install into your PATH**

Run:
```bash
tar -xvf zellij*-x86_64-unknown-linux-musl.tar.gz
chmod +x zellij
sudo install -m 0755 zellij /usr/local/bin/
```

Verification:
```bash
zellij --version
```

## Alternative: install with Cargo (if you already have Rust)

If you already use Rust and Cargo, you can compile/install directly:
```bash
cargo install --locked zellij
```

Verification:
```bash
zellij --version
```

## Configuration

Run zellij at least once to generate default config.

### Completions

```bash
mkdir -p ~/.local/share/bash-completion/completions
zellij setup --generate-completion bash > ~/.local/share/bash-completion/completions/zellij
```

### Keybindings

Using Ctrl+PageUp/Down you switch in terminal tabs, using Alt+Ctrl+PageUp/Down you switch zellij tabs. Similarly with creating and closing tabs.

Modify section `shared_except "locked"` in the config to have it like this:

```bash
bind "Alt i" "Alt Ctrl Shift PageUp" { MoveTab "Left"; }
bind "Alt o" "Alt Ctrl Shift PageDown" { MoveTab "Right"; }
bind "Alt Left" "Alt Ctrl PageUp" { MoveFocusOrTab "Left"; }
bind "Alt Right" "Alt Ctrl PageDown" { MoveFocusOrTab "Right"; }
bind "Alt Ctrl Shift t" { NewTab; }
bind "Alt Ctrl Shift w" { CloseTab; }
```

### Batch config updates

This script updates a list of options in one go. It replaces both commented and
uncommented lines, and appends missing keys at the end.

```bash
CONFIG="$HOME/.config/zellij/config.kdl"

set_kdl_option() {
  local key="$1"
  local value="$2"

  if grep -Eq "^[[:space:]]*(//[[:space:]]*)?$key\\b" "$CONFIG"; then
    sed -i -E "s|^[[:space:]]*(//[[:space:]]*)?$key\\b.*|$key $value|" "$CONFIG"
  else
    echo "$key $value" >> "$CONFIG"
  fi
}

while read -r key value; do
  set_kdl_option "$key" "$value"
done << 'EOF'
scroll_buffer_size 100000
pane_frames true
attach_to_session true
session_serialization true
serialize_pane_viewport true
scrollback_lines_to_serialize 100000
serialization_interval 60
pane_frames false
theme "ao"
EOF
```

### Directory Tab Names

Copy following code to your `.bashrc`

```bash
__zellij_tab_name_update() {
  [[ -n $ZELLIJ ]] || return
  local dir=${PWD/#$HOME/\~}
  dir=${dir##*/}
  [[ $dir == "~" ]] && dir="home"
  zellij action rename-tab "$dir" >/dev/null 2>&1 &
  disown
}
PROMPT_COMMAND="__zellij_tab_name_update${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

## References
- Zellij User Guide: Installation
- Zellij User Guide: Configuration
- Zellij GitHub Releases
