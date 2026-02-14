# starship.sh — Starship prompt (must load last to override __git_ps1 / bash-preexec)

if command -v starship &>/dev/null && [[ -z "${STARSHIP_SHELL-}" ]]; then
  eval "$(starship init bash)"
fi
