# ai.sh — AI coding assistant shortcuts (Claude Code, Codex)

# --- Claude Code ---
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

# --- Codex (OpenAI) ---
__codex_sandboxed() (
  local profile="$1"; shift
  local codex_home="$HOME/.codex-temp"
  mkdir -p "$codex_home"
  [[ -f "$HOME/.codex/auth.json" ]] && ln -sf "$HOME/.codex/auth.json" "$codex_home/auth.json"
  [[ -f "$HOME/.codex/config.toml" ]] && ln -sf "$HOME/.codex/config.toml" "$codex_home/config.toml"
  CODEX_HOME="$codex_home" codex --profile "$profile" "$@"
)

codex-temp() { __codex_sandboxed temp "$@"; }
codex-quick() { __codex_sandboxed quick "$@"; }

alias cxt='codex-temp'
alias cxq='codex-quick'
