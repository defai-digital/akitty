#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${AKITTY_SIGNING_IDENTITY:?Set the Developer ID Application identity or certificate hash}"
: "${AKITTY_NOTARY_PROFILE:?Set the existing notarytool Keychain profile}"
app="$PWD/build/Akitty.app"
[[ -d $app ]] || { echo 'Build the release app first.' >&2; exit 1; }
# Refuse to sign a bundle whose build stamp does not match the source we are
# releasing: signing a stale binary would mislabel it with a new commit.
python3 - "$app" <<'PYSTAMP'
import json, pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()
path = app / 'Contents/Resources/akitty-build.json'
if not path.is_file():
    raise SystemExit('App bundle has no build stamp; rebuild with scripts/build-app.sh release')
try:
    stamp = json.loads(path.read_text())
except json.JSONDecodeError:
    raise SystemExit('App bundle build stamp is not valid JSON')
if not isinstance(stamp, dict) or stamp.get('schema') != 1:
    raise SystemExit('App bundle build stamp is unsupported')
if stamp.get('commit') != git('rev-parse', 'HEAD'):
    raise SystemExit('App bundle was built from another commit; rebuild from the release commit')
if stamp.get('dirty') is not False:
    raise SystemExit('App bundle was built from a dirty tree; commit and rebuild it')
if stamp.get('configuration') != 'release':
    raise SystemExit('Notarization requires a release build')
if git('status', '--porcelain'):
    raise SystemExit('Working tree changed since the bundle was built; rebuild from the clean commit')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if stamp.get('version') != info.get('CFBundleShortVersionString') or str(stamp.get('build')) != str(info.get('CFBundleVersion')):
    raise SystemExit('App bundle version does not match its build stamp')
print('Build stamp verified:', str(stamp['commit'])[:12], 'build', stamp['build'])
PYSTAMP
mkdir -p .internal/release
# Sign Sparkle's helper code from the inside out, preserving helper entitlements.
framework="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$framework" ]]; then
    codesign --force --options runtime --preserve-metadata=entitlements --sign "$AKITTY_SIGNING_IDENTITY" --timestamp "$framework/Versions/B/Autoupdate"
    while IFS= read -r -d '' helper; do
        codesign --force --options runtime --preserve-metadata=entitlements --sign "$AKITTY_SIGNING_IDENTITY" --timestamp "$helper"
    done < <(find "$framework/Versions/B" -depth -type d \( -name '*.xpc' -o -name '*.app' \) -print0)
    codesign --force --options runtime --sign "$AKITTY_SIGNING_IDENTITY" --timestamp "$framework"
fi
codesign --force --options runtime --entitlements macos/Release.entitlements --sign "$AKITTY_SIGNING_IDENTITY" --timestamp "$app"
codesign --verify --deep --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" .internal/release/Akitty-submit.zip
xcrun notarytool submit .internal/release/Akitty-submit.zip --keychain-profile "$AKITTY_NOTARY_PROFILE" --wait --output-format json > .internal/release/notary.json
python3 - <<'PY'
import json
from pathlib import Path
result=json.loads(Path('.internal/release/notary.json').read_text())
if result.get('status') != 'Accepted': raise SystemExit('Notarization was not accepted; see private receipt.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --keepParent "$app" build/Akitty-macOS.zip
shasum -a 256 build/Akitty-macOS.zip > build/SHA256SUMS
