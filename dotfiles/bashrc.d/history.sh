# shellcheck shell=bash
# history.sh — Enhanced bash history

# Erase duplicates across entire history + ignore lines starting with space
HISTCONTROL=erasedups:ignorespace

# Large history
HISTSIZE=500000
HISTFILESIZE=500000

# Skip trivial commands from history
HISTIGNORE='cd:pwd:exit:clear:history:bg:fg'

# Timestamp each history entry
HISTTIMEFORMAT='%F %T  '

# Save multi-line commands as a single entry
shopt -s cmdhist

# Append to history file, don't overwrite
shopt -s histappend

# Edit recalled history commands before executing
shopt -s histverify

# Flush each command to history file immediately (survive crashes)
# Called by zzz-starship.sh precmd hook (after $? is captured)
__history_flush() {
    history -a
}

# Atuin (optional) — must init before Starship (alphabetical order handles this)
[[ -f "$HOME/.atuin/bin/env" ]] && . "$HOME/.atuin/bin/env"
if command -v atuin &>/dev/null; then
    [[ -f ~/.bash-preexec.sh ]] && source ~/.bash-preexec.sh
    eval "$(atuin init bash)"
    # Workaround: bash-preexec may not fire preexec for the first command in a
    # new terminal (Ghostty + bash 5.2). Detect and record it on the next precmd.
    # Skip the first invocation (__bp_install's manual precmd before any user input).
    __atuin_first_cmd_fix() {
        if [[ -z "${__atuin_fix_ready-}" ]]; then
            __atuin_fix_ready=1
            return
        fi
        precmd_functions=("${precmd_functions[@]/__atuin_first_cmd_fix}")
        [[ -n "$ATUIN_HISTORY_ID" ]] && return
        local cmd
        cmd=$(HISTTIMEFORMAT='' builtin history 1)
        cmd="${cmd#*[[:digit:]][* ] }"
        [[ -z "$cmd" ]] && return
        local id
        id=$(atuin history start -- "$cmd" 2>/dev/null)
        [[ -n "$id" ]] && (ATUIN_LOG=error atuin history end \
            --exit "${__bp_last_ret_value:-0}" -- "$id" &) >/dev/null 2>&1
    }
    precmd_functions=(__atuin_first_cmd_fix "${precmd_functions[@]}")
fi
