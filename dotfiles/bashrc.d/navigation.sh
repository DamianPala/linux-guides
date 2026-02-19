# shellcheck shell=bash
# Shell options for directory navigation and globbing

# Correct minor cd typos
shopt -s cdspell

# Correct minor typos during tab completion
shopt -s dirspell

# Enable ** recursive globbing
shopt -s globstar

# Quick directory traversal
alias ..='cd ..'
alias ...='cd ../..'

# Frequently used parent directories
CDPATH=".:~:~/Documents:~/Documents/ai_sandbox"
