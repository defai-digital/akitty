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
# Command history: commands zsh keeps in history are also saved in a shared store. Tab at the end of a typed prefix
# lists the five most recent distinct matches, those run in this folder first, then those from other folders; Up/Down
# choose (the line previews the choice), Enter keeps it on the line, Esc restores the prefix, Tab completes as usual and
# any other key closes the list and is typed. Up/Down on a typed prefix step through the same matches. Without a match
# every key does what it did before.
# AKITTY_FOLDER_HISTORY=0 turns this off.
[[ ${AKITTY_FOLDER_HISTORY-} != 0 ]] || return
zmodload -F zsh/datetime p:EPOCHSECONDS 2>/dev/null
if ! zmodload -F zsh/system b:zsystem b:sysopen 2>/dev/null || ! zmodload -F zsh/stat b:zstat 2>/dev/null; then
    print -u2 -r -- 'AkiTTY command history unavailable: safe file locking modules are missing.'
    return
fi
# zsh 5.8 lacks nonblocking opens. Keep its normal history and keys rather than risk blocking on a replaced file.
if ! () {
    local descriptor
    sysopen -r -o nofollow,nonblock,cloexec -u descriptor /dev/null 2>/dev/null || return 1
    exec {descriptor}<&-
}; then
    print -u2 -r -- 'AkiTTY command history unavailable: safe nonblocking file opens are missing.'
    return
fi
typeset -g __akitty_folder_file=${AKITTY_FOLDER_HISTORY_FILE:-$HOME/Library/Application Support/Akitty/folder-history}
# Keep the existing storage format, configuration and preference keys so saved commands remain available.
typeset -ga __akitty_folder_menu __akitty_folder_cycle
typeset -g __akitty_folder_original __akitty_folder_keymap __akitty_folder_shown
typeset -gi __akitty_folder_selected __akitty_folder_warned=0 __akitty_folder_named_result=0 __akitty_folder_hooks_ready=1
function __akitty_folder_warning() {
    if (( ! __akitty_folder_warned )); then
        print -u2 -r -- "AkiTTY command history unavailable: $1"
        __akitty_folder_warned=1
    fi
    return 1
}
function __akitty_folder_safe_file() {
    local -A info
    zstat -L -H info -- "$1" 2>/dev/null &&
        (( (info[mode] & 8#170000) == 8#100000 && info[uid] == EUID && (info[mode] & 8#777) == 8#600 && info[nlink] == 1 ))
}
function __akitty_folder_create() {
    [[ -e $1 || -L $1 ]] && return 0
    local created
    sysopen -w -m 600 -o create,excl,nofollow,nonblock,cloexec -u created "$1" 2>/dev/null || return 1
    exec {created}>&-
}
# All readers, appends and compaction share the same POSIX lock as Settings. Never fall back to an unlocked write.
function __akitty_folder_locked() {
    emulate -L zsh
    local LC_ALL=C file=$__akitty_folder_file lock
    local -A parent
    [[ $file == /* && ${#file} -le 4096 && ! -L ${file:h} ]] || { __akitty_folder_warning 'unsafe history path'; return 1; }
    [[ -d ${file:h} ]] || (umask 077; mkdir -p -- "${file:h}") 2>/dev/null || return 1
    zstat -L -H parent -- "${file:h}" 2>/dev/null &&
        (( (parent[mode] & 8#170000) == 8#40000 && parent[uid] == EUID && (parent[mode] & 8#22) == 0 )) ||
        { __akitty_folder_warning 'unsafe history directory'; return 1; }
    __akitty_folder_create "$file.lock" && __akitty_folder_safe_file "$file.lock" ||
        { __akitty_folder_warning 'unsafe history lock'; return 1; }
    zsystem flock -t 1 -f lock "$file.lock" 2>/dev/null ||
        { __akitty_folder_warning 'history is busy; no data was written'; return 1; }
    {
        __akitty_folder_create "$file" && __akitty_folder_safe_file "$file" ||
            { __akitty_folder_warning 'history must be a private regular file without links'; return 1; }
        "$@" || { __akitty_folder_warning 'cannot access history'; return 1; }
    } always { zsystem flock -u $lock }
}
# Read at most 512 KiB and 3000 rows, including when an existing file is unexpectedly oversized.
function __akitty_folder_read() {
    local descriptor data
    local -A info
    sysopen -r -o nofollow,nonblock,cloexec -u descriptor "$__akitty_folder_file" 2>/dev/null || return 1
    {
        zstat -H info -f $descriptor && (( (info[mode] & 8#170000) == 8#100000 )) || return 1
        data=$(/usr/bin/tail -c 524288 <&$descriptor) || return 1
        reply=("${(@f)data}")
        # The bounded tail may start halfway through a record; never offer that fragment as a command.
        (( info[size] <= 524288 )) || reply=("${(@)reply[2,-1]}")
        (( $#reply <= 3000 )) || reply=("${(@)reply[-3000,-1]}")
    } always { exec {descriptor}<&- }
}
function __akitty_folder_trim() {
    local -A info
    zstat -L -H info -- "$__akitty_folder_file" || return 1
    (( info[size] > 524288 )) || return 0
    local -a reply
    __akitty_folder_read || return 1
    local temporary=$__akitty_folder_file.$$.tmp descriptor
    sysopen -w -m 600 -o create,excl,nofollow,cloexec -u descriptor "$temporary" 2>/dev/null || return 1
    {
        if (( $#reply )); then print -rl -u $descriptor -- "${reply[@]}" || return 1; fi
        exec {descriptor}>&-; descriptor=
        command mv -f -- "$temporary" "$__akitty_folder_file"
    } always {
        [[ -z ${descriptor-} ]] || exec {descriptor}>&-
        [[ ! -e $temporary ]] || command rm -f -- "$temporary"
    }
}
function __akitty_folder_append() {
    local LC_ALL=C descriptor
    (( ${#1} <= 16384 )) || return 1
    sysopen -a -o nofollow,nonblock,cloexec -u descriptor "$__akitty_folder_file" 2>/dev/null || return 1
    { print -r -u $descriptor -- "$1" } always { exec {descriptor}>&- }
    __akitty_folder_trim
}
# Observe each hook's status without hiding the registered names: add-zsh-hook must still be able to find,
# remove and deduplicate them. zsh runs the hooks itself, preserving their order and native history decisions.
# The named hook resets the decision for each line, even when a rejected line never reaches the final writer.
function __akitty_folder_capture_named() {
    local -i __akitty_folder_hook_depth=1
    __akitty_folder_named_result=0
    if (( $+functions[__akitty_folder_named_saved] )); then
        __akitty_folder_named_saved "$@"
        __akitty_folder_named_result=$?
    fi
    return $__akitty_folder_named_result
}
function __akitty_folder_capture_hook() {
    # zsh locals are dynamically scoped: user hooks must still read and update their own variables.
    local __akitty_folder_hook_result
    local -i __akitty_folder_hook_depth=$(( ${__akitty_folder_hook_depth:-0} + 1 ))
    "__akitty_folder_saved_${funcstack[1]}" "$@"; __akitty_folder_hook_result=$?
    # A hook can call another registered function and handle its failure; only the outer result counts.
    (( __akitty_folder_hook_depth == 1 && __akitty_folder_hook_result != 0 && __akitty_folder_named_result == 0 )) && __akitty_folder_named_result=$__akitty_folder_hook_result
    return $__akitty_folder_hook_result
}
function __akitty_folder_addhistory() {
    # A storage skip/failure must not turn an otherwise accepted native history line into a rejection.
    if (( __akitty_folder_hooks_ready && __akitty_folder_named_result == 0 )); then __akitty_folder_store "$@" || true; fi
    return 0
}
function __akitty_folder_store() {
    emulate -L zsh
    local command=${1%$'\n'} logical=$PWD physical=${PWD:A}
    [[ ${AKITTY_FOLDER_HISTORY-} != 0 && $command == [^[:space:]]* && $command != *[$'\n\r']* ]] || return 1
    () { local LC_ALL=C; (( ${#command} <= 1024 )); } || return 1
    [[ -z ${HISTORY_IGNORE-} || $command != ${~HISTORY_IGNORE} ]] || return 1
    # A path with tab/CR/LF cannot be written into a tab-separated record; keep the command with empty path columns.
    [[ $logical$physical != *[$'\t\n\r']* ]] || logical= physical=
    __akitty_folder_locked __akitty_folder_append "${EPOCHSECONDS:-0}"$'\t'"$logical"$'\t'"$physical"$'\t'"$command"
}
# Hooks the user adds after startup join those run in front of the saved line.
function __akitty_folder_wrap_hook() {
    local hook=$1 wrapper=$2 saved=$3
    [[ $functions[$hook] != $functions[$wrapper] ]] || return 0
    # An unloaded autoload stub resolves its own name in fpath. Load it before copying it under a saved name.
    if [[ $functions[$hook] == 'builtin autoload -X'* ]]; then autoload +X -- "$hook" || return 1; fi
    functions -c "$hook" "$saved" && functions -c "$wrapper" "$hook"
}
function __akitty_folder_adopt_hooks() {
    local hook
    __akitty_folder_hooks_ready=1
    if (( $+functions[zshaddhistory] )); then
        __akitty_folder_wrap_hook zshaddhistory __akitty_folder_capture_named __akitty_folder_named_saved || __akitty_folder_hooks_ready=0
    else
        unfunction __akitty_folder_named_saved 2>/dev/null
        functions -c __akitty_folder_capture_named zshaddhistory
    fi
    for hook in "${zshaddhistory_functions[@]}"; do
        [[ $hook != __akitty_folder_addhistory ]] && (( $+functions[$hook] )) || continue
        __akitty_folder_wrap_hook "$hook" __akitty_folder_capture_hook "__akitty_folder_saved_$hook" || __akitty_folder_hooks_ready=0
    done
    zshaddhistory_functions=("${(@)zshaddhistory_functions:#__akitty_folder_addhistory}" __akitty_folder_addhistory)
}
# Sets reply to at most $1 distinct commands that extend the line, newest first: those recorded in this folder (by its
# logical or physical path) before those from other folders. Record order gives recency, so clock changes and equal
# timestamps do not matter.
function __akitty_folder_matches() {
    reply=()
    [[ ${AKITTY_FOLDER_HISTORY-} != 0 && -n $BUFFER && $CURSOR == $#BUFFER && -r $__akitty_folder_file ]] || return 1
    local -a lines fields
    local -A seen
    local line command pass physical=${PWD:A}
    local -i i same
    __akitty_folder_locked __akitty_folder_read || return 1
    lines=("${reply[@]}"); reply=()
    # Two newest-first passes: this folder's records, then the rest. A command run here counts as here.
    for pass in here elsewhere; do
        for (( i = $#lines; i >= 1; i-- )); do
            line=$lines[i]
            (( ${#line} <= 16384 )) || continue
            fields=("${(@ps:\t:)line}")
            (( $#fields >= 4 )) || continue
            same=0; [[ $fields[2] == "$PWD" || $fields[3] == "$physical" ]] && same=1
            if [[ $pass == here ]]; then (( same )) || continue; else (( same )) && continue; fi
            command=${(pj:\t:)fields[4,-1]}
            [[ $command != $BUFFER && ${command[1,$#BUFFER]} == $BUFFER ]] || continue
            [[ -z ${seen[$command]-} ]] || continue
            seen[$command]=1
            reply+=("$command")
            (( $#reply < $1 )) || return 0
        done
    done
    (( $#reply ))
}
function __akitty_folder_show() {
    local list='Command history: Up/Down choose, Enter keep, Esc cancel, Tab complete'
    local -i i width=$(( COLUMNS > 8 ? COLUMNS - 4 : 4 ))
    for (( i = 1; i <= $#__akitty_folder_menu; i++ )); do
        (( i == __akitty_folder_selected )) && list+=$'\n> ' || list+=$'\n  '
        list+=${__akitty_folder_menu[i][1,width]}
    done
    zle -M -- "$list"
}
function __akitty_folder_tab() {
    emulate -L zsh
    local -a reply
    if ! __akitty_folder_matches 5; then zle $__akitty_tab_widget -- "$@"; return; fi
    __akitty_folder_menu=("${reply[@]}") __akitty_folder_original=$BUFFER __akitty_folder_selected=0
    __akitty_folder_keymap=$KEYMAP
    zle -K akitty-folder
    __akitty_folder_show
}
function __akitty_folder_step() {
    emulate -L zsh
    local -i count=$#__akitty_folder_menu
    __akitty_folder_selected=$(( (__akitty_folder_selected + $1 + count + 1) % (count + 1) ))
    (( __akitty_folder_selected )) && BUFFER=$__akitty_folder_menu[__akitty_folder_selected] || BUFFER=$__akitty_folder_original
    CURSOR=$#BUFFER
    __akitty_folder_show
}
function __akitty_folder_close() { zle -K $__akitty_folder_keymap; zle -M ''; }
function __akitty_folder_menu_up() { __akitty_folder_step -1; }
function __akitty_folder_menu_down() { __akitty_folder_step 1; }
function __akitty_folder_menu_accept() { __akitty_folder_close; }
function __akitty_folder_menu_cancel() { BUFFER=$__akitty_folder_original; CURSOR=$#BUFFER; __akitty_folder_close; }
function __akitty_folder_menu_complete() { __akitty_folder_menu_cancel; zle $__akitty_tab_widget; }
function __akitty_folder_menu_other() { __akitty_folder_close; zle -U "$KEYS"; }
# Up/Down on a typed prefix step through the same matches (this folder's first); consecutive presses continue from the
# shown match, Down past the first restores the prefix, and anything else runs the key's previous widget.
function __akitty_folder_arrow() {
    emulate -L zsh
    local fallback=$1; shift
    local -i step=$1
    if [[ $LASTWIDGET == __akitty_folder_(up|down) && $BUFFER == ${__akitty_folder_shown-} && $#__akitty_folder_cycle -gt 0 ]]; then
        :
    elif (( step < 0 )); then
        local -a reply
        __akitty_folder_matches 20 || { zle $fallback; return }
        __akitty_folder_cycle=("${reply[@]}") __akitty_folder_original=$BUFFER __akitty_folder_selected=0
    else
        zle $fallback; return
    fi
    local -i next=$(( __akitty_folder_selected - step ))
    (( next <= $#__akitty_folder_cycle )) || return 0
    __akitty_folder_selected=$(( next < 0 ? 0 : next ))
    (( __akitty_folder_selected )) && BUFFER=$__akitty_folder_cycle[__akitty_folder_selected] || BUFFER=$__akitty_folder_original
    CURSOR=$#BUFFER
    __akitty_folder_shown=$BUFFER
    (( __akitty_folder_selected )) || __akitty_folder_cycle=()
}
function __akitty_folder_up() { __akitty_folder_arrow ${__akitty_folder_widgets[up]} -1; }
function __akitty_folder_down() { __akitty_folder_arrow ${__akitty_folder_widgets[down]} 1; }
# The keys wrap whatever they run after the user's startup files (compinit, fzf-tab, history search and the like).
function __akitty_folder_widget_for() {
    local widget=${${(z)"$(bindkey -M main -- $1)"}[2]}
    [[ -n $widget && $widget != undefined-key ]] && print -r -- $widget || print -r -- $2
}
typeset -g __akitty_tab_widget=$(__akitty_folder_widget_for '^I' expand-or-complete)
typeset -gA __akitty_folder_widgets=(up "$(__akitty_folder_widget_for '^[[A' up-line-or-history)"
    down "$(__akitty_folder_widget_for '^[[B' down-line-or-history)")
() {
    local widget
    for widget in tab up down menu_up menu_down menu_accept menu_cancel menu_complete menu_other; do
        zle -N __akitty_folder_$widget
    done
    bindkey -M main '^I' __akitty_folder_tab
    bindkey -M main '^[[A' __akitty_folder_up '^[OA' __akitty_folder_up '^[[B' __akitty_folder_down '^[OB' __akitty_folder_down
    bindkey -N akitty-folder
    bindkey -M akitty-folder -R '^@'-'^?' __akitty_folder_menu_other
    bindkey -M akitty-folder -R '\M-^@'-'\M-^?' __akitty_folder_menu_other
    bindkey -M akitty-folder '^[[A' __akitty_folder_menu_up '^[OA' __akitty_folder_menu_up \
        '^[[B' __akitty_folder_menu_down '^[OB' __akitty_folder_menu_down '^M' __akitty_folder_menu_accept \
        '^J' __akitty_folder_menu_accept '^[' __akitty_folder_menu_cancel '^G' __akitty_folder_menu_cancel \
        '^I' __akitty_folder_menu_complete
}
__akitty_folder_adopt_hooks
add-zsh-hook precmd __akitty_folder_adopt_hooks
[[ ${AKITTY_FOLDER_HISTORY-} == 0 || ! -e $__akitty_folder_file ]] || __akitty_folder_locked __akitty_folder_trim 2>/dev/null
