# shellcheck shell=bash disable=SC1003
# Aliases and tool overrides

# eza (ls replacement)
if command -v eza &>/dev/null; then
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
else
    alias ll='ls -alF'
    alias la='ls -A'
    alias l='ls -CF'
fi

# bat (cat replacement)
if command -v bat &>/dev/null; then
    alias cat='bat -pp'
fi

# nvim
if command -v nvim &>/dev/null; then
    alias vi='nvim'
fi

# fd: Ubuntu package fd-find ships binary as 'fdfind'
if ! command -v fd &>/dev/null && command -v fdfind &>/dev/null; then
    alias fd='fdfind'
fi

# human-readable output
alias df='df -h'
alias free='free -h'

# grep colors
alias grep='grep --color=auto'
alias fgrep='grep -F --color=auto'
alias egrep='grep -E --color=auto'

# colored GCC warnings and errors
export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# Desktop notification for long-running commands: sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# SSH wrapper: auto-install xterm-ghostty terminfo + terminal cleanup after
# broken disconnects. Ghostty ssh-env/ssh-terminfo must be DISABLED.
ssh() {
    local _term="xterm-256color"
    local _opts=(-o "SetEnv COLORTERM=truecolor")

    # --- Terminfo auto-install ---
    # Install xterm-ghostty terminfo on remote (once per host, cached).
    # Enables undercurl, colored underlines, kitty keyboard in remote nvim.
    if command -v infocmp &>/dev/null; then
        local _host _user _port
        while IFS=' ' read -r _k _v; do
            case "$_k" in
                hostname) _host="$_v" ;;
                user) _user="$_v" ;;
                port) _port="$_v" ;;
            esac
        done < <(command ssh -G "$@" 2>/dev/null)

        if [[ -n "$_host" ]]; then
            local _cache="$HOME/.cache/ssh-terminfo/${_user}@${_host}:${_port}"

            if [[ -f "$_cache" ]]; then
                _term="xterm-ghostty"
            else
                local _ti
                _ti=$(infocmp -0 -x xterm-ghostty 2>/dev/null)
                if [[ -n "$_ti" ]]; then
                    echo "Setting up xterm-ghostty terminfo on $_host..." >&2
                    if echo "$_ti" | command ssh "$@" \
                        'if ! infocmp xterm-ghostty &>/dev/null; then
                 command -v tic &>/dev/null || exit 1
                 mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null || exit 1
               fi
               if [ -f ~/.bashrc ] && grep -q xterm-color ~/.bashrc 2>/dev/null \
                    && ! grep -q xterm-ghostty ~/.bashrc 2>/dev/null; then
                 sed -i "/color_prompt/s/xterm-color/xterm-ghostty | xterm-color/" ~/.bashrc 2>/dev/null
               fi
               if [ -f ~/.bashrc ] && ! grep -q "COLORTERM=truecolor" ~/.bashrc 2>/dev/null; then
                 printf "\n[ \"\$TERM\" = \"xterm-ghostty\" ] && export COLORTERM=truecolor\n" >> ~/.bashrc
               fi' \
                        2>/dev/null; then
                        _term="xterm-ghostty"
                        mkdir -p "${_cache%/*}" 2>/dev/null
                        touch "$_cache"
                    fi
                fi
            fi
        fi
    fi

    # --- Connect ---
    TERM="$_term" command ssh "${_opts[@]}" "$@"
    local ret=$?

    # --- Broken disconnect cleanup ---
    if ((ret != 0)); then
        # Race: garbage bytes (kitty keyboard, mouse sequences) from the remote app
        # continue arriving after a single reset, re-enabling modes.
        # Fix: suppress echo → disable modes → drain in rounds → RIS last.
        printf '\x18\x1b\\'                 # CAN+ST: abort partial sequence
        stty -echo 2>/dev/null              # suppress garbage display
        printf '\x1b[=0;1u'                 # kitty kbd: flags=0
        printf '\x1b[<999u'                 # kitty kbd: pop stack
        printf '\x1b[?1000;1002;1003;1006l' # mouse tracking off
        printf '\x1b[?2004l'                # bracketed paste off
        printf '\x1b[?1049l'                # leave alternate screen
        python3 -c "import termios,sys;termios.tcflush(sys.stdin.fileno(),termios.TCIFLUSH)" 2>/dev/null
        sleep 0.3
        python3 -c "import termios,sys;termios.tcflush(sys.stdin.fileno(),termios.TCIFLUSH)" 2>/dev/null
        printf '\x1bc' # RIS: full terminal reset
        sleep 0.1
        python3 -c "import termios,sys;termios.tcflush(sys.stdin.fileno(),termios.TCIFLUSH)" 2>/dev/null
        stty sane 2>/dev/null
    fi
    return $ret
}
export -f ssh

# Open files/URLs in GUI apps (macOS-style)
# open file         → default app (xdg-open)
# open file1 file2  → default app for each
# open typora file  → auto-detect: typora is in PATH and not a file → use as app
# open -a app file  → explicit app (always unambiguous)
# open              → file manager in cwd
open() {
    if (( $# == 0 )); then
        xdg-open . &>/dev/null & disown
        return
    fi

    local app=""
    if [[ "$1" == "-a" ]]; then
        app="$2"; shift 2
    elif (( $# > 1 )) && command -v "$1" &>/dev/null && [[ ! -e "$1" ]]; then
        app="$1"; shift
    fi

    if [[ -n "$app" ]]; then
        "$app" "$@" &>/dev/null & disown
    else
        local f
        for f in "$@"; do
            xdg-open "$f" &>/dev/null & disown
        done
    fi
}

# Expand aliases after sudo (trailing space triggers alias expansion on next word)
alias sudo='sudo '

# Reload bashrc
alias refresh='source ~/.bashrc'
