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

# grep colors
alias grep='grep --color=auto'
alias fgrep='grep -F --color=auto'
alias egrep='grep -E --color=auto'

# colored GCC warnings and errors
export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# Desktop notification for long-running commands: sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# Fix TERM for SSH (remote hosts lack ghostty terminfo)
function ssh { TERM=xterm-256color command ssh "$@"; }
export -f ssh

# Reload bashrc
alias refresh='source ~/.bashrc'
