#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${AKITTY_SIGNING_IDENTITY:?Set the Developer ID Application identity or certificate hash}"
: "${AKITTY_NOTARY_PROFILE:?Set the existing notarytool Keychain profile}"
app="$PWD/build/Akitty.app"
[[ -d $app ]] || { echo 'Build the release app first.' >&2; exit 1; }
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
