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
if [ "${TEST_STAGING_GONE:-}" = 1 ]; then
  # Drop the staged app after it passes assessment, so the final rename(2) fails
  # on a missing source once the old app has already been moved to backup.
  for arg in "$@"; do
    case "$arg" in
      */.akitty-install.*/Akitty.app) /bin/rm -rf "$arg" ;;
    esac
  done
fi
exit "${TEST_SPCTL:-0}"
SH
shim mv <<'SH'
#!/bin/bash
printf 'mv %s\n' "$*" >> "$TEST_LOG"
# The only mv left in install.sh moves the existing app into its backup; the
# final install and the restore both use rename(2), which a PATH shim cannot
# intercept, so failures after the backup are forced through other shims.
case "${TEST_MV_BLOCK:-}" in
  backup)
    case "${2:-}" in
      */.akitty-backup.*/Akitty.app)
        : > "$TEST_READY"
        sleep 30
        echo "mv shim: blocked backup move interrupted" >&2; exit 143 ;;
    esac
    ;;
esac
case "${TEST_MV_RACE:-}" in
  install)
    # Move the old app to the backup first, then plant a foreign destination, so
    # the destination exists exactly when the staging app is moved into place.
    case "${2:-}" in
      */.akitty-backup.*/Akitty.app)
        /bin/mv "$@" || exit $?
        mkdir -p "$HOME/Applications/Akitty.app/Contents/MacOS"
        printf 'foreign\n' > "$HOME/Applications/Akitty.app/Contents/MacOS/Akitty"
        exit 0 ;;
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

# A lock this process owns (its owner file names $$) is removed normally.
bash -c '
  . "$1"
  path="$2/normal"
  lock=""; lock_owned="$path"
  mkdir "$path"
  printf "%s\n" "$$" > "$path/owner"
  release_lock
  [ ! -e "$path" ] && [ -z "$lock_owned$lock" ] || exit 1
' _ "$root/release-lock.sh" "$root/lock-test" \
  || fail "normal owner lock cleanup kept a lock it owns"

# A lock whose owner file names another process must be preserved: the lock path
# was removed and recreated by a replacement installer while this one was still
# running, so deleting it would clear a live foreign lock.
bash -c '
  . "$1"
  path="$2/replaced"
  lock=""; lock_owned="$path"
  mkdir "$path"
  printf "%s\n" "4242" > "$path/owner"
  release_lock
  [ -d "$path" ] || exit 1
  [ "$(cat "$path/owner")" = "4242" ] || exit 1
  [ -z "$lock_owned$lock" ] || exit 1
' _ "$root/release-lock.sh" "$root/lock-test" \
  || fail "replacement owner lock was removed or kept as locally owned"

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
# spctl drops the staged app, so the final rename(2) fails after the backup move.
printf 'original\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
rm -f "$pidfile"
status=0
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_PIDFILE="$pidfile" TEST_STAGING_GONE=1 \
  bash -c 'echo $$ > "$TEST_PIDFILE"; mkdir -p "$HOME/Applications/.akitty-backup.$$"; printf "sentinel\n" > "$HOME/Applications/.akitty-backup.$$/sentinel"; exec bash scripts/install.sh --inner' \
  >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "forced final-move failure was reported as success"
pid="$(cat "$pidfile")"
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty" 2>/dev/null)" = "original" ] || fail "failed install did not restore the original app"
[ -e "$home/Applications/.akitty-backup.$pid/sentinel" ] || fail "rollback deleted a preexisting backup collision"
[ ! -e "$home/Applications/Akitty.app/Akitty.app" ] || fail "rollback restored a nested app"

# A failure while deleting staging must not abort cleanup before the previous app
# is restored: restore runs first and the later removals are best-effort.
printf 'original\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
status=0
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_STAGING_GONE=1 TEST_RM_FAIL=staging \
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
  TEST_STAGING_GONE=1 TEST_MV_RACE=install \
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

# A final-move failure with a free destination must restore the previous app
# rather than leave it in the backup. The restore primitive's refusal of an
# occupied destination is covered by the rename(2) test above.
mkdir -p "$home/Applications/Akitty.app/Contents/MacOS"
printf 'original\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
rm -rf "$home/Applications"/.akitty-backup.*
status=0
output="$(env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_STAGING_GONE=1 \
  bash scripts/install.sh --inner 2>&1)" || status=$?
[ "$status" -ne 0 ] || fail "failed final move was reported as success"
[ ! -e "$home/Applications/Akitty.app/Akitty.app" ] || fail "restore nested the app: $output"
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty" 2>/dev/null)" = "original" ] || fail "failed final move did not restore the previous app: $output"
[ ! -e "$home/Applications/.akitty-install.lock" ] || fail "failed final move did not release its lock"
rm -rf "$home/Applications"/.akitty-backup.*

# The final move into place must not nest the app when the destination appears
# after the old app was moved to backup. The mv shim performs the backup move and
# then plants a foreign destination, so the destination exists exactly when the
# staging app is moved into place. /bin/mv would nest the app inside it, report
# success and let the original backup be deleted; rename(2) must fail instead.
mkdir -p "$home/Applications/Akitty.app/Contents/MacOS"
printf 'original\n' > "$home/Applications/Akitty.app/Contents/MacOS/Akitty"
rm -rf "$home/Applications"/.akitty-backup.* "$home/Applications"/.akitty-install.*
status=0
output="$(env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_FIXTURES="$fixtures" \
  TEST_MV_RACE=install \
  bash scripts/install.sh --inner 2>&1)" || status=$?
[ "$status" -ne 0 ] || fail "raced install move was reported as success: $output"
case "$output" in *"cannot move the app into"*) ;; *) fail "raced install move was not reported: $output" ;; esac
[ ! -e "$home/Applications/Akitty.app/Akitty.app" ] || fail "install nested the app inside a raced destination: $output"
[ "$(cat "$home/Applications/Akitty.app/Contents/MacOS/Akitty" 2>/dev/null)" = "foreign" ] || fail "raced install did not preserve the foreign destination: $output"
backup_app=""
for candidate in "$home/Applications"/.akitty-backup.*; do
  if [ -e "$candidate/Akitty.app" ]; then backup_app="$candidate/Akitty.app"; fi
done
[ -n "$backup_app" ] || fail "raced install deleted the original backup"
[ "$(cat "$backup_app/Contents/MacOS/Akitty")" = "original" ] || fail "raced install lost the original app from the backup"
[ ! -e "$home/Applications/.akitty-install.lock" ] || fail "raced install did not release its lock"
rm -rf "$home/Applications"/.akitty-backup.*
rm -rf "$home/Applications/Akitty.app"

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
    ("SIGTERM before the app is moved", signal.SIGTERM, {"TEST_MV_BLOCK": "backup"}, "original\n"),
    ("SIGTERM while the backup is removed", signal.SIGTERM, {"TEST_RM_BLOCK": "backup"}, "fake\n"),
    ("SIGINT before the app is moved", signal.SIGINT, {"TEST_MV_BLOCK": "backup"}, "original\n"),
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

# Entry mode: a signal sent only to the entry PID must stop the inner installer
# instead of letting it finish. The fake inner records its PID and readiness,
# installs INT/TERM traps, then sleeps before writing a completion marker and the
# success line. The entry must forward the signal, reap the child, clean up, and
# die by the same signal, so the child never completes and nothing is installed.
python3 - "$root" "$bin" "$home" "$fixtures" "$PWD" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root, bin_dir, home, fixtures, repo = (Path(value) for value in sys.argv[1:6])
base_env = {
    "PATH": f"{bin_dir}:{os.environ['PATH']}",
    "HOME": str(home),
    "TEST_LOG": str(root / "log"),
    "TEST_FIXTURES": str(fixtures),
}
failures = []
for signame, signum in (("INT", signal.SIGINT), ("TERM", signal.SIGTERM)):
    inner = root / f"entry-inner-{signame}.sh"
    child_pid_file = root / f"entry-child-{signame}.pid"
    ready = root / f"entry-ready-{signame}"
    done = root / f"entry-done-{signame}"
    for path in (child_pid_file, ready, done):
        path.unlink(missing_ok=True)
    inner.write_text(
        "#!/bin/bash\n"
        "printf '%s\\n' \"$$\" > '" + str(child_pid_file) + "'\n"
        ": > '" + str(ready) + "'\n"
        "trap 'exit 130' INT\n"
        "trap 'exit 143' TERM\n"
        "sleep 2\n"
        ": > '" + str(done) + "'\n"
        "printf 'installed AkiTTY fake\\n'\n"
    )
    proc = subprocess.Popen(
        ["bash", str(repo / "scripts" / "install.sh")],
        cwd=str(repo),
        env={**base_env, "TEST_SCRIPT": str(inner)},
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
        failures.append(f"SIG{signame}: the entry never started the inner installer")
        continue
    try:
        os.kill(proc.pid, signum)  # only the entry PID, never the child
    except ProcessLookupError:
        pass
    timed_out = False
    try:
        out, _ = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
        timed_out = True
    text = out.decode("utf-8", "replace") if out else ""
    if timed_out:
        failures.append(f"SIG{signame} to the entry only: the entry did not exit")
    elif proc.returncode != -signum:
        failures.append(
            f"SIG{signame} to the entry only: exited {proc.returncode}, "
            f"not by signal {signum}: {text}"
        )
    if "installed AkiTTY" in text:
        failures.append(f"SIG{signame} to the entry only: the inner installer reported success")
    if done.exists():
        failures.append(f"SIG{signame} to the entry only: the inner installer ran to completion")
    child = child_pid_file.read_text().strip() if child_pid_file.exists() else ""
    if not child:
        failures.append(f"SIG{signame} to the entry only: the inner installer never started")
    else:
        try:
            os.kill(int(child), 0)
        except ProcessLookupError:
            pass
        else:
            failures.append(f"SIG{signame} to the entry only: left the inner installer running")
if failures:
    print("entry signal test failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
PY

# Entry mode: the inner installer's exit status is propagated verbatim, so a
# failed install is never flattened into success by the wrapper.
printf '#!/bin/bash\nexit 7\n' > "$root/exit7.sh"
status=0
env PATH="$bin:$PATH" HOME="$home" TEST_LOG="$root/log" TEST_SCRIPT="$root/exit7.sh" \
  bash scripts/install.sh >/dev/null 2>&1 || status=$?
[ "$status" -eq 7 ] || fail "entry mode did not propagate the inner exit status (got $status, expected 7)"

# The spawn window is the only place a termination can arrive after the inner
# installer is forked but before its PID is recorded. Drive the production
# on_signal/finalize_deferred_signal pair directly, with inner_acquiring set and
# inner_pid still empty: the signal must only be recorded (the running child is
# left alone), and finalizing after inner_pid is assigned must go through
# on_signal so that child is stopped too. The child writes its marker from its
# own trap, which makes both halves observable.
python3 - "$root" "$PWD" <<'PY'
from pathlib import Path
import signal
import subprocess
import sys

root, repo = (Path(value) for value in sys.argv[1:3])
unit = root / "signal-unit"
unit.mkdir(parents=True, exist_ok=True)
# Only the two signal functions are under test; cleanup is owned by the EXIT
# trap in production, so the harness stubs it out.
source = (repo / "scripts" / "install.sh").read_text()
start = source.index("on_signal() {")
end = source.index("trap cleanup EXIT")
(unit / "fns.sh").write_text(source[start:end])
(unit / "child.sh").write_text(
    "#!/bin/bash\n"
    "trap 'echo signaled > \"$MARKER\"; exit 0' TERM\n"
    ": > \"$READY\"\n"
    "while :; do sleep 0.05; done\n"
)
(unit / "harness.sh").write_text(
    "#!/bin/bash\n"
    '. "$1"\n'
    "cleanup() { :; }\n"
    'lock_acquiring=0 deferred_signal=""\n'
    'lock="" lock_owned="" staging="" zip="" work="" backup="" dest="" entry_dest=""\n'
    'MARKER="$2/child"; READY="$2/ready"; export MARKER READY\n'
    "inner_acquiring=1\n"
    'bash "$2/child.sh" &\n'
    "child_pid=$!\n"
    'inner_pid=""                        # the window: forked, PID not recorded\n'
    "# Wait for the child's trap: the default disposition would kill it early.\n"
    "i=0\n"
    'while [ ! -e "$READY" ] && [ "$i" -lt 250 ]; do sleep 0.02; i=$((i + 1)); done\n'
    '[ -e "$READY" ] || exit 5\n'
    "on_signal TERM\n"
    '[ "$deferred_signal" = "TERM" ] || exit 2\n'
    'kill -0 "$child_pid" 2>/dev/null || exit 3\n'
    'printf recorded > "$2/recorded"\n'
    'inner_pid="$child_pid"              # the assignment the window waited for\n'
    "inner_acquiring=0\n"
    "finalize_deferred_signal\n"
    "exit 4                              # finalize terminates by TERM\n"
)
try:
    proc = subprocess.run(
        ["bash", str(unit / "harness.sh"), str(unit / "fns.sh"), str(unit)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=60,
    )
    rc = proc.returncode
    text = proc.stdout.decode("utf-8", "replace")
except subprocess.TimeoutExpired:
    rc, text = None, "the harness hung (an unbounded wait?)"
failures = []
if rc != -signal.SIGTERM:
    reasons = {
        2: "recorded the signal but did not defer it",
        3: "acted on the signal before inner_pid was assigned",
        4: "finalize returned instead of terminating",
        5: "the harness child never became ready",
    }
    failures.append(
        f"exit {rc} (expected death by SIGTERM): {reasons.get(rc, 'unexpected')}: {text}"
    )
if not (unit / "recorded").exists():
    failures.append("a signal during the inner spawn was not deferred while inner_pid was unknown")
if not (unit / "child").exists():
    failures.append("finalizing the deferred signal did not signal the inner child")
if failures:
    print("deferred entry signal test failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
PY

# Entry mode: an inner installer that ignores INT/TERM must still be stopped. The
# entry forwards the signal, waits only a bounded grace period, then escalates to
# SIGKILL and reaps, so the entry exits instead of hanging and the install can
# never complete after the entry is gone. A child killed that way never runs its
# own EXIT trap, so the entry must also drop the destination lock such a child
# created -- but only when the lock's owner file names exactly that dead PID. A
# lock with another owner or no owner, and unrelated staging/backup directories,
# must be kept.
python3 - "$root" "$bin" "$home" "$fixtures" "$PWD" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

root, bin_dir, home, fixtures, repo = (Path(value) for value in sys.argv[1:6])
base_env = {
    "PATH": f"{bin_dir}:{os.environ['PATH']}",
    "HOME": str(home),
    "TEST_LOG": str(root / "log"),
    "TEST_FIXTURES": str(fixtures),
}
applications = home / "Applications"
lock_dir = applications / ".akitty-install.lock"
owner_file = lock_dir / "owner"
failures = []
for signame, signum in (("INT", signal.SIGINT), ("TERM", signal.SIGTERM)):
    for lock_mode in ("own", "foreign", "missing"):
        label = f"SIG{signame} with a {lock_mode}-owner lock"
        inner = root / f"stubborn-inner-{signame}-{lock_mode}.sh"
        child_pid_file = root / f"stubborn-child-{signame}-{lock_mode}.pid"
        ready = root / f"stubborn-ready-{signame}-{lock_mode}"
        done = root / f"stubborn-done-{signame}-{lock_mode}"
        for path in (child_pid_file, ready, done):
            path.unlink(missing_ok=True)
        # Unrelated destination state that the entry's cleanup must leave alone.
        staging = applications / ".akitty-install.TESTSTAGE"
        backup = applications / ".akitty-backup.TESTBACKUP"
        for extra in (staging, backup):
            extra.mkdir(parents=True, exist_ok=True)
            (extra / "sentinel").write_text("keep\n")
        # Start with no lock, then let the inner create the one under test.
        shutil.rmtree(lock_dir, ignore_errors=True)
        owner_write = ""
        if lock_mode == "own":
            owner_write = "printf '%s\\n' \"$$\" > '" + str(owner_file) + "'\n"
        elif lock_mode == "foreign":
            owner_write = "printf '4242\\n' > '" + str(owner_file) + "'\n"
        inner.write_text(
            "#!/bin/bash\n"
            "printf '%s\\n' \"$$\" > '" + str(child_pid_file) + "'\n"
            # Model the inner installer's own acquire_lock: the lock names its PID.
            "mkdir -p '" + str(lock_dir) + "'\n"
            + owner_write
            # Ignore the forwarded signal, the way a stuck inner installer would.
            + "trap '' INT TERM\n"
            ": > '" + str(ready) + "'\n"
            "while :; do sleep 1; done\n"
            ": > '" + str(done) + "'\n"
            "printf 'installed AkiTTY fake\\n'\n"
        )
        proc = subprocess.Popen(
            ["bash", str(repo / "scripts" / "install.sh")],
            cwd=str(repo),
            env={**base_env, "TEST_SCRIPT": str(inner)},
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
            failures.append(f"{label}: the entry never started the stubborn inner installer")
            continue
        started = time.time()
        try:
            os.kill(proc.pid, signum)  # only the entry PID, never the child
        except ProcessLookupError:
            pass
        timed_out = False
        try:
            out, _ = proc.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, _ = proc.communicate()
            timed_out = True
        elapsed = time.time() - started
        text = out.decode("utf-8", "replace") if out else ""
        if timed_out:
            failures.append(f"{label}: the entry hung waiting for a child that ignores the signal")
        elif proc.returncode != -signum:
            failures.append(
                f"{label}: exited {proc.returncode}, not by signal {signum}: {text}"
            )
        # The grace window is ~5s, then SIGKILL: long enough to be a real wait,
        # short enough to prove the escalation happened.
        if not 3 <= elapsed <= 25:
            failures.append(f"{label}: the graceful wait was not bounded (~{elapsed:.1f}s)")
        if "installed AkiTTY" in text:
            failures.append(f"{label}: the inner installer reported success")
        if done.exists():
            failures.append(f"{label}: the inner installer ran to completion")
        child = child_pid_file.read_text().strip() if child_pid_file.exists() else ""
        if not child:
            failures.append(f"{label}: the stubborn inner installer never started")
        else:
            try:
                os.kill(int(child), 0)
            except ProcessLookupError:
                pass
            else:
                failures.append(f"{label}: left the stubborn inner installer running")
        # The entry must clear only the lock whose owner names the dead inner PID.
        if lock_mode == "own":
            if lock_dir.exists():
                failures.append(f"{label}: left the dead inner's install lock behind")
        elif lock_mode == "foreign":
            if not lock_dir.is_dir():
                failures.append(f"{label}: removed a lock owned by another process")
            elif not owner_file.exists() or owner_file.read_text() != "4242\n":
                failures.append(f"{label}: rewrote a lock owned by another process")
        elif not lock_dir.exists():
            failures.append(f"{label}: removed a lock with no owner file")
        for extra, kind in ((staging, "staging directory"), (backup, "backup directory")):
            if not extra.is_dir() or not (extra / "sentinel").exists():
                failures.append(f"{label}: removed an unrelated {kind}")
if failures:
    print("stubborn entry signal test failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
PY

# Entry mode: an inner killed by a killer outside the entry (SIGKILL sent
# straight to its PID, so the entry is never signalled) never runs its own EXIT
# trap, and wait reports 128+N instead of going through on_signal. The entry must
# release a destination lock whose owner names exactly that dead child before it
# propagates the status, or every later install into the same destination is
# blocked by a dead owner. A lock with another owner or no owner file must still
# be kept, exactly as on the on_signal escalation path.
python3 - "$root" "$bin" "$home" "$fixtures" "$PWD" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

root, bin_dir, home, fixtures, repo = (Path(value) for value in sys.argv[1:6])
base_env = {
    "PATH": f"{bin_dir}:{os.environ['PATH']}",
    "HOME": str(home),
    "TEST_LOG": str(root / "log"),
    "TEST_FIXTURES": str(fixtures),
}
applications = home / "Applications"
lock_dir = applications / ".akitty-install.lock"
owner_file = lock_dir / "owner"
app = applications / "Akitty.app" / "Contents" / "MacOS" / "Akitty"
failures = []
for lock_mode in ("own", "foreign", "missing"):
    label = f"SIGKILL of the inner with a {lock_mode}-owner lock"
    inner = root / f"killed-inner-{lock_mode}.sh"
    child_pid_file = root / f"killed-child-{lock_mode}.pid"
    ready = root / f"killed-ready-{lock_mode}"
    for path in (child_pid_file, ready):
        path.unlink(missing_ok=True)
    if lock_dir.is_dir():
        shutil.rmtree(lock_dir, ignore_errors=True)
    elif lock_dir.exists():
        lock_dir.unlink()
    if (applications / "Akitty.app").is_dir():
        shutil.rmtree(applications / "Akitty.app", ignore_errors=True)
    owner_write = ""
    if lock_mode == "own":
        owner_write = "printf '%s\\n' \"$$\" > '" + str(owner_file) + "'\n"
    elif lock_mode == "foreign":
        owner_write = "printf '4242\\n' > '" + str(owner_file) + "'\n"
    inner.write_text(
        "#!/bin/bash\n"
        "printf '%s\\n' \"$$\" > '" + str(child_pid_file) + "'\n"
        # Hold the destination lock exactly as the inner's own acquire_lock does.
        "mkdir -p '" + str(lock_dir) + "'\n"
        + owner_write
        + ": > '" + str(ready) + "'\n"
        "while :; do sleep 1; done\n"
    )
    proc = subprocess.Popen(
        ["bash", str(repo / "scripts" / "install.sh")],
        cwd=str(repo),
        env={**base_env, "TEST_SCRIPT": str(inner)},
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
        failures.append(f"{label}: the entry never started the inner installer")
        continue
    child = child_pid_file.read_text().strip() if child_pid_file.exists() else ""
    if not child:
        proc.kill()
        proc.communicate()
        failures.append(f"{label}: the inner installer never recorded its PID")
        continue
    # The lock must really be held before the kill, or the release assertion
    # below would be vacuous.
    if not lock_dir.is_dir():
        failures.append(f"{label}: the inner never created its destination lock")
    elif lock_mode == "own":
        if not owner_file.exists() or owner_file.read_text().strip() != child:
            failures.append(f"{label}: the inner did not record itself as the lock owner")
    elif lock_mode == "foreign":
        if not owner_file.exists() or owner_file.read_text() != "4242\n":
            failures.append(f"{label}: the inner did not record the foreign lock owner")
    elif owner_file.exists():
        failures.append(f"{label}: the owner-less lock unexpectedly has an owner file")
    # The inner PID only: the entry keeps running and is never signalled, so its
    # own on_signal/release_escalated_lock escalation path cannot run here.
    try:
        os.kill(int(child), signal.SIGKILL)
    except ProcessLookupError:
        pass
    timed_out = False
    try:
        out, _ = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
        timed_out = True
    text = out.decode("utf-8", "replace") if out else ""
    expected_status = 128 + signal.SIGKILL
    if timed_out:
        failures.append(f"{label}: the entry did not exit after the inner was killed")
    elif proc.returncode != expected_status:
        failures.append(
            f"{label}: the entry exited {proc.returncode}, not the child status "
            f"{expected_status}: {text}"
        )
    if "installed AkiTTY" in text:
        failures.append(f"{label}: the inner installer reported success")
    if lock_mode == "own":
        if lock_dir.exists():
            failures.append(f"{label}: left the dead inner's install lock behind")
        else:
            # The whole point: a later install must not be blocked by the dead owner.
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
                    f"{label}: the follow-up install failed ({follow.returncode}): "
                    + follow.stdout.decode("utf-8", "replace")
                )
            elif not app.exists() or lock_dir.exists():
                failures.append(f"{label}: the follow-up install did not complete cleanly")
    elif lock_mode == "foreign":
        if not lock_dir.is_dir():
            failures.append(f"{label}: removed a lock owned by another process")
        elif not owner_file.exists() or owner_file.read_text() != "4242\n":
            failures.append(f"{label}: rewrote a lock owned by another process")
    elif not lock_dir.exists():
        failures.append(f"{label}: removed a lock with no owner file")
    shutil.rmtree(lock_dir, ignore_errors=True)
    if (applications / "Akitty.app").is_dir():
        shutil.rmtree(applications / "Akitty.app", ignore_errors=True)
if failures:
    print("externally killed inner test failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
PY

echo "installer tests passed"
