# zellij.sh — Auto-rename Zellij tab to current directory name
# Called by zzz-starship.sh precmd hook (after $? is captured)

__zellij_tab_name_update() {
  [[ -n $ZELLIJ ]] || return 0
  local dir=${PWD/#$HOME/\~}
  dir=${dir##*/}
  [[ $dir == "~" ]] && dir="home"
  zellij action rename-tab "$dir" >/dev/null 2>&1 &
  disown
}
