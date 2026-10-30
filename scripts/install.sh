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
work="" zip="" staging="" backup="" dest=""

die() { echo "akitty: $*" >&2; exit 1; }
say() { echo "akitty: $*" >&2; }

cleanup() {
    if [ -n "$staging" ]; then rm -rf "$staging"; fi
    if [ -n "$zip" ]; then rm -f "$zip"; fi
    if [ -n "$work" ]; then rm -rf "$work"; fi
    if [ -n "$backup" ]; then
        # A failed replacement restores the previous app; a successful one
        # removed the backup already and cleared this variable.
        if [ -e "$dest/Akitty.app" ]; then rm -rf "$backup"
        else mv "$backup" "$dest/Akitty.app" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT INT TERM

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

    # Stage on the destination filesystem so the final move is a rename, never a copy.
    staging="$(mktemp -d "$dest/.akitty-install.XXXXXX")" || die "cannot stage the install in $dest"
    ditto -x -k "$zip" "$staging" || die "cannot extract the archive"
    [ -d "$staging/Akitty.app" ] || die "archive does not contain Akitty.app"
    codesign --verify --deep --strict "$staging/Akitty.app" || die "code signature verification failed"
    spctl --assess --type execute "$staging/Akitty.app" >/dev/null 2>&1 \
        || die "Gatekeeper assessment failed; the app is not notarized"

    if [ -e "$dest/Akitty.app" ]; then
        backup="$dest/.akitty-backup.$$"
        mv "$dest/Akitty.app" "$backup" || die "cannot replace the existing $dest/Akitty.app"
    fi
    mv "$staging/Akitty.app" "$dest/Akitty.app" || die "cannot move the app into $dest"
    if [ -n "$backup" ]; then rm -rf "$backup"; backup=""; fi

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
