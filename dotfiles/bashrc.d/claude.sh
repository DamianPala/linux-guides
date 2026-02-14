# Claude Code workflow functions and short aliases

claude-continue() { claude -c "$@"; }
claude-resume() { claude -r "$@"; }
claude-deep() { MAX_THINKING_TOKENS=31999 claude --model opus "$@"; }
claude-temp() { (cd ~/Documents/ai_sandbox/temp && claude "$@"); }
claude-quick() { (cd ~/Documents/ai_sandbox/temp && claude --model sonnet "$@"); }

alias clc='claude-continue'
alias clr='claude-resume'
alias cld='claude-deep'
alias clt='claude-temp'
alias clq='claude-quick'
