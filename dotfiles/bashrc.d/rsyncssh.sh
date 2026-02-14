# rsyncssh.sh — rsync over SSH with global progress + resumable transfers

# Wrapper options:
#   :2222              -> set SSH port to 2222 (shorthand)
#   --port 2222        -> set SSH port to 2222
# Everything else is passed through to rsync (e.g. -HAX, -z, --delete, etc.)
rsyncssh() {
  local port=22
  local ssh_base_opts="-T -o Compression=no"
  local -a args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --port | --ssh-port)
      port="$2"
      if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "rsyncssh: invalid port: $port" >&2
        return 1
      fi
      shift 2
      ;;
    :[0-9]*)
      port="${1#:}"
      if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "rsyncssh: invalid port: $port" >&2
        return 1
      fi
      shift
      ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    *)
      args+=("$1")
      shift
      ;;
    esac
  done

  rsync -az --no-owner --no-group \
    --info=progress2 \
    --partial --partial-dir=.rsync-partial \
    --human-readable --stats \
    -e "ssh ${ssh_base_opts} -p ${port}" \
    "${args[@]}"
}

# --- bash completion (remote path completion like user@host:/path<TAB>) ---

# Ensure bash-completion is loaded
if ! declare -F _init_completion >/dev/null 2>&1; then
  if [[ -r /usr/share/bash-completion/bash_completion ]]; then
    . /usr/share/bash-completion/bash_completion
  elif [[ -r /etc/bash_completion ]]; then
    . /etc/bash_completion
  fi
fi

# Load rsync completion if not already available
if ! declare -F _rsync >/dev/null 2>&1; then
  if [[ -r /usr/share/bash-completion/completions/rsync ]]; then
    . /usr/share/bash-completion/completions/rsync
  fi
fi

# Wrapper completion: strip rsyncssh-specific args and delegate to _rsync
_rsyncssh_complete() {
  if ! declare -F _rsync >/dev/null 2>&1; then
    return 0
  fi

  local i
  local -a words=()
  local new_cword=$COMP_CWORD

  words+=(rsync)

  for ((i = 1; i < ${#COMP_WORDS[@]}; i++)); do
    case "${COMP_WORDS[i]}" in
    --port | --ssh-port)
      if ((i < COMP_CWORD)); then ((new_cword--)); fi
      ((i++))
      if ((i < COMP_CWORD)); then ((new_cword--)); fi
      continue
      ;;
    :[0-9]*)
      if ((i < COMP_CWORD)); then ((new_cword--)); fi
      continue
      ;;
    esac
    words+=("${COMP_WORDS[i]}")
  done

  local -a save_words=("${COMP_WORDS[@]}")
  local save_cword=$COMP_CWORD

  COMP_WORDS=("${words[@]}")
  COMP_CWORD=$new_cword

  _rsync

  COMP_WORDS=("${save_words[@]}")
  COMP_CWORD=$save_cword
}

complete -o bashdefault -o default -o nospace -F _rsyncssh_complete rsyncssh
