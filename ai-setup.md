# Claude Code and Codex Setup

## Install

```bash
sudo npm install -g @anthropic-ai/claude-code@latest
sudo npm install -g @openai/codex@latest
sudo npm install -g ccusage
```

### Claude Powerline

Statusline showing context usage, cost, and model info. Requires Nerd Font for icons.

```bash
cat > ~/.claude/settings.json << 'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "npx -y @owloops/claude-powerline@latest"
  }
}
EOF

cat > ~/.claude/claude-powerline.json << 'EOF'
{
  "theme": "rose-pine",
  "display": {
    "style": "powerline",
    "charset": "unicode",
    "padding": 1,
    "lines": [
      {
        "segments": {
          "directory": { "enabled": true, "style": "basename" },
          "model": { "enabled": true },
          "session": { "enabled": true, "type": "breakdown", "costSource": "calculated" },
          "block": { "enabled": true, "type": "time" },
          "context": { "enabled": true, "showPercentageOnly": false },
          "git": { "enabled": true, "showWorkingTree": true }
        }
      }
    ]
  }
}
EOF
```

---

## Shell Setup

Useful aliases and functions for working with Claude Code CLI.

### Functions

```bash
cat >> ~/.bashrc << 'EOF'
# ============================================
# Claude Code aliases and functions
# ============================================
claude-continue() { claude -c "$@"; }
claude-resume() { claude -r "$@"; }
claude-deep() { MAX_THINKING_TOKENS=31999 claude --model opus "$@"; }
claude-temp() { (cd ~/temp && claude "$@"); }
claude-quick() { (cd ~/temp && claude --model haiku "$@"); }

# Short aliases
alias clc='claude-continue'
alias clr='claude-resume'
alias cld='claude-deep'
alias clt='claude-temp'
alias clq='claude-quick'
EOF
```

After adding, reload your shell:

```bash
source ~/.bashrc  # Linux
source ~/.zshrc   # Mac
```

### Custom /deep Command

```bash
mkdir -p ~/.claude/skills/deep && cat > ~/.claude/skills/deep/SKILL.md << 'EOF'
---
name: deep
description: Deep analysis with extended thinking and Opus model
model: opus
---

Analyze this with deep, methodical reasoning. Take your time to think through the problem thoroughly.

$ARGUMENTS

Requirements:
- Think step by step through the entire problem
- Consider multiple approaches and perspectives
- Identify edge cases and potential issues
- Provide detailed, well-structured analysis
- Include specific examples where relevant
EOF
```

Use inside any Claude session: `/deep explain the architecture of this codebase`

### Windows PowerShell

```powershell
@'
function claude-deep { $env:MAX_THINKING_TOKENS = "31999"; claude --model opus @args }
function claude-temp { Push-Location "$HOME\temp"; claude @args; Pop-Location }
function claude-quick { Push-Location "$HOME\temp"; claude --model haiku @args; Pop-Location }
Set-Alias -Name cld -Value claude-deep
Set-Alias -Name clt -Value claude-temp
Set-Alias -Name clq -Value claude-quick
'@ | Add-Content $PROFILE
. $PROFILE
```

### Tips

- `MAX_THINKING_TOKENS=31999` is just below the 32k threshold where batch processing is recommended
- Temp folder sessions keep your main project history clean
- Use `/deep` inside sessions for on-demand deep thinking without restarting
