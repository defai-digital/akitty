# macOS /etc/zshrc selects HISTFILE before this wrapper restores ZDOTDIR.
# Keep history out of the signed application resources, then allow user overrides.
[[ $HISTFILE != "$AKITTY_INTEGRATION_DIR/.zsh_history" ]] || HISTFILE="$AKITTY_USER_ZDOTDIR/.zsh_history"
ZDOTDIR=$AKITTY_USER_ZDOTDIR
[[ ! -r "$ZDOTDIR/.zshrc" ]] || source "$ZDOTDIR/.zshrc"
source "$AKITTY_INTEGRATION_DIR/akitty.zsh"
unset AKITTY_INTEGRATION_DIR AKITTY_USER_ZDOTDIR
