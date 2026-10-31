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
        # Hooks added while precmd runs start with the next prompt; mark this one directly.
        (( ! $+functions[__akitty_precmd] )) || __akitty_precmd
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __akitty_deferred_init
else
    unset __akitty_integration
fi
