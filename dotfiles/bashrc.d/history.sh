# history.sh — Enhanced bash history

# Erase duplicates across entire history + ignore lines starting with space
HISTCONTROL=erasedups:ignorespace

# Large history
HISTSIZE=500000
HISTFILESIZE=500000

# Skip trivial commands from history
HISTIGNORE='ls:ll:la:l:cd:pwd:exit:clear:history:bg:fg'

# Timestamp each history entry
HISTTIMEFORMAT='%F %T  '

# Save multi-line commands as a single entry
shopt -s cmdhist

# Append to history file, don't overwrite
shopt -s histappend

# Edit recalled history commands before executing
shopt -s histverify

# Flush each command to history file immediately (survive crashes)
# Called by zzz-starship.sh precmd hook (after $? is captured)
__history_flush() {
  history -a
}
