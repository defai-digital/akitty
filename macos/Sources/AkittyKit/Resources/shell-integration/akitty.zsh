# Opt-in metadata only. Programs can spoof these notifications; never authorize from them.
[[ -o interactive && -z ${__akitty_installed-} ]] || return
__akitty_installed=1
function __akitty_precmd() {
    local code=$?
    [[ -z ${__akitty_running-} ]] || printf '\e]133;D;%d\a' "$code"
    __akitty_running=
    local path=${PWD//\%/%25}
    path=${path// /%20}; path=${path//$'\n'/%0A}; path=${path//$'\r'/%0D}
    path=${path//\#/%23}; path=${path//\?/%3F}; path=${path//$'\e'/%1B}; path=${path//$'\a'/%07}
    printf '\e]7;file://localhost%s\a\e]133;A\a' "$path"
    # The tab names where the shell is, as Ghostty's title feature does: the last three directories, since the tab
    # keeps the end of a long title. AKITTY_SHELL_TITLE=0 leaves the title to the user's own hooks.
    [[ ${AKITTY_SHELL_TITLE-} == 0 ]] || printf '\e]2;%s\a' "${${(%):-%(4~|…/%3~|%~)}//[[:cntrl:]]/}"
}
function __akitty_preexec() {
    local command=$1
    command=${command//$'\n'/ }; command=${command//$'\r'/ }
    printf '\e]772;%s\a\e]133;C\a' "$(printf %s "$command" | /usr/bin/base64 | /usr/bin/tr -d '\r\n')"
    # While a command runs the tab names it, control characters removed so the title cannot end or escape early.
    [[ ${AKITTY_SHELL_TITLE-} == 0 ]] || printf '\e]2;%s\a' "${command//[[:cntrl:]]/}"
    __akitty_running=1
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd __akitty_precmd
add-zsh-hook preexec __akitty_preexec
# B is part of the prompt, not printed ahead of user/framework prompt hooks.
setopt prompt_percent
PS1="${PS1}"$'%{\e]133;B\a%}'
