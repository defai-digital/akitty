#!/bin/bash
# Offline contract tests for scripts/install.sh. Every external command that the
# installer touches (curl, plutil, ditto, codesign, spctl, uname, sw_vers) is
# replaced by a PATH shim, so this suite never reaches the network and never
# mutates the machine outside its temporary HOME.
set -euo pipefail
cd "$(dirname "$0")/.."

root="$(mktemp -d "${TMPDIR:-/tmp}/akitty-install-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT INT TERM
bin="$root/bin"
fixtures="$root/fixtures"
home="$root/home"
mkdir -p "$bin" "$fixtures" "$home/Applications"

fail() { echo "installer test failed: $*" >&2; exit 1; }
shim() { cat > "$bin/$1"; chmod +x "$bin/$1"; }

shim uname <<'SH'
#!/bin/bash
case "${1:-}" in
  -s) echo "${TEST_OS:-Darwin}" ;;
  -m) echo "${TEST_ARCH:-arm64}" ;;
  *) echo "${TEST_OS:-Darwin}" ;;
esac
SH
shim sw_vers <<'SH'
#!/bin/bash
echo "${TEST_MACOS:-14.5}"
SH
shim curl <<'SH'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$TEST_LOG"
url=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || { echo "curl shim: missing -o" >&2; exit 91; }
case "${CURL_MODE:-ok}" in
  fail) exit 22 ;;
  empty) : > "$out"; exit 0 ;;
esac
case "$url" in
  */install) src="${TEST_SCRIPT:-}" ;;
  */latest.json) src="$TEST_FIXTURES/latest.json" ;;
  */release.json) src="$TEST_FIXTURES/release.json" ;;
  *.zip) src="$TEST_FIXTURES/app.zip" ;;
  *) echo "curl shim: unexpected URL $url" >&2; exit 90 ;;
esac
[ -n "$src" ] || { echo "curl shim: no fixture for $url" >&2; exit 92; }
cp "$src" "$out"
SH
shim plutil <<'SH'
#!/bin/bash
# plutil -extract <key> raw -o - <file>
[ "${1:-}" = "-extract" ] || { echo "plutil shim: unsupported args" >&2; exit 93; }
python3 - "$2" "$6" <<'PY'
import json, sys
value = json.load(open(sys.argv[2]))[sys.argv[1]]
sys.stdout.write(str(int(value)) if isinstance(value, int) else str(value))
PY
SH
shim ditto <<'SH'
#!/bin/bash
printf 'ditto %s\n' "$*" >> "$TEST_LOG"
[ "${1:-}" = "-x" ] && [ "${2:-}" = "-k" ] || { echo "ditto shim: unsupported args" >&2; exit 94; }
mkdir -p "$4/Akitty.app/Contents/MacOS"
printf 'fake\n' > "$4/Akitty.app/Contents/MacOS/Akitty"
SH
shim codesign <<'SH'
#!/bin/bash
printf 'codesign %s\n' "$*" >> "$TEST_LOG"
exit "${TEST_CODESIGN:-0}"
SH
shim spctl <<'SH'
#!/bin/bash
printf 'spctl %s\n' "$*" >> "$TEST_LOG"
exit "${TEST_SPCTL:-0}"
SH

# Fixtures: a fake archive plus matching/mismatching manifests.
version="9.9.9"
name="AkiTTY-$version-macOS-arm64.zip"
printf 'fake archive bytes\n' > "$fixtures/app.zip"
sha="$(shasum -a 256 "$fixtures/app.zip" | cut -d' ' -f1)"
size="$(wc -c < "$fixtures/app.zip" | tr -d ' ')"
manifest() { # sha256
  printf '{"schema":1,"version":"%s","name":"%s","size":%s,"sha256":"%s"}\n' \
    "$version" "$name" "$size" "$1"
}
manifest "$sha" > "$fixtures/latest.json"
manifest "$sha" > "$fixtures/release.json"

run_install() { # extra env assignments as "KEY=VALUE" args
  env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" "$@" \
    bash scripts/install.sh --inner
}

expect_failure() { # description, expected stderr fragment, env...
  local description="$1" fragment="$2"; shift 2
  local output status=0
  rm -rf "$home/Applications/Akitty.app"
  output="$(env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" "$@" \
    bash scripts/install.sh --inner 2>&1)" || status=$?
  [ "$status" -ne 0 ] || fail "$description: expected a non-zero exit"
  case "$output" in *"$fragment"*) ;; *) fail "$description: missing '$fragment' in: $output" ;; esac
  [ ! -e "$home/Applications/Akitty.app" ] || fail "$description: installed an app despite failing"
}

# Inner mode: the image has to exist before it can be verified.
printf 'FAKE ARCHIVE BYTES\n' > "$fixtures/app.zip"   # same length, different bytes
expect_failure "tampered archive" "checksum differs"
printf 'short\n' > "$fixtures/app.zip"
expect_failure "truncated archive" "size differs"
printf 'fake archive bytes\n' > "$fixtures/app.zip"

expect_failure "signature failure" "code signature verification failed" TEST_CODESIGN=1
expect_failure "gatekeeper failure" "Gatekeeper assessment failed" TEST_SPCTL=1
expect_failure "wrong architecture" "Apple Silicon" TEST_ARCH=x86_64
expect_failure "old macOS" "macOS 14" TEST_MACOS=13.6

manifest "$sha" | sed 's/9\.9\.9/9.9/' > "$fixtures/latest-release-bad.json"
cp "$fixtures/latest.json" "$fixtures/latest.json.bak"
cp "$fixtures/latest-release-bad.json" "$fixtures/latest.json"
expect_failure "invalid version" "invalid version"
cp "$fixtures/latest.json.bak" "$fixtures/latest.json"

manifest "$(printf 'a%.0s' {1..64})" > "$fixtures/latest.json"
expect_failure "pointer disagrees with immutable manifest" "does not match the immutable release manifest"
cp "$fixtures/latest.json.bak" "$fixtures/latest.json"

# Inner mode: unknown arguments are rejected, not guessed at.
: > "$root/log"
status=0
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  bash scripts/install.sh --inner --bogus >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "unknown argument was accepted"
[ ! -e "$home/Applications/Akitty.app" ] || fail "unknown argument installed an app"

# Inner mode: a verified install lands in ~/Applications and prints the path.
: > "$root/log"
status=0
output="$(env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  bash scripts/install.sh --inner 2>&1)" || status=$?
[ "$status" -eq 0 ] || fail "verified install failed ($status): $output"
[ -e "$home/Applications/Akitty.app/Contents/MacOS/Akitty" ] || fail "verified install did not create the app: $output"
[ "$(printf '%s\n' "$output" | tail -1)" = "$home/Applications/Akitty.app" ] || fail "installer did not print the app path: $output"
grep -q "codesign --verify --deep --strict" "$root/log" || fail "codesign was not called"
grep -q "spctl --assess" "$root/log" || fail "spctl was not called"

# Inner mode: reinstalling replaces the previous copy.
printf 'old\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  bash scripts/install.sh --inner >/dev/null 2>&1 || fail "reinstall failed"
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty")" != "old" ] || fail "reinstall kept the old app"

# Entry mode: a failed or empty download is never executed.
marker="$root/executed"
printf '#!/bin/bash\ntouch "%s"\n' "$marker" > "$root/marker.sh"
for mode in fail empty; do
  rm -f "$marker"
  status=0
  env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" CURL_MODE="$mode" TEST_SCRIPT="$root/marker.sh" \
    bash scripts/install.sh >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "entry mode accepted a $mode download"
  [ ! -e "$marker" ] || fail "entry mode executed a $mode download"
done

# Entry mode: a complete download runs the inner mode transparently.
rm -f "$marker"
printf '#!/bin/bash\ntouch "%s"\nprintf "%%s\\n" "$@" > "%s/args"\n' "$marker" "$root" > "$root/marker.sh"
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_SCRIPT="$root/marker.sh" \
  bash scripts/install.sh --system >/dev/null 2>&1 || fail "entry mode did not run the downloaded installer"
[ -e "$marker" ] || fail "entry mode did not execute a complete download"
[ "$(cat "$root/args")" = "--inner
--system" ] || fail "entry mode did not forward --inner and the caller's arguments"

echo "installer tests passed"
