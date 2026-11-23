# Restore the user's ZDOTDIR first: system zprofile/zshrc/zlogin then never see this bundled directory, so their
# compinit dumps and HISTFILE defaults land with the user instead of inside the signed application resources.
ZDOTDIR=$AKITTY_USER_ZDOTDIR
typeset -g __akitty_integration=$AKITTY_INTEGRATION_DIR/akitty.zsh
unset AKITTY_INTEGRATION_DIR AKITTY_USER_ZDOTDIR
[[ ! -r "$ZDOTDIR/.zshenv" ]] || source "$ZDOTDIR/.zshenv"
if [[ -o interactive ]]; then
    # Load at the first prompt, after the user's .zshrc and .zlogin, so their prompt and hooks are already set.
    function __akitty_deferred_init() {
        add-zsh-hook -d precmd __akitty_deferred_init
        unfunction __akitty_deferred_init
        source "$__akitty_integration"
        unset __akitty_integration
        (( $+functions[__akitty_precmd] )) || return 0
        # Hooks added while precmd runs start with the next prompt, so this prompt is marked here. This hook was added
        # before the user's startup files, so their precmd hooks still run after it. The ready mark waits for the line
        # editor's first start, after those hooks and the prompt: a hook still reading the terminal (an update
        # question) must not look like an idle prompt. Without the line editor the mark is printed now.
        if [[ -o zle ]] && autoload -Uz add-zle-hook-widget 2>/dev/null \
            && add-zle-hook-widget line-init __akitty_first_line 2>/dev/null; then
            local __akitty_defer_mark=1
        fi
        __akitty_precmd
    }
    function __akitty_first_line() {
        add-zle-hook-widget -d line-init __akitty_first_line
        printf '\e]133;A\a'
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __akitty_deferred_init
else
    unset __akitty_integration
fi
