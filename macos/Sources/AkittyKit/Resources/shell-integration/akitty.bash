# Supports interactive bash 3.2+. Does not replace an existing DEBUG trap; joins bash-preexec when it is loaded first.
[[ $- == *i* && -z ${__akitty_installed-} ]] || return
__akitty_installed=1
__akitty_running=
__akitty_mark='\[\e]133;B\a\]'
# The app's default-on wrapper declines quietly so every new terminal is not prefixed with a warning.
__akitty_quiet_decline=${__akitty_quiet-}
__akitty_report_command() {
    local command=${1//$'\n'/ }; command=${command//$'\r'/ }
    printf '\e]772;%s\a\e]133;C\a' "$(printf %s "$command" | /usr/bin/base64 | /usr/bin/tr -d '\r\n')"
    __akitty_running=1
}
__akitty_report_prompt() {
    [[ -z $__akitty_running ]] || printf '\e]133;D;%d\a' "$1"
    __akitty_running=
    local path=${PWD//\%/%25}
    path=${path// /%20}; path=${path//$'\n'/%0A}; path=${path//$'\r'/%0D}
    path=${path//\#/%23}; path=${path//\?/%3F}; path=${path//$'\e'/%1B}; path=${path//$'\a'/%07}
    printf '\e]7;file://localhost%s\a\e]133;A\a' "$path"
}
PS1="${PS1}${__akitty_mark}"
if [[ -n ${bash_preexec_imported-}${__bp_imported-} ]]; then
    # bash-preexec owns the DEBUG trap and PROMPT_COMMAND (installing itself at the first prompt); use its hook arrays.
    __akitty_bp_preexec() { __akitty_report_command "$1"; }
    __akitty_bp_precmd() {
        local code=$? hook others=()
        __akitty_report_prompt "$code"
        # bash-preexec appends the user's precmd when it installs; stay last so prompt start follows hook output.
        for hook in "${precmd_functions[@]}"; do [[ $hook == __akitty_bp_precmd ]] || others+=("$hook"); done
        precmd_functions=("${others[@]}" __akitty_bp_precmd)
    }
    preexec_functions+=(__akitty_bp_preexec)
    precmd_functions+=(__akitty_bp_precmd)
    return
fi
__akitty_previous_prompts=("${PROMPT_COMMAND[@]}")
__akitty_previous_history=
__akitty_ready=
__akitty_preexec() {
    [[ -n $__akitty_ready ]] || return 0
    case "$BASH_COMMAND" in __akitty_*) return 0 ;; esac
    local command=$BASH_COMMAND line entered=
    line=$(HISTTIMEFORMAT= builtin history 1)
    if [[ $line =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ && ${BASH_REMATCH[1]} != "$__akitty_previous_history" ]]; then
        command=${BASH_REMATCH[2]}; entered=1
    fi
    # On a prompt where PROMPT_COMMAND changed, hooks added after ours may still run: only a new history entry counts.
    [[ $__akitty_ready == 1 || -n $entered ]] || return 0
    __akitty_ready=
    __akitty_report_command "$command"
}
__akitty_restore_status() { return "$1"; }
__akitty_run_previous_prompts() {
    local hook
    for hook in "${__akitty_previous_prompts[@]}"; do
        # Each hook sees the user's command status, as each element of Bash's prompt array does.
        [[ -z $hook ]] || { __akitty_restore_status "$1"; eval "$hook"; }
    done
}
# Moves hooks added to PROMPT_COMMAND since the last prompt (array elements, or text joined to ours with `;` or a
# newline) into the list this hook runs, keeping their order around ours, and restores PROMPT_COMMAND to our hook.
# Bash already runs them on this prompt, so they are adopted for the next one.
__akitty_adopt_prompts() {
    local hook before=() after=() found= head tail
    for hook in "${PROMPT_COMMAND[@]}"; do
        if [[ -z $found && $hook == *__akitty_precmd* ]]; then
            found=1; head=${hook%%__akitty_precmd*}; tail=${hook#*__akitty_precmd}
            while [[ $head == *[[:space:]\;] ]]; do head=${head%?}; done
            while [[ $tail == [[:space:]\;]* ]]; do tail=${tail#?}; done
            [[ -z $head ]] || before+=("$head")
            [[ -z $tail ]] || after+=("$tail")
        elif [[ -z $found ]]; then before+=("$hook")
        elif [[ -n $hook ]]; then after+=("$hook")
        fi
    done
    __akitty_previous_prompts=("${before[@]}" "${__akitty_previous_prompts[@]}" "${after[@]}")
    PROMPT_COMMAND=(__akitty_precmd)
}
__akitty_precmd() {
    local code=$? line ready=1
    __akitty_ready=
    [[ -z $__akitty_running ]] || printf '\e]133;D;%d\a' "$code"
    __akitty_running=
    __akitty_run_previous_prompts "$code"
    if [[ ${#PROMPT_COMMAND[@]} != 1 || $PROMPT_COMMAND != __akitty_precmd ]]; then __akitty_adopt_prompts; ready=entered; fi
    __akitty_report_prompt "$code"
    line=$(HISTTIMEFORMAT= builtin history 1)
    __akitty_previous_history=
    if [[ $line =~ ^[[:space:]]*([0-9]+)[[:space:]] ]]; then __akitty_previous_history=${BASH_REMATCH[1]}; fi
    __akitty_ready=$ready
}
# Bash hides an existing DEBUG trap from sourced files and functions and restores it when they return, so ownership
# is decided by top-level PROMPT_COMMAND code at the first prompt, where `trap -p` sees what is really installed.
__akitty_first_prompt() {
    local code=$__akitty_status
    unset __akitty_status
    if [[ $__akitty_owner == "trap -- '__akitty_preexec' DEBUG" ]]; then
        unset __akitty_owner
        PROMPT_COMMAND=(__akitty_precmd)
        __akitty_restore_status "$code"; __akitty_precmd
        return
    fi
    unset __akitty_owner
    PROMPT_COMMAND=("${__akitty_previous_prompts[@]}")
    [[ $PS1 != *"$__akitty_mark" ]] || PS1=${PS1%"$__akitty_mark"}
    [[ -n $__akitty_quiet_decline ]] || printf '%s\n' 'AkiTTY shell integration unavailable: an existing DEBUG trap owns command hooks.' >&2
    __akitty_run_previous_prompts "$code"
    return "$code"
}
# Assign whole arrays: a plain assignment replaces only element 0, and bash 5.1+ would still run the user's later
# elements after our hook marked the prompt ready, recording them as commands and running them twice.
PROMPT_COMMAND=($'__akitty_status=$?\n__akitty_owner=$(trap -p DEBUG)\n[[ -n $__akitty_owner ]] || { trap \'__akitty_preexec\' DEBUG; __akitty_owner=$(trap -p DEBUG); }\n__akitty_first_prompt')
