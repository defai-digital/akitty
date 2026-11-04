# Source this file from repository-root build scripts.
# Prefer rustup; accept an exact-version distribution toolchain as well.
export PATH="$HOME/.cargo/bin:$PATH"
export AKITTY_RUST_DISTRIBUTION=false
if command -v rustup >/dev/null 2>&1; then
    export RUSTUP_TOOLCHAIN=1.99.1
    export RUSTC="$(rustup which --toolchain 1.99.1 rustc)"
    export RUSTDOC="$(rustup which --toolchain 1.99.1 rustdoc)"
else
    export AKITTY_RUST_DISTRIBUTION=true
    export RUSTC="$(command -v rustc)"
    export RUSTDOC="$(command -v rustdoc)"
fi
[[ $("$RUSTC" --version) == 'rustc 1.99.1 '* ]] || {
    echo 'Rust 1.99.1 is required; install the pinned toolchain.' >&2
    exit 1
}
[[ $(cargo --version) == 'cargo 1.99.1 '* ]] || {
    echo 'Cargo 1.99.1 is required; install the pinned toolchain.' >&2
    exit 1
}
