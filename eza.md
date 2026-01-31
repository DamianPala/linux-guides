# Install eza on Ubuntu

`eza` is a modern replacement for `ls` with better defaults, Git status, and optional icons. This guide targets Ubuntu 24.04 on x86_64.

## Requirements

- Optional: a Nerd Font if you want icons

## Install from apt

```bash
sudo apt update
sudo apt install -y eza
```

## Install with Cargo (latest version)

If you already use Rust and Cargo, install eza from crates.io:

```bash
cargo install eza
```

## Verification

```bash
eza --version
```

You should see the eza version printed.

## Configuration

### Aliases

Add aliases to your `~/.bashrc`:

```bash
alias ls='eza --icons=auto --group-directories-first --classify=auto --color=auto'
alias l='ls'
alias ll='ls -l'
alias la='ll -a'
alias lla='ll -a'

alias lt='ls -Tl --level=2'
alias lta='ls -Tal --level=3'
alias lg='ls -l --git'
alias lsd='ls -Dl'
alias lsf='ls -fl'
alias lS='ls -l --sort=size'
alias lM='ls -l --sort=modified'
```

Reload your shell:

```bash
source ~/.bashrc
```

> If you don't have Nerd Fonts installed remove `--icons=auto` from `ls` alias.

### Theme

To use my custom theme file [eza-theme.yml](eza-theme.yml) run:

```bash
mkdir -p ~/.config/eza
cp /path/to/linux-guides/eza-theme.yml ~/.config/eza/theme.yml
```

## Notes

- `--git` can be slow in very large repos; drop it in those directories.
- Icons require a Nerd Font in your terminal.

## References

- eza docs: https://eza.rocks/
