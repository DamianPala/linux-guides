# shellcheck shell=bash disable=SC2034
# starship.sh — Starship prompt + precmd hooks (must load last)
#
# Centralizes all precmd hooks via starship_precmd_user_func.
# Modules (history.sh, zellij.sh, etc.) only define functions;
# this file wires them into the prompt lifecycle.

# Aggregate precmd hook — called after each command
# With Starship: runs via starship_precmd_user_func (after $? is captured)
# Without Starship: runs via PROMPT_COMMAND wrapper (preserving $?)
__precmd_user_hook() {
    declare -F __history_flush &>/dev/null && __history_flush
    declare -F __zellij_tab_name_update &>/dev/null && __zellij_tab_name_update
}

if [[ -z "${_precmd_loaded-}" ]]; then
    _precmd_loaded=1
    if command -v starship &>/dev/null; then
        starship_precmd_user_func="__precmd_user_hook"
        eval "$(starship init bash)"
        # Workaround: Ghostty's preexec on bash <5.3 runs in a subshell
        # ($(...) in PS0), so _ghostty_executing=1 is lost. Starship then
        # overwrites PS1, and __ghostty_precmd never re-adds OSC 133 markers.
        # Force the flag so markers (and click-to-position) work every prompt.
        if [[ -n "${GHOSTTY_RESOURCES_DIR-}" ]]; then
            PROMPT_COMMAND="_ghostty_executing=1;${PROMPT_COMMAND}"
        fi
    else
        # Fallback without Starship: preserve $? for downstream PS1
        __precmd_fallback() {
            local ret=$?
            __precmd_user_hook
            return $ret
        }
        PROMPT_COMMAND="__precmd_fallback${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    fi
fi
