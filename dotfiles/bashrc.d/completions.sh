# shellcheck shell=bash disable=SC1090,SC1091
# completions.sh — dynamic tab-completion for CLI tools without system completions

command -v bat &>/dev/null && eval "$(bat --completion bash)"
# fd: Ubuntu package fd-find ships binary as 'fdfind'
if command -v fd &>/dev/null; then
    eval "$(fd --gen-completions bash)"
elif command -v fdfind &>/dev/null; then
    eval "$(fdfind --gen-completions bash)"
fi
command -v rg &>/dev/null && eval "$(rg --generate complete-bash)"
[[ -f ~/.hatch-complete.bash ]] && . ~/.hatch-complete.bash

# fzf: keybindings (Ctrl+T, Alt+C, and Ctrl+R when Atuin is not installed) + completion
# fzf --bash requires 0.48+; Ubuntu 24.04 ships 0.44
if command -v fzf &>/dev/null; then
    _fzf_init="$(fzf --bash 2>/dev/null)"
    if [[ -n "$_fzf_init" ]]; then
        eval "$_fzf_init"
    elif [[ -f /usr/share/doc/fzf/examples/key-bindings.bash ]]; then
        source /usr/share/doc/fzf/examples/key-bindings.bash
    fi
    unset _fzf_init
    # Atuin owns Ctrl+R when installed — unbind fzf's version
    command -v atuin &>/dev/null && bind -r '"\C-r"' 2>/dev/null
fi
