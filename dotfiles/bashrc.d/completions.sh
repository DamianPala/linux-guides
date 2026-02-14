# completions.sh — dynamic tab-completion for CLI tools without system completions

command -v bat &>/dev/null && eval "$(bat --completion bash)"
command -v fd  &>/dev/null && eval "$(fd --gen-completions bash)"
command -v rg  &>/dev/null && eval "$(rg --generate complete-bash)"

# fzf: keybindings (Ctrl+R, Ctrl+T, Alt+C) + completion
command -v fzf &>/dev/null && eval "$(fzf --bash)"
