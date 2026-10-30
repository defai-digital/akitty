# Supports interactive bash 3.2+. Does not replace an existing DEBUG trap.
[[ $- == *i* && -z ${__akitty_installed-} ]] || return
if [[ -n $(trap -p DEBUG) ]]; then
    printf '%s\n' 'AkiTTY shell integration unavailable: an existing DEBUG trap owns command hooks.' >&2
    return
fi
__akitty_installed=1
__akitty_previous_prompts=("${PROMPT_COMMAND[@]}")
__akitty_previous_history=
unset PROMPT_COMMAND
__akitty_ready=
__akitty_running=
__akitty_preexec() {
    [[ -n $__akitty_ready ]] || return 0
    case "$BASH_COMMAND" in __akitty_*) return 0 ;; esac
    __akitty_ready=
    local command=$BASH_COMMAND line
    line=$(HISTTIMEFORMAT= builtin history 1)
    if [[ $line =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ && ${BASH_REMATCH[1]} != "$__akitty_previous_history" ]]; then
        command=${BASH_REMATCH[2]}
    fi
    command=${command//$'\n'/ }; command=${command//$'\r'/ }
    printf '\e]772;%s\a\e]133;C\a' "$(printf %s "$command" | /usr/bin/base64 | /usr/bin/tr -d '\r\n')"
    __akitty_running=1
}
__akitty_restore_status() { return "$1"; }
__akitty_precmd() {
    local code=$?
    __akitty_ready=
    [[ -z $__akitty_running ]] || printf '\e]133;D;%d\a' "$code"
    __akitty_running=
    local hook line
    for hook in "${__akitty_previous_prompts[@]}"; do
        [[ -z $hook ]] || { __akitty_restore_status "$code"; eval "$hook"; }
    done
    local path=${PWD//\%/%25}
    path=${path// /%20}; path=${path//$'\n'/%0A}; path=${path//$'\r'/%0D}
    path=${path//\#/%23}; path=${path//\?/%3F}; path=${path//$'\e'/%1B}; path=${path//$'\a'/%07}
    printf '\e]7;file://localhost%s\a\e]133;A\a' "$path"
    line=$(HISTTIMEFORMAT= builtin history 1)
    __akitty_previous_history=
    if [[ $line =~ ^[[:space:]]*([0-9]+)[[:space:]] ]]; then __akitty_previous_history=${BASH_REMATCH[1]}; fi
    __akitty_ready=1
}
PROMPT_COMMAND=__akitty_precmd
PS1="${PS1}"'\[\e]133;B\a\]'
trap '__akitty_preexec' DEBUG
