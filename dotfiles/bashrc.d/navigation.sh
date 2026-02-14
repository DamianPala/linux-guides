# Shell options for directory navigation and globbing

# Correct minor cd typos
shopt -s cdspell

# Correct minor typos during tab completion
shopt -s dirspell

# Enable ** recursive globbing
shopt -s globstar

# Frequently used parent directories
CDPATH=".:~:~/Documents:~/Documents/ai_sandbox"
