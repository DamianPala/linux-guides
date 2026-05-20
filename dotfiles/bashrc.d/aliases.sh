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
_ssh_has_remote_command() {
    local _arg _dest_seen=0 _skip_next=0 _stop_options=0

    for _arg in "$@"; do
        if ((_skip_next)); then
            _skip_next=0
            continue
        fi

        if ((_dest_seen)); then
            return 0
        fi

        if ((_stop_options == 0)); then
            case "$_arg" in
                --)
                    _stop_options=1
                    continue
                    ;;
                -[BbcDEeFIiJLlmOoPpQRSWw])
                    _skip_next=1
                    continue
                    ;;
                -[BbcDEeFIiJLlmOoPpQRSWw]?* | -*)
                    continue
                    ;;
            esac
        fi

        _dest_seen=1
    done

    return 1
}

_ssh_local_only_or_tunnel() {
    local _arg

    for _arg in "$@"; do
        case "$_arg" in
            -G | -G* | -Q | -Q* | -V | -N | -f | -W | -W* | -L | -L* | -R | -R* | -D | -D*)
                return 0
                ;;
        esac
    done

    return 1
}

_ssh_probe_remote_terminfo_tools() {
    # shellcheck disable=SC2016 # Expanded by the remote shell, not locally.
    local _probe='command -v infocmp >/dev/null 2>&1 \
&& command -v tic >/dev/null 2>&1 \
&& command -v base64 >/dev/null 2>&1 \
&& { [ -n "${SHELL:-}" ] || command -v sh >/dev/null 2>&1; }'

    TERM=xterm-256color command ssh \
        -o "SetEnv COLORTERM=truecolor" \
        -o BatchMode=yes \
        -o ConnectTimeout="${SSH_TERMINFO_PROBE_TIMEOUT:-5}" \
        "$@" "$_probe" </dev/null >/dev/null 2>&1
}

_ssh_terminfo_hint() {
    local _user="$1" _host="$2"
    local _hint_cache="$HOME/.cache/ssh-terminfo/inconclusive/${_user}@${_host}:${3:-22}"

    [[ -t 2 && ! -f "$_hint_cache" ]] || return 0
    mkdir -p "${_hint_cache%/*}" 2>/dev/null
    touch "$_hint_cache" 2>/dev/null
    printf 'Ghostty terminfo auto-install skipped: probe could not authenticate/check host.\n' >&2
    printf 'Run once to force install:\n' >&2
    printf '  SSH_TERMINFO_FORCE=1 ssh %s@%s\n' "$_user" "$_host" >&2
}

ssh() {
    local _term="xterm-256color"
    local _opts=(-o "SetEnv COLORTERM=truecolor")
    local _remote_cmd=()

    # --- Terminfo auto-install ---
    # Install xterm-ghostty terminfo on remote (once per host, cached).
    # Enables undercurl, colored underlines, kitty keyboard in remote nvim.
    if [[ -z "${SSH_NO_TERMINFO:-}" ]] \
        && [[ "$TERM" == "xterm-ghostty" ]] \
        && command -v infocmp &>/dev/null \
        && ! _ssh_local_only_or_tunnel "$@" \
        && ! _ssh_has_remote_command "$@"; then
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
            local _unsupported_cache="$HOME/.cache/ssh-terminfo/unsupported/${_user}@${_host}:${_port}"

            if [[ -f "$_cache" && -z "${SSH_TERMINFO_FORCE:-}" ]]; then
                _term="xterm-ghostty"
            elif [[ -n "${SSH_TERMINFO_FORCE:-}" ]] \
                || [[ ! -f "$_unsupported_cache" || -n "${SSH_TERMINFO_RECHECK:-}" ]]; then
                local _probe_ret=0
                if [[ -z "${SSH_TERMINFO_FORCE:-}" ]]; then
                    _ssh_probe_remote_terminfo_tools "$@"
                    _probe_ret=$?
                fi
                if ((_probe_ret == 0)); then
                    local _ti_b64
                    _ti_b64=$(infocmp -0 -x xterm-ghostty 2>/dev/null | base64 -w0)
                    if [[ -n "$_ti_b64" ]]; then
                        _term="xterm-ghostty"
                        # Inline install: embed terminfo as base64 in the remote
                        # command, then exec login shell. One connection, one
                        # password, MOTD preserved. Only on first connect per host.
                        _opts+=(-t)
                        _remote_cmd=("$(command cat <<REMOTE
if ! infocmp xterm-ghostty >/dev/null 2>&1; then
    if command -v tic >/dev/null 2>&1; then
        if echo '${_ti_b64}' | base64 -d | tic -x - 2>/dev/null; then
            if command -v sudo >/dev/null 2>&1 \
                 && ! echo '${_ti_b64}' | base64 -d | sudo -n tic -x -o /usr/share/terminfo - 2>/dev/null; then
                printf '\n  \033[33m⚠ terminfo installed for your user only. Run this to fix sudo:\033[0m\n'
                printf '  sudo cp ~/.terminfo/x/xterm-ghostty /usr/share/terminfo/x/\n\n'
            fi
        else
            printf '\n  \033[33m⚠ Could not install terminfo (read-only filesystem?).\033[0m\n'
            printf '  \033[33mFrom your local machine, run:\033[0m\n'
            printf '  infocmp -0 -x xterm-ghostty | command ssh %s \"mkdir -p ~/.terminfo && tic -x -\"\n\n' "\$(whoami)@\$(hostname)"
        fi
    fi
fi
if [ -f ~/.bashrc ] && grep -q xterm-color ~/.bashrc 2>/dev/null \
     && ! grep -q xterm-ghostty ~/.bashrc 2>/dev/null; then
    sed -i '/color_prompt/s/xterm-color/xterm-ghostty | xterm-color/' ~/.bashrc 2>/dev/null
fi
if [ -f ~/.bashrc ] && ! grep -q 'COLORTERM=truecolor' ~/.bashrc 2>/dev/null; then
    printf '\n[ "\$TERM" = "xterm-ghostty" ] && export COLORTERM=truecolor\n' >> ~/.bashrc
fi
cat /run/motd.dynamic 2>/dev/null || cat /etc/motd 2>/dev/null
# Fall back if terminfo didn't install (e.g. no tic on Synology)
if ! infocmp xterm-ghostty >/dev/null 2>&1; then
    export TERM=xterm-256color
fi
if [ -n "\${SHELL:-}" ]; then
    exec "\$SHELL" -l
fi
exec sh -l
REMOTE
)")
                        local _need_cache=1
                    fi
                elif ((_probe_ret == 255)); then
                    _ssh_terminfo_hint "$_user" "$_host" "$_port"
                elif ((_probe_ret != 255)); then
                    mkdir -p "${_unsupported_cache%/*}" 2>/dev/null
                    touch "$_unsupported_cache" 2>/dev/null
                fi
            fi
        fi
    fi

    # --- Connect ---
    local _start=$SECONDS
    local ret _elapsed

    if [[ "${_need_cache:-}" == 1 ]]; then
        # First attempt with terminfo blob. Capture stderr to detect Windows
        # hosts that reject the long remote command ("exec request failed").
        # Password prompts use /dev/tty, not stderr, so redirect is safe.
        local _stderr_file
        _stderr_file="$(mktemp)"
        TERM="$_term" command ssh "${_opts[@]}" "$@" "${_remote_cmd[@]}" 2>"$_stderr_file"
        ret=$?
        _elapsed=$(( SECONDS - _start ))

        if ((ret != 0)) && grep -q "exec request failed" "$_stderr_file" 2>/dev/null; then
            rm -f "$_stderr_file"
            mkdir -p "${_cache%/*}" 2>/dev/null
            touch "$_cache"
            # Retry without blob or -t flag
            _start=$SECONDS
            TERM="xterm-256color" command ssh -o "SetEnv COLORTERM=truecolor" "$@"
            ret=$?
            _elapsed=$(( SECONDS - _start ))
        else
            command cat "$_stderr_file" >&2
            rm -f "$_stderr_file"
            if ((ret == 0)); then
                mkdir -p "${_cache%/*}" 2>/dev/null
                touch "$_cache"
            fi
        fi
    else
        TERM="$_term" command ssh "${_opts[@]}" "$@"
        ret=$?
        _elapsed=$(( SECONDS - _start ))
    fi

    # --- Broken disconnect cleanup ---
    # ret=255 is SSH connection error (broken pipe, timeout). Codes 1-254 come from
    # the remote command and don't indicate a broken terminal. _elapsed>3 skips
    # quick failures (connection refused, auth fail).
    if ((ret == 255 && _elapsed > 3)); then
        # Race: garbage bytes (kitty keyboard, mouse sequences) from the remote app
        # continue arriving after disconnect, re-enabling modes.
        # Fix: suppress echo → disable modes → drain in rounds → stty sane.
        printf '\x18\x1b\\'                 # CAN+ST: abort partial sequence
        stty -echo 2>/dev/null              # suppress garbage display
        printf '\x1b[=0;1u'                 # kitty kbd: flags=0
        printf '\x1b[<999u'                 # kitty kbd: pop stack
        printf '\x1b[?1000;1002;1003;1006l' # mouse tracking off
        printf '\x1b[?2004l'                # bracketed paste off
        printf '\x1b[?1049l'                # leave alternate screen
        printf '\x1b[?25h'                  # cursor visible
        python3 -c "import termios,sys;termios.tcflush(sys.stdin.fileno(),termios.TCIFLUSH)" 2>/dev/null
        sleep 0.3
        python3 -c "import termios,sys;termios.tcflush(sys.stdin.fileno(),termios.TCIFLUSH)" 2>/dev/null
        sleep 0.1
        python3 -c "import termios,sys;termios.tcflush(sys.stdin.fileno(),termios.TCIFLUSH)" 2>/dev/null
        stty sane 2>/dev/null
    fi
    return $ret
}
export -f _ssh_has_remote_command _ssh_local_only_or_tunnel _ssh_probe_remote_terminfo_tools _ssh_terminfo_hint ssh

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

# VS Code
alias code='ELECTRON_OZONE_PLATFORM_HINT=wayland command code'
