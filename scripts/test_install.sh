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
shim mv <<'SH'
#!/bin/bash
printf 'mv %s\n' "$*" >> "$TEST_LOG"
case "${TEST_MV_BLOCK:-}" in
  staging)
    case "${1:-}" in
      */.akitty-install.*)
        : > "$TEST_READY"
        sleep 30
        echo "mv shim: blocked move interrupted" >&2; exit 143 ;;
    esac
    ;;
esac
case "${TEST_MV_RACE:-}" in
  restore)
    case "${1:-}" in
      */.akitty-backup.*/Akitty.app)
        mkdir -p "$HOME/Applications/Akitty.app/Contents/MacOS"
        printf 'raced\n' > "$HOME/Applications/Akitty.app/Contents/MacOS/Akitty" ;;
    esac
    ;;
esac
case "${TEST_MV_FAIL:-}" in
  staging)
    case "${1:-}" in
      */.akitty-install.*) echo "mv shim: forced failure" >&2; exit 1 ;;
    esac
    ;;
  concurrent)
    case "${1:-}" in
      */.akitty-install.*)
        mkdir -p "$HOME/Applications/Akitty.app/Contents/MacOS"
        printf 'foreign\n' > "$HOME/Applications/Akitty.app/Contents/MacOS/Akitty"
        echo "mv shim: concurrent destination" >&2; exit 1 ;;
    esac
    ;;
esac
exec /bin/mv "$@"
SH
shim rm <<'SH'
#!/bin/bash
printf 'rm %s\n' "$*" >> "$TEST_LOG"
if [ "${TEST_RM_BLOCK:-}" = "backup" ]; then
  for arg in "$@"; do
    case "$arg" in
      */.akitty-backup.*) : > "$TEST_READY"; sleep 30; exit 143 ;;
    esac
  done
fi
if [ "${TEST_RM_FAIL:-}" = "staging" ]; then
  for arg in "$@"; do
    case "$arg" in
      */.akitty-install.??????) echo "rm shim: forced failure" >&2; exit 1 ;;
    esac
  done
fi
exec /bin/rm "$@"
SH
shim mkdir <<'SH'
#!/bin/bash
# Test-only hook around the installer's lock mkdir, so a test can make the lock
# exist at an exact point in acquire_lock. TEST_MKDIR_SIGNAL signals the
# installer while it is still waiting for this mkdir (bash defers the trap until
# the child exits, i.e. before lock_owned is assigned); TEST_MKDIR_SIGNAL_FAIL
# signals it the same way but lets the mkdir fail first, as a foreign lock makes
# it; TEST_MKDIR_OWNER_DIR plants a nonempty obstacle where the owner file has
# to be written.
sig="${TEST_MKDIR_SIGNAL:-}${TEST_MKDIR_SIGNAL_FAIL:-}"
case "${sig}${TEST_MKDIR_OWNER_DIR:-}" in
  "") exec /bin/mkdir "$@" ;;
esac
case "${1:-}" in
  */.akitty-install.lock) ;;
  *) exec /bin/mkdir "$@" ;;
esac
status=0
/bin/mkdir "$@" || status=$?
if [ -n "${TEST_MKDIR_OWNER_DIR:-}" ]; then
  /bin/mkdir "$1/owner" || exit $?
fi
if [ -n "$sig" ]; then
  # Never die from a signal the installer might forward, and stay alive until
  # the signal is delivered, so the installer's trap is deferred until now.
  trap '' INT TERM
  kill -s "$sig" "$PPID"
  /bin/sleep 0.2
fi
exit "$status"
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

# A second installer must be rejected by the atomic per-destination lock, and a
# foreign lock it did not create must survive the rejection untouched.
lock="$home/Applications/.akitty-install.lock"
rm -rf "$lock"
mkdir -p "$lock"
printf '4242\n' > "$lock/owner"
status=0
output="$(env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  bash scripts/install.sh --inner 2>&1)" || status=$?
[ "$status" -ne 0 ] || fail "installer ignored an existing destination lock"
case "$output" in *"already running"*) ;; *) fail "lock rejection was not reported: $output" ;; esac
[ -d "$lock" ] || fail "rejected installer removed a foreign lock"
[ "$(cat "$lock/owner")" = "4242" ] || fail "rejected installer rewrote a foreign lock"
[ ! -e "$home/Applications/Akitty.app" ] || fail "rejected installer installed an app"
rm -rf "$lock"

# A failure to record the owner must remove the lock it created. The mkdir shim
# creates the real lock and plants a nonempty obstacle where the owner file has
# to go, so the redirect fails with the lock already on disk (the same shape as
# a write error after the file exists); cleanup cannot rely on rmdir here.
rm -rf "$lock"
status=0
output="$(env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_MKDIR_OWNER_DIR=1 bash scripts/install.sh --inner 2>&1)" || status=$?
[ "$status" -ne 0 ] || fail "owner-record failure was reported as success"
case "$output" in
  *"cannot record the install lock owner"*) ;;
  *) fail "owner-record failure was not reported: $output" ;;
esac
[ ! -e "$lock" ] || fail "owner-record failure leaked its install lock"
[ ! -e "$home/Applications/Akitty.app" ] || fail "owner-record failure installed an app"

# A signal delivered after the atomic mkdir created the lock but before
# lock_owned was assigned must not leak the lock. The mkdir shim creates the
# real lock and signals the installer while it is still waiting for that mkdir,
# which is exactly where bash defers the trap until the child exits.
python3 - "$root" "$bin" "$home" "$fixtures" "$PWD" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

root, bin_dir, home, fixtures, repo = (Path(value) for value in sys.argv[1:6])
applications = home / "Applications"
lock = applications / ".akitty-install.lock"
app = applications / "Akitty.app" / "Contents" / "MacOS" / "Akitty"
base_env = {
    "PATH": f"{bin_dir}:{os.environ['PATH']}",
    "HOME": str(home),
    "TEST_LOG": str(root / "log"),
    "TEST_FIXTURES": str(fixtures),
}
def reset():
    if lock.is_dir():
        shutil.rmtree(lock, ignore_errors=True)
    elif lock.exists():
        lock.unlink()
    if (applications / "Akitty.app").is_dir():
        shutil.rmtree(applications / "Akitty.app", ignore_errors=True)
failures = []
for signame, signum in (("INT", signal.SIGINT), ("TERM", signal.SIGTERM)):
    reset()
    proc = subprocess.run(
        ["bash", str(repo / "scripts" / "install.sh"), "--inner"],
        cwd=str(repo),
        env={**base_env, "TEST_MKDIR_SIGNAL": signame},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        timeout=60,
    )
    text = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != -signum:
        failures.append(
            f"SIG{signame} during lock acquisition: exited {proc.returncode}, "
            f"not by signal {signum}: {text}"
        )
    if "installed AkiTTY" in text:
        failures.append(f"SIG{signame} during lock acquisition: reported success")
    if lock.exists():
        failures.append(f"SIG{signame} during lock acquisition: left its install lock behind")
    if app.exists():
        failures.append(f"SIG{signame} during lock acquisition: installed an app")
    follow = subprocess.run(
        ["bash", str(repo / "scripts" / "install.sh"), "--inner"],
        cwd=str(repo),
        env=base_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=60,
    )
    if follow.returncode != 0:
        failures.append(
            f"SIG{signame} follow-up install failed ({follow.returncode}): "
            + follow.stdout.decode("utf-8", "replace")
        )
    elif not app.exists() or lock.exists():
        failures.append(f"SIG{signame} follow-up install did not complete cleanly")
    reset()
if failures:
    print("deferred signal test failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
PY

# A signal deferred during a successful mkdir followed by an owner-write failure
# must still terminate by that signal once the lock this process created is
# removed. The mkdir shim creates the real lock, plants the owner obstacle, and
# signals the installer while it waits for that child, so the trap is deferred
# until the owner redirect fails; the failure branch must finalize the signal
# instead of dying with exit 1.
python3 - "$root" "$bin" "$home" "$fixtures" "$PWD" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

root, bin_dir, home, fixtures, repo = (Path(value) for value in sys.argv[1:6])
applications = home / "Applications"
lock = applications / ".akitty-install.lock"
app = applications / "Akitty.app" / "Contents" / "MacOS" / "Akitty"
base_env = {
    "PATH": f"{bin_dir}:{os.environ['PATH']}",
    "HOME": str(home),
    "TEST_LOG": str(root / "log"),
    "TEST_FIXTURES": str(fixtures),
}
def reset():
    if lock.is_dir():
        shutil.rmtree(lock, ignore_errors=True)
    elif lock.exists():
        lock.unlink()
    if (applications / "Akitty.app").is_dir():
        shutil.rmtree(applications / "Akitty.app", ignore_errors=True)
failures = []
for signame, signum in (("INT", signal.SIGINT), ("TERM", signal.SIGTERM)):
    reset()
    proc = subprocess.run(
        ["bash", str(repo / "scripts" / "install.sh"), "--inner"],
        cwd=str(repo),
        env={**base_env, "TEST_MKDIR_SIGNAL": signame, "TEST_MKDIR_OWNER_DIR": "1"},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        timeout=60,
    )
    text = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != -signum:
        failures.append(
            f"SIG{signame} with an owner-write failure: exited {proc.returncode}, "
            f"not by signal {signum}: {text}"
        )
    if "installed AkiTTY" in text:
        failures.append(f"SIG{signame} with an owner-write failure: reported success")
    if lock.exists():
        failures.append(f"SIG{signame} with an owner-write failure: left its install lock behind")
    if app.exists():
        failures.append(f"SIG{signame} with an owner-write failure: installed an app")
    reset()
if failures:
    print("deferred signal with owner failure test failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
PY

# A signal delivered while a foreign lock makes the atomic mkdir fail must still
# terminate by that signal. The mkdir shim lets the lock mkdir fail (as it does
# when another install holds the lock) and then signals the installer while it is
# still waiting for that mkdir, so the trap is deferred past the rejection. The
# foreign lock and its owner must survive and no app may be installed.
python3 - "$root" "$bin" "$home" "$fixtures" "$PWD" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

root, bin_dir, home, fixtures, repo = (Path(value) for value in sys.argv[1:6])
applications = home / "Applications"
lock = applications / ".akitty-install.lock"
app = applications / "Akitty.app" / "Contents" / "MacOS" / "Akitty"
base_env = {
    "PATH": f"{bin_dir}:{os.environ['PATH']}",
    "HOME": str(home),
    "TEST_LOG": str(root / "log"),
    "TEST_FIXTURES": str(fixtures),
}
def reset():
    if lock.is_dir():
        shutil.rmtree(lock, ignore_errors=True)
    elif lock.exists():
        lock.unlink()
    if (applications / "Akitty.app").is_dir():
        shutil.rmtree(applications / "Akitty.app", ignore_errors=True)
failures = []
for signame, signum in (("INT", signal.SIGINT), ("TERM", signal.SIGTERM)):
    reset()
    lock.mkdir(parents=True)
    (lock / "owner").write_text("4242\n")
    proc = subprocess.run(
        ["bash", str(repo / "scripts" / "install.sh"), "--inner"],
        cwd=str(repo),
        env={**base_env, "TEST_MKDIR_SIGNAL_FAIL": signame},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        timeout=60,
    )
    text = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != -signum:
        failures.append(
            f"SIG{signame} with a foreign lock: exited {proc.returncode}, "
            f"not by signal {signum}: {text}"
        )
    if "installed AkiTTY" in text:
        failures.append(f"SIG{signame} with a foreign lock: reported success")
    if not lock.is_dir():
        failures.append(f"SIG{signame} with a foreign lock: removed the foreign lock")
    elif not (lock / "owner").exists() or (lock / "owner").read_text() != "4242\n":
        failures.append(f"SIG{signame} with a foreign lock: rewrote the foreign owner")
    if app.exists():
        failures.append(f"SIG{signame} with a foreign lock: installed an app")
    reset()
if failures:
    print("foreign-lock signal test failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
PY

# Cleanup must not depend on the owner file: a signal can arrive after the
# atomic mkdir but before owner initialization finishes. Exercise the exact
# production function with no owner file and a different foreign lock path.
python3 - scripts/install.sh "$root/release-lock.sh" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index("release_lock() {")
end = source.index("\n}\n", start) + 3
Path(sys.argv[2]).write_text(source[start:end])
PY
mkdir "$root/lock-test"
bash -c '
  . "$1"
  foreign="$2/foreign"; owned="$2/owned"
  lock="$foreign"; lock_owned="$owned"
  mkdir "$lock" "$lock_owned"
  release_lock
  [ ! -e "$owned" ] && [ -d "$foreign" ] && [ -z "$lock_owned$lock" ] || exit 1
  release_lock
' _ "$root/release-lock.sh" "$root/lock-test" \
  || fail "owner-less lock cleanup leaked an owned lock or removed a foreign lock"

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
[ ! -e "$home/Applications/.akitty-install.lock" ] || fail "successful install left its lock behind"

# Inner mode: reinstalling replaces the previous copy.
printf 'old\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  bash scripts/install.sh --inner >/dev/null 2>&1 || fail "reinstall failed"
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty")" != "old" ] || fail "reinstall kept the old app"

# A predictable backup name must never adopt or delete a preexisting path. The
# wrapper records its PID and execs, so the installer's $$ is known in advance.
pidfile="$root/pid"
printf 'old\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
rm -f "$pidfile"
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_PIDFILE="$pidfile" \
  bash -c 'echo $$ > "$TEST_PIDFILE"; mkdir -p "$HOME/Applications/.akitty-backup.$$"; printf "sentinel\n" > "$HOME/Applications/.akitty-backup.$$/sentinel"; exec bash scripts/install.sh --inner' \
  >/dev/null 2>&1 || fail "install with a colliding backup path failed"
pid="$(cat "$pidfile")"
[ -e "$home/Applications/.akitty-backup.$pid/sentinel" ] || fail "install deleted a preexisting backup collision"
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty")" != "old" ] || fail "install kept the old app under a collision"
[ ! -e "$home/Applications/Akitty.app/Akitty.app" ] || fail "install nested the app under a collision"

# Forced rollback after the replacement starts must restore exactly the original
# app and leave unrelated paths alone, even when a backup-shaped path exists.
printf 'original\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
rm -f "$pidfile"
status=0
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_PIDFILE="$pidfile" TEST_MV_FAIL=staging \
  bash -c 'echo $$ > "$TEST_PIDFILE"; mkdir -p "$HOME/Applications/.akitty-backup.$$"; printf "sentinel\n" > "$HOME/Applications/.akitty-backup.$$/sentinel"; exec bash scripts/install.sh --inner' \
  >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "forced staging failure was reported as success"
pid="$(cat "$pidfile")"
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty" 2>/dev/null)" = "original" ] || fail "failed install did not restore the original app"
[ -e "$home/Applications/.akitty-backup.$pid/sentinel" ] || fail "rollback deleted a preexisting backup collision"
[ ! -e "$home/Applications/Akitty.app/Akitty.app" ] || fail "rollback restored a nested app"

# A failure while deleting staging must not abort cleanup before the previous app
# is restored: restore runs first and the later removals are best-effort.
printf 'original\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
status=0
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_MV_FAIL=staging TEST_RM_FAIL=staging \
  bash scripts/install.sh --inner >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "forced staging-delete failure was reported as success"
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty" 2>/dev/null)" = "original" ] || fail "failed install did not restore the original app when staging cleanup failed"
[ ! -e "$home/Applications/.akitty-install.lock" ] || fail "failed install did not release its lock"
rm -rf "$home/Applications"/.akitty-install.*

# When the destination is occupied at failure time, the previous app must be
# preserved and its path reported, never deleted merely because dest exists.
printf 'original\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
status=0
output="$(env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_MV_FAIL=concurrent \
  bash scripts/install.sh --inner 2>&1)" || status=$?
[ "$status" -ne 0 ] || fail "concurrent destination failure was reported as success"
case "$output" in *"preserved"*) ;; *) fail "preserved previous app path was not reported: $output" ;; esac
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty" 2>/dev/null)" = "foreign" ] || fail "concurrent app was not left in place"
backup_app=""
for candidate in "$home/Applications"/.akitty-backup.*; do
  if [ -e "$candidate/Akitty.app" ]; then backup_app="$candidate/Akitty.app"; fi
done
[ -n "$backup_app" ] || fail "failed install deleted the previous app instead of preserving it"
[ "$(cat "$backup_app/Contents/MacOS/Akitty")" = "original" ] || fail "preserved backup does not hold the previous app"
[ ! -e "$home/Applications/.akitty-install.lock" ] || fail "preserve path did not release its lock"
rm -rf "$home/Applications"/.akitty-backup.*
rm -rf "$home/Applications/Akitty.app"

# rename(2), the restore primitive, must refuse an occupied destination instead
# of nesting inside it.
prim="$root/rename"
mkdir -p "$prim/dest/Akitty.app" "$prim/src/Akitty.app"
printf 'foreign\n' > "$prim/dest/Akitty.app/foreign"
printf 'previous\n' > "$prim/src/Akitty.app/previous"
if /usr/bin/perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' \
  "$prim/src/Akitty.app" "$prim/dest/Akitty.app" 2>/dev/null; then
  fail "rename(2) replaced an occupied destination"
fi
[ ! -e "$prim/dest/Akitty.app/Akitty.app" ] || fail "rename(2) nested the app"
[ -e "$prim/src/Akitty.app/previous" ] || fail "failed rename(2) consumed the source"

# When the destination appears between the existence check and the restore move,
# the restore must fail rather than nest the previous app inside it. The mv shim
# plants a destination at rename time, exactly where the check has already passed.
mkdir -p "$home/Applications/Akitty.app/Contents/MacOS"
printf 'original\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
rm -rf "$home/Applications"/.akitty-backup.*
status=0
output="$(env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_MV_FAIL=staging TEST_MV_RACE=restore \
  bash scripts/install.sh --inner 2>&1)" || status=$?
[ "$status" -ne 0 ] || fail "raced restore failure was reported as success"
[ ! -e "$home/Applications/Akitty.app/Akitty.app" ] || fail "restore nested the app when the destination appeared late: $output"
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty" 2>/dev/null)" = "original" ] || fail "raced restore lost the previous app: $output"
[ ! -e "$home/Applications/.akitty-install.lock" ] || fail "raced restore did not release its lock"
rm -rf "$home/Applications"/.akitty-backup.*

# A signal must terminate the installer instead of resuming it. The installer and
# its sleeping shim share one process group because bash defers a trap until the
# foreground child exits: the group signal reaches both, the handler cleans up and
# re-raises, so the process dies by that signal, the previous app is restored when
# it was not yet replaced, the lock is released, and no success line is printed.
python3 - "$root" "$bin" "$home" "$fixtures" "$PWD" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

root, bin_dir, home, fixtures, repo = (Path(value) for value in sys.argv[1:6])
applications = home / "Applications"
app = applications / "Akitty.app" / "Contents" / "MacOS" / "Akitty"
lock = applications / ".akitty-install.lock"
scenarios = [
    ("SIGTERM before the app is moved", signal.SIGTERM, {"TEST_MV_BLOCK": "staging"}, "original\n"),
    ("SIGTERM while the backup is removed", signal.SIGTERM, {"TEST_RM_BLOCK": "backup"}, "fake\n"),
    ("SIGINT before the app is moved", signal.SIGINT, {"TEST_MV_BLOCK": "staging"}, "original\n"),
    ("SIGINT while the backup is removed", signal.SIGINT, {"TEST_RM_BLOCK": "backup"}, "fake\n"),
]
failures = []
for description, signum, blocks, expected in scenarios:
    for stale in applications.glob(".akitty-*"):
        if stale.is_dir():
            shutil.rmtree(stale, ignore_errors=True)
        else:
            stale.unlink(missing_ok=True)
    app.parent.mkdir(parents=True, exist_ok=True)
    app.write_text("original\n")
    ready = root / "ready"
    ready.unlink(missing_ok=True)
    env = {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "HOME": str(home),
        "TEST_LOG": str(root / "log"),
        "TEST_FIXTURES": str(fixtures),
        "TEST_READY": str(ready),
        **blocks,
    }
    proc = subprocess.Popen(
        ["bash", str(repo / "scripts" / "install.sh"), "--inner"],
        cwd=str(repo),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    deadline = time.time() + 20
    while not ready.exists() and proc.poll() is None and time.time() < deadline:
        time.sleep(0.02)
    if not ready.exists():
        proc.kill()
        proc.communicate()
        failures.append(description + ": the installer never reached the block point")
        continue
    try:
        os.killpg(proc.pid, signum)
    except ProcessLookupError:
        pass
    out, _ = proc.communicate(timeout=20)
    text = out.decode("utf-8", "replace")
    if proc.returncode != -signum:
        failures.append(
            f"{description}: exited {proc.returncode}, not by signal {signum}: {text}"
        )
    if "installed AkiTTY" in text:
        failures.append(description + ": reported success after the signal")
    if lock.exists():
        failures.append(description + ": left its install lock behind")
    actual = app.read_text() if app.exists() else ""
    if actual != expected:
        failures.append(
            f"{description}: app content {actual!r}, expected {expected!r}"
        )
if failures:
    print("signal test failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
PY

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
