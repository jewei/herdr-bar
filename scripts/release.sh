#!/bin/bash
# Builds, signs, and notarizes the release zip. This script does not publish anything.
#
# Requirements:
#   • A "Developer ID Application" signing identity in the Keychain
#   • Notary credentials: xcrun notarytool store-credentials notarytool
#
# Output: dist/HerdrBar-VERSION.zip, with VERSION from Resources/Info.plist.
set -euo pipefail

TEAM_ID="${TEAM_ID:-4L4SS26L9J}"
IDENTITY="${IDENTITY:-Developer ID Application: Jewei Mak ($TEAM_ID)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool}"

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

# The release must contain only committed source.
if [[ -n "$(git status --porcelain -- Sources Resources Package.swift)" ]]; then
    echo "Commit the changes in Sources, Resources, and Package.swift first." >&2
    exit 1
fi

version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
app="dist/Herdr Bar.app"
zip="dist/HerdrBar-$version.zip"

swift test
./scripts/build.sh

echo "▶ Signing with $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --identifier dev.jewei.herdr-bar "$app"

echo "▶ Submitting to the Apple notary service"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
result="$(xcrun notarytool submit "$zip" --keychain-profile "$KEYCHAIN_PROFILE" --team-id "$TEAM_ID" \
    --wait --output-format json)"
status="$(plutil -extract status raw - <<< "$result")"
if [[ "$status" != "Accepted" ]]; then
    id="$(plutil -extract id raw - <<< "$result")"
    echo "Notarization status: $status. Read the log with:" >&2
    echo "  xcrun notarytool log $id --keychain-profile $KEYCHAIN_PROFILE" >&2
    exit 1
fi

# Staple the ticket to the app, so Gatekeeper can check it offline. Then zip the stapled app.
xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

echo "▶ Validating"
codesign --verify --deep --strict --verbose=2 "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

printf 'Notarized %s\nSHA-256: %s\n' "$zip" "$(shasum -a 256 "$zip" | awk '{print $1}')"
