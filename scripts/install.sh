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
work="" zip="" staging="" backup="" dest="" lock="" lock_owned="" inner_pid=""
# Destination the inner installer will lock, derived in entry mode from the same
# argument it receives. Kept at script level so on_signal's cleanup can identify a
# lock the escalated inner left behind.
entry_dest=""
# Set while this process holds a handle-shaped gap: acquire_lock() between mkdir
# and recording ownership, or entry mode between starting the inner installer and
# recording its PID. Signals that arrive then are only recorded (deferred_signal),
# because acting immediately would run cleanup before lock_owned names the lock
# this process created (leaking it) or before inner_pid names the child just
# spawned (orphaning it). Each window's owner clears its flag and finalizes.
lock_acquiring=0 inner_acquiring=0 deferred_signal=""

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
    # The lock path may have been removed and recreated by another installer
    # that now owns it; an owner that is not this PID means the lock is not ours
    # to delete. An owner-less lock is still ours (a signal can arrive between
    # the atomic mkdir and writing the owner file), so it is removed as before.
    if [ -f "$lock_owned/owner" ]; then
        local owner=""
        owner="$(cat "$lock_owned/owner" 2>/dev/null || true)"
        if [ "$owner" != "$$" ]; then
            lock_owned=""; lock=""
            return 0
        fi
    fi
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
# While a lock or the inner child is being acquired the signal is only recorded:
# cleanup would run before lock_owned names the lock this process just created,
# or before inner_pid names the child it just spawned.
on_signal() { # SIGNAME
    local sig="$1"
    if [ "$lock_acquiring" = 1 ] || [ "$inner_acquiring" = 1 ]; then
        deferred_signal="$sig"
        return 0
    fi
    # Entry mode runs the downloaded installer as a background child. Stop and
    # reap it before this process removes the work directory it runs from and
    # dies, so a signal delivered only to this PID can never leave the inner
    # installer running (and reporting success) after the entry is gone.
    if [ -n "$inner_pid" ]; then
        local child="$inner_pid" waited=0
        inner_pid=""
        kill -s "$sig" "$child" 2>/dev/null || true
        # The graceful wait is bounded: a child that ignores INT/TERM, or is
        # stuck, would otherwise block this handler forever and the entry could
        # never exit. bash reaps an exited child itself, so kill -0 stops
        # matching as soon as the child is gone; 50 x 0.1s is the ~5s window.
        while [ "$waited" -lt 50 ] && kill -0 "$child" 2>/dev/null; do
            sleep 0.1
            waited=$((waited + 1))
        done
        # Escalate after the grace window so the child cannot outlive the entry
        # that owns the directory it runs from; wait then reaps it either way.
        kill -KILL "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        # The child is reaped; drop a lock the escalation left behind so the next
        # install into the same destination is not blocked by a dead owner.
        release_escalated_lock "$child"
    fi
    cleanup
    trap - "$sig"
    kill -s "$sig" $$
}

release_escalated_lock() { # dead inner pid
    # An inner child killed by the escalation above never runs its own EXIT trap,
    # so the destination lock it created would outlive it and block every later
    # install. Remove that lock only when its owner file still names exactly the
    # dead child: a missing or different owner belongs to another installer (or
    # cannot be attributed), and unrelated staging and backup directories are
    # never touched. A graceful inner exit already released its lock, so this is
    # a no-op then.
    local child="$1" stale="" owner=""
    [ -n "$entry_dest" ] || return 0
    stale="$entry_dest/.akitty-install.lock"
    [ -f "$stale/owner" ] || return 0
    owner="$(cat "$stale/owner" 2>/dev/null || true)"
    [ "$owner" = "$child" ] || return 0
    rm -rf "$stale" || true
}

# Finish a termination deferred during one of the acquire windows, once the
# handle it was waiting for exists. Re-entering on_signal keeps a single
# termination path: the inner child is stopped and reaped, cleanup runs, and the
# recorded signal is re-raised. The EXIT trap does not run when the shell dies by
# a signal, so the installer terminates by that signal instead of resuming or
# exiting 1. Clearing the slot first bounds this to one level of recursion.
finalize_deferred_signal() {
    [ -n "$deferred_signal" ] || return 0
    local sig="$deferred_signal"
    deferred_signal=""
    on_signal "$sig"
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
    # rename(2) refuses an occupied destination, so a path that appears after the
    # backup move can never be nested into: /bin/mv would move staging/Akitty.app
    # inside it, report success, and let the old app be deleted below.
    /usr/bin/perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' \
        "$staging/Akitty.app" "$dest/Akitty.app" 2>/dev/null \
        || die "cannot move the app into $dest"
    if [ -n "$backup" ]; then
        rm -rf "$backup" || say "previous AkiTTY preserved at $backup/Akitty.app"
        backup=""
    fi

    say "installed AkiTTY $version; quit and relaunch Akitty if it is already running"
    printf '%s\n' "$dest/Akitty.app"
}

if [ "${1:-}" != "--inner" ]; then
    # The inner installer locks the destination named by the same argument it
    # receives, so derive that path here: if the escalation in on_signal kills the
    # inner before its own cleanup runs, the entry can still identify its lock.
    case "${1:-}" in
        "") if [ -n "${HOME:-}" ]; then entry_dest="$HOME/Applications"; fi ;;
        --system) entry_dest="/Applications" ;;
    esac
    command -v curl >/dev/null 2>&1 || die "curl is required"
    work="$(mktemp -d "${TMPDIR:-/tmp}/akitty-entry.XXXXXX")" || die "cannot create a temporary directory"
    fetch "$BASE_URL/install" "$work/install"
    # Run the downloaded installer in the background and wait for it: bash defers
    # a trap while waiting for a foreground child, so a signal sent only to this
    # PID would let the inner installer finish and print success first. Tracking
    # the child lets on_signal forward the signal and reap it before cleanup.
    # With job control off an async child inherits SIGINT ignored and could never
    # trap the forwarded signal, so reset the dispositions before the exec.
    # The PID only exists after the fork, so a signal delivered in that window is
    # recorded (inner_acquiring) instead of acted on, then finalized below once
    # inner_pid is assigned; that path goes through on_signal, so the child is
    # stopped as well and never left orphaned.
    inner_acquiring=1
    /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV' \
        bash "$work/install" --inner "$@" &
    inner_pid=$!
    inner_acquiring=0
    finalize_deferred_signal
    status=0
    wait "$inner_pid" || status=$?
    # A killer outside this process (SIGKILL from another session, or any signal
    # this entry never forwarded) makes wait report 128+N even though on_signal
    # never ran, so the destination lock that child held would survive it and
    # block every later install. Only a status of 128 or more can mean the child
    # skipped its own EXIT trap; the exact-owner check inside the release makes a
    # graceful exit, a foreign owner, and an owner-less lock no-ops.
    if [ "$status" -ge 128 ]; then release_escalated_lock "$inner_pid"; fi
    inner_pid=""
    exit "$status"
else
    shift
    install_inner "$@"
fi
