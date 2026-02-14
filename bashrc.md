# Modular Bashrc Setup

Organized bash configuration split into a clean base `~/.bashrc` and modular `~/.bashrc.d/*.sh` scripts. Each module handles one concern — aliases, history, navigation, etc. — and can be enabled/disabled by adding or removing the file.

---

## Structure

```
~/.bashrc              ← base: prompt with git, PATH, completion, module loader
~/.bashrc.d/
  aliases.sh           ← eza, bat, nvim, grep
  claude.sh            ← Claude Code shortcuts
  completions.sh       ← tab-completion for bat, fd, rg, fzf
  history.sh           ← large crash-safe history
  navigation.sh        ← cdspell, globstar, CDPATH
  readline.sh          ← smarter tab completion
  rsyncssh.sh          ← rsync-over-SSH wrapper
  zellij.sh            ← auto-rename tab to cwd
~/.inputrc             ← Ctrl+Up/Down history search
```

The base bashrc loads all `~/.bashrc.d/*.sh` files in alphabetical order at the end. To disable a module, prefix it with `_` (e.g. `aliases.sh` → `_aliases.sh`) or just remove the file.

---

## Install

From the repo root (`linux-guides/`):

```bash
cp dotfiles/bashrc ~/.bashrc
mkdir -p ~/.bashrc.d
cp dotfiles/bashrc.d/*.sh ~/.bashrc.d/
cp dotfiles/inputrc ~/.inputrc
chmod 700 ~/.bashrc.d
chmod 600 ~/.bashrc.d/*.sh
```

Then reload:

```bash
source ~/.bashrc
```

---

## Dependencies

The base bashrc works standalone. All modules are safe to load even if their tools aren't installed.

---

## Prompt

The prompt uses `__git_ps1` via `PROMPT_COMMAND` (not a static PS1) for color-coded git status:

- **Green** branch name = clean working directory
- **Red** branch name = uncommitted changes
- `*` = unstaged changes, `+` = staged changes
- `<` / `>` / `<>` = behind/ahead/diverged from upstream
- `%` = untracked files

Requires `git` and the `__git_ps1` function (shipped with `git` on Ubuntu via `/usr/lib/git-core/git-sh-prompt`).

---

## PROMPT_COMMAND chain

Three things append to `PROMPT_COMMAND`, and they compose safely regardless of load order:

1. **bashrc** — `__git_ps1 "prefix" "suffix"` (sets the prompt)
2. **history.sh** — `history -a` (flush history to disk after each command)
3. **zellij.sh** — `__zellij_tab_name_update` (rename tab to current dir)

Each uses the pattern `PROMPT_COMMAND="func${PROMPT_COMMAND:+;$PROMPT_COMMAND}"` to prepend without overwriting.

---

## Modules

### aliases.sh

| Alias | Command |
|-------|---------|
| `ls` | `eza --icons=auto --group-directories-first --classify=auto --color=auto` |
| `ll` | `ls -l` |
| `la` | `ll -a` |
| `lt` | `ls -Tl --level=2` (tree) |
| `lg` | `ls -l --git` (git status column) |
| `lS` | `ls -l --sort=size` |
| `lM` | `ls -l --sort=modified` |
| `cat` | `bat -pp` (plain, no pager) |
| `vi` | `nvim` |
| `refresh` | `source ~/.bashrc` |
| `alert` | Desktop notification after long command |

### claude.sh

| Function / Alias | What |
|-------------------|------|
| `claude-continue` / `clc` | Resume last conversation (`claude -c`) |
| `claude-resume` / `clr` | Pick conversation to resume (`claude -r`) |
| `claude-deep` / `cld` | Opus model with max thinking tokens |
| `claude-temp` / `clt` | New session in temp sandbox dir |
| `claude-quick` / `clq` | Sonnet model in temp sandbox dir |

### completions.sh

Dynamic tab-completion for CLI tools that don't ship system completions. Each entry is guarded with `command -v` — safe to load even if the tool isn't installed.

- `bat`, `fd`, `rg` — flag/path completion
- `fzf` — keybindings (**Ctrl+R** fuzzy history, **Ctrl+T** file picker, **Alt+C** cd into dir) + completion

Tools that already have system or user completions (delta, zellij) are skipped.

### history.sh

- `HISTSIZE=500000` — half a million entries in memory
- `HISTFILESIZE=100000` — 100k saved to disk
- `erasedups:ignoreboth` — removes all previous copies of a command, ignores space-prefixed and duplicates
- `HISTIGNORE` — skips trivial commands (`ls`, `cd`, `pwd`, etc.)
- `HISTTIMEFORMAT='%F %T  '` — timestamps in `history` output
- `histverify` — recalled commands go to the prompt for editing, not immediate execution
- `history -a` in PROMPT_COMMAND — flush after every command (no lost history on crash)

### navigation.sh

- `cdspell` — auto-correct minor typos in `cd` arguments
- `dirspell` — auto-correct typos during tab completion
- `globstar` — `**` matches recursively (e.g. `**/*.py`)
- `CDPATH` — `cd projects` works from anywhere if `~/Documents/ai_sandbox/projects` exists

### readline.sh

Applied via `bind` in the shell (complements `~/.inputrc`):

- Case-insensitive completion (`Makefile` matches `makef<TAB>`)
- Hyphens and underscores treated as equivalent
- Single Tab shows all matches immediately
- Tab cycles through matches (menu-complete)
- Shift+Tab cycles backward
- Completions color-coded by file type

### rsyncssh.sh

Rsync wrapper for SSH transfers with progress bar and resume support:

```bash
rsyncssh user@host:/remote/path /local/path
rsyncssh :2222 user@host:/path /local/path    # custom port
rsyncssh --port 2222 user@host:/path /local/   # alternative
```

Includes full bash tab-completion (delegates to rsync's `_rsync` completer).

### inputrc

- **Ctrl+Up** / **Ctrl+Down** — search history by prefix (type `git` then Ctrl+Up cycles through git commands)
- Arrow key fixes for some terminals
