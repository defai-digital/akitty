#!/usr/bin/env bash
# AkiTTY installer: a download-then-run bootstrap that never pipes into a shell.
#
#   curl -fsSL https://download.automatosx.com/akitty/install -o install.sh
#   bash install.sh            # into ~/Applications
#   bash install.sh --system   # into /Applications (the location must be writable)
#
# The same file is served at /akitty/install; the entry mode re-downloads itself
# and then runs the inner mode, so a partial or empty download is never executed.
# Trust chain: the archive digest comes from the immutable release manifest
# (releases/download/vX.Y.Z/release.json), which the release pipeline refuses to
# change, and must match the mutable latest.json pointer. The extracted app must
# pass codesign and Gatekeeper (notarization) before anything is moved into place.
set -Eeuo pipefail

BASE_URL="https://download.automatosx.com/akitty"

# These are script-level so the EXIT trap still sees them after a failure inside
# any function; they start empty and are filled in as the install progresses.
work="" zip="" staging="" backup="" dest="" lock="" lock_owned=""
# Set only while acquire_lock() is between mkdir and recording ownership; signals
# that arrive then are deferred so they cannot run cleanup before lock_owned is
# assigned and leak a lock this process created.
lock_acquiring=0 lock_signal=""

die() { echo "akitty: $*" >&2; exit 1; }
say() { echo "akitty: $*" >&2; }

acquire_lock() { # dest
    # mkdir is atomic, so only one installer can hold the lock for a destination.
    lock="$1/.akitty-install.lock"
    lock_acquiring=1
    if ! mkdir "$lock" 2>/dev/null; then
        lock_acquiring=0
        # A signal recorded during the failed mkdir must still terminate the
        # installer by that signal. lock_owned was never set, so the foreign
        # lock and its owner are left untouched by the cleanup below.
        finalize_deferred_signal
        local owner="" note=""
        if [ -f "$lock/owner" ]; then owner="$(cat "$lock/owner" 2>/dev/null || true)"; fi
        if [ -n "$owner" ]; then note=" (owner pid $owner)"; fi
        die "another AkiTTY install is already running for $1$note; remove $lock only if no install is active"
    fi
    lock_owned="$lock"
    if ! printf '%s\n' "$$" > "$lock/owner"; then
        # The redirect may already have created an empty owner file, so rmdir
        # cannot be used here: remove the whole lock this process created.
        lock_acquiring=0
        rm -rf "$lock" || true
        lock=""; lock_owned=""
        # Lock cleanup and ownership are settled, so a signal deferred during a
        # successful mkdir can now terminate the installer by itself.
        finalize_deferred_signal
        die "cannot record the install lock owner in $1"
    fi
    lock_acquiring=0
    # Ownership is recorded now, so a deferred signal can be re-raised with the
    # normal disposition; cleanup then releases the lock through release_lock.
    finalize_deferred_signal
}

release_lock() {
    # Remove only the lock this process acquired, even if a signal interrupted
    # owner initialization; a foreign or stale lock is never adopted.
    [ -n "$lock_owned" ] || return 0
    rm -rf "$lock_owned" || true
    lock_owned=""; lock=""
}

cleanup() {
    # Restore or preserve the previous app before any other cleanup, so a failure
    # while deleting staging/zip/work can never strand the old app.
    if [ -n "$backup" ] && [ -e "$backup/Akitty.app" ]; then
        if [ -e "$dest/Akitty.app" ]; then
            # The destination is occupied (a half-finished replacement or a
            # concurrent install); keep the previous app rather than deleting it
            # just because dest exists.
            say "previous AkiTTY preserved at $backup/Akitty.app"
        elif /usr/bin/perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' \
                "$backup/Akitty.app" "$dest/Akitty.app" 2>/dev/null; then
            rmdir "$backup" 2>/dev/null || true
        else
            # rename(2) refuses an occupied destination, so a destination that
            # appears after the check above can never nest the app inside it.
            say "previous AkiTTY preserved at $backup/Akitty.app"
        fi
        # Cleanup runs again from the EXIT trap after a signal handler, so each
        # step must be idempotent and report at most once.
        backup=""
    fi
    # Everything below is best-effort: cleanup failures must not abort the trap.
    if [ -n "$staging" ]; then rm -rf "$staging" || true; fi
    if [ -n "$zip" ]; then rm -f "$zip" || true; fi
    if [ -n "$work" ]; then rm -rf "$work" || true; fi
    release_lock
}
# Cleanup belongs to EXIT only. An INT/TERM handler that merely ran cleanup would
# let the installer resume and even print success after the signal, so those
# handlers clean up, restore the default disposition, and re-raise the same
# signal to terminate. EXIT then runs cleanup again; every step is idempotent.
# While a lock is being acquired the signal is only recorded: cleanup would run
# before lock_owned names the lock this process just created and leak it.
on_signal() { # SIGNAME
    local sig="$1"
    if [ "$lock_acquiring" = 1 ]; then
        lock_signal="$sig"
        return 0
    fi
    cleanup
    trap - "$sig"
    kill -s "$sig" $$
}

# Finish a termination deferred while the lock was being acquired, once the lock
# state is settled. The EXIT trap does not run when the shell dies by a signal,
# so clean up first, restore the default disposition, and re-raise the recorded
# signal so the installer terminates by it instead of resuming or exiting 1.
finalize_deferred_signal() {
    [ -n "$lock_signal" ] || return 0
    local sig="$lock_signal"
    lock_signal=""
    cleanup
    trap - "$sig"
    kill -s "$sig" $$
}
trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

fetch() { # url destination
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error \
        --location --retry 3 --connect-timeout 20 --max-time 120 "$1" -o "$2" \
        || die "download failed: $1 (nothing was installed)"
    [ -s "$2" ] || die "download was empty: $1 (nothing was installed)"
}

json_value() { # file key
    plutil -extract "$2" raw -o - "$1" 2>/dev/null || die "malformed $1 (missing $2)"
}

sha256_of() {
    shasum -a 256 "$1" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]'
}

install_inner() {
    [ "$(uname -s)" = "Darwin" ] || die "AkiTTY installs on macOS only"
    [ "$(uname -m)" = "arm64" ] || die "only Apple Silicon builds exist today (found $(uname -m))"
    local macos_version major
    macos_version="$(sw_vers -productVersion)"
    major="${macos_version%%.*}"
    case "$major" in ''|*[!0-9]*) die "cannot read the macOS version" ;; esac
    [ "$major" -ge 14 ] || die "macOS 14 or later is required (found $macos_version)"

    case "${1:-}" in
        "") ;;
        --system) dest="/Applications" ;;
        -h|--help)
            say "usage: install.sh [--system]"
            return 0
            ;;
        *) die "unknown argument: $1 (usage: install.sh [--system])" ;;
    esac
    [ -n "$dest" ] || dest="$HOME/Applications"
    [ -d "$dest" ] || mkdir -p "$dest" 2>/dev/null || die "cannot create $dest"
    [ -w "$dest" ] || die "$dest is not writable; run without --system to install into $HOME/Applications"

    work="$(mktemp -d "${TMPDIR:-/tmp}/akitty-install.XXXXXX")" || die "cannot create a temporary directory"

    # The mutable pointer names the version; the immutable manifest owns the digest.
    fetch "$BASE_URL/latest.json" "$work/latest.json"
    local version ver latest_sha
    version="$(json_value "$work/latest.json" version)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "latest.json has an invalid version: $version"
    ver="v$version"
    fetch "$BASE_URL/releases/download/$ver/release.json" "$work/release.json"
    [ "$(json_value "$work/release.json" version)" = "$version" ] || die "release manifest version differs from latest.json"
    latest_sha="$(json_value "$work/latest.json" sha256 | tr '[:upper:]' '[:lower:]')"
    local sha name size
    sha="$(json_value "$work/release.json" sha256 | tr '[:upper:]' '[:lower:]')"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "release manifest has an invalid sha256"
    [ "$latest_sha" = "$sha" ] || die "latest.json does not match the immutable release manifest"
    name="$(json_value "$work/release.json" name)"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$ ]] || die "release manifest has an invalid archive name"
    size="$(json_value "$work/release.json" size)"
    case "$size" in ''|*[!0-9]*) die "release manifest has an invalid size" ;; esac

    say "downloading AkiTTY $version for Apple Silicon"
    zip="$work/$name"
    fetch "$BASE_URL/releases/download/$ver/$name" "$zip"
    [ "$(wc -c < "$zip" | tr -d ' ')" = "$size" ] || die "archive size differs from the release manifest"
    [ "$(sha256_of "$zip")" = "$sha" ] || die "archive checksum differs from the release manifest"

    # Serialize mutation of this destination before staging: a second installer
    # with the same destination is rejected instead of racing the final moves.
    acquire_lock "$dest"

    # Stage on the destination filesystem so the final move is a rename, never a copy.
    staging="$(mktemp -d "$dest/.akitty-install.XXXXXX")" || die "cannot stage the install in $dest"
    ditto -x -k "$zip" "$staging" || die "cannot extract the archive"
    [ -d "$staging/Akitty.app" ] || die "archive does not contain Akitty.app"
    codesign --verify --deep --strict "$staging/Akitty.app" || die "code signature verification failed"
    spctl --assess --type execute "$staging/Akitty.app" >/dev/null 2>&1 \
        || die "Gatekeeper assessment failed; the app is not notarized"

    if [ -e "$dest/Akitty.app" ]; then
        # Exclusively created, so a leftover or attacker-planted path with a
        # predictable name can never be adopted as the backup.
        backup="$(mktemp -d "$dest/.akitty-backup.XXXXXX")" \
            || die "cannot back up the existing $dest/Akitty.app"
        if ! mv "$dest/Akitty.app" "$backup/Akitty.app"; then
            rmdir "$backup" 2>/dev/null || true
            backup=""
            die "cannot replace the existing $dest/Akitty.app"
        fi
    fi
    mv "$staging/Akitty.app" "$dest/Akitty.app" || die "cannot move the app into $dest"
    if [ -n "$backup" ]; then
        rm -rf "$backup" || say "previous AkiTTY preserved at $backup/Akitty.app"
        backup=""
    fi

    say "installed AkiTTY $version; quit and relaunch Akitty if it is already running"
    printf '%s\n' "$dest/Akitty.app"
}

if [ "${1:-}" != "--inner" ]; then
    command -v curl >/dev/null 2>&1 || die "curl is required"
    work="$(mktemp -d "${TMPDIR:-/tmp}/akitty-entry.XXXXXX")" || die "cannot create a temporary directory"
    fetch "$BASE_URL/install" "$work/install"
    bash "$work/install" --inner "$@"
    exit $?
else
    shift
    install_inner "$@"
fi
