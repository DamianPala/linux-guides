# zellij.sh — Auto-rename Zellij tab to current directory name

__zellij_tab_name_update() {
  local ret=$?
  [[ -n $ZELLIJ ]] || return $ret
  local dir=${PWD/#$HOME/\~}
  dir=${dir##*/}
  [[ $dir == "~" ]] && dir="home"
  zellij action rename-tab "$dir" >/dev/null 2>&1 &
  disown
  return $ret
}

if [[ -z "${_zellij_loaded-}" ]]; then
  _zellij_loaded=1
  PROMPT_COMMAND="__zellij_tab_name_update${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
