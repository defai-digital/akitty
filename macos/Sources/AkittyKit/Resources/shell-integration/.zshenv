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
        # A startup file that sourced akitty.zsh itself registered its precmd hook, which already handles this prompt.
        local __akitty_sourced=${__akitty_installed-}
        source "$__akitty_integration"
        unset __akitty_integration
        [[ -z $__akitty_sourced ]] && (( $+functions[__akitty_precmd] )) || return 0
        # Hooks added while precmd runs start with the next prompt, so this prompt's hook runs here. Its ready mark
        # still waits for the user's precmd hooks, which run after this one (see akitty.zsh).
        __akitty_precmd
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __akitty_deferred_init
else
    unset __akitty_integration
fi
