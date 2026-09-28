#!/bin/bash
# Builds, signs, and notarizes the release zip. This script does not publish anything.
#
# Requirements:
#   • A "Developer ID Application" signing identity in the Keychain
#   • Notary credentials: xcrun notarytool store-credentials notarytool
#
# Output: dist/HerdrBar-VERSION-ARCH.zip and its source/build manifest.
set -euo pipefail

TEAM_ID="${TEAM_ID:-4L4SS26L9J}"
IDENTITY="${IDENTITY:-Developer ID Application: Jewei Mak ($TEAM_ID)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool}"

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

# Require a clean repository, including tests, scripts, and untracked source.
# Git's normal ignore rules keep build products (.build/, dist/, etc.) out.
source_status="$(git status --porcelain --untracked-files=all --ignore-submodules=none)"
if [[ -n "$source_status" ]]; then
    echo "Commit or remove all tracked and untracked source-tree changes before releasing:" >&2
    printf '%s\n' "$source_status" >&2
    exit 1
fi

source_commit="$(git rev-parse HEAD)"
release_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-release.XXXXXX")"
artifact_stage=""
promotion_started=false
promotion_complete=false
cleanup() {
    local status=$? suffix failed=false
    if [[ "$promotion_started" == true && "$promotion_complete" != true ]]; then
        for suffix in zip json sha256; do
            if [[ -f "$artifact_stage/previous/$artifact.$suffix" ]]; then
                mv -f "$artifact_stage/previous/$artifact.$suffix" "$project_dir/dist/$artifact.$suffix" || failed=true
            else
                rm -f "$project_dir/dist/$artifact.$suffix" || failed=true
            fi
        done
    fi
    rm -rf "$release_dir"
    if [[ "$failed" == true ]]; then
        printf 'Could not restore release records. Backup retained at %s\n' "$artifact_stage" >&2
        exit 1
    fi
    if [[ -n "$artifact_stage" ]]; then rm -rf "$artifact_stage"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
source_dir="$release_dir/source"
mkdir -p "$source_dir"
# Tests, scripts, resources, and sources all come from the same immutable commit.
git archive "$source_commit" | tar -x -C "$source_dir"
version="$(plutil -extract CFBundleShortVersionString raw "$source_dir/Resources/Info.plist")"
build_number="$(plutil -extract CFBundleVersion raw "$source_dir/Resources/Info.plist")"
tag="${1:-v$version}"
if [[ "$tag" != "v$version" || "$#" -gt 1 ]]; then
    echo "Usage: scripts/release.sh [v$version] (must match the bundle version)" >&2
    exit 1
fi
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    if [[ "$(git rev-parse "refs/tags/$tag^{commit}")" != "$source_commit" ]]; then
        echo "The release tag $tag points to another commit. Increase the bundle version." >&2
        exit 1
    fi
fi
previous_tag="$(git describe --tags --match 'v[0-9]*' --abbrev=0 "$source_commit^" 2>/dev/null || true)"
if [[ -n "$previous_tag" ]]; then
    git show "$previous_tag:Resources/Info.plist" > "$release_dir/previous.plist"
    previous_build="$(plutil -extract CFBundleVersion raw "$release_dir/previous.plist")"
    if [[ ! "$build_number" =~ ^[1-9][0-9]*$ || "$build_number" -le "$previous_build" ]]; then
        echo "The build number must be greater than $previous_build from $previous_tag." >&2
        exit 1
    fi
fi

cd "$source_dir"
app="dist/Herdr Bar.app"

swift test
./scripts/build.sh
architecture="$(python3 scripts/verify-bundle.py "$app" Resources/Info.plist)"
artifact="HerdrBar-$version-$architecture"
zip="dist/$artifact.zip"

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

python3 - "$zip" "$source_commit" "$tag" "$architecture" <<'PY'
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

archive, revision, tag, architecture = sys.argv[1:]
archive = Path(archive)
with Path("Resources/Info.plist").open("rb") as stream:
    metadata = plistlib.load(stream)
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
manifest = {
    "source_commit": revision,
    "tag": tag,
    "version": metadata["CFBundleShortVersionString"],
    "build_number": metadata["CFBundleVersion"],
    "minimum_macos": metadata["LSMinimumSystemVersion"],
    "architecture": architecture,
    "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "artifact": archive.name,
    "sha256": checksum,
    "notarized": True,
}
archive.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
archive.with_suffix(".sha256").write_text(f"{checksum}  {archive.name}\n")
PY
mkdir -p "$project_dir/dist"
artifact_stage="$(mktemp -d "$project_dir/dist/.HerdrBar-release.XXXXXX")"
mkdir -p "$artifact_stage/new" "$artifact_stage/previous"
for suffix in zip json sha256; do
    cp "dist/$artifact.$suffix" "$artifact_stage/new/$artifact.$suffix"
    if [[ -e "$project_dir/dist/$artifact.$suffix" ]]; then
        cp -p "$project_dir/dist/$artifact.$suffix" "$artifact_stage/previous/$artifact.$suffix"
    fi
done
# Restore the entire previous set if any promotion step or handled signal fails.
promotion_started=true
for suffix in zip json sha256; do
    mv -f "$artifact_stage/new/$artifact.$suffix" "$project_dir/dist/$artifact.$suffix"
done
promotion_complete=true
printf 'Notarized %s/dist/%s.zip\n' "$project_dir" "$artifact"
cat "$project_dir/dist/$artifact.sha256"
