#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
app_dir="$project_dir/dist/Herdr Bar.app"
mkdir -p "$project_dir/dist"
# Stage the entire bundle on the destination filesystem; never reuse old resources.
staging_dir="$(mktemp -d "$project_dir/dist/.HerdrBar-stage.XXXXXX")"
staged_app="$staging_dir/Herdr Bar.app"
previous_app="$staging_dir/previous.app"
cleanup() {
    local status=$?
    # Restore the last bundle if promotion failed after moving it aside.
    if [[ -e "$previous_app" && ! -e "$app_dir" ]]; then
        if ! mv "$previous_app" "$app_dir"; then
            printf 'Could not restore previous bundle; preserved at %s\n' "$previous_app" >&2
            exit 1
        fi
    fi
    rm -rf "$staging_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_dir/HerdrBar" "$staged_app/Contents/MacOS/HerdrBar"
chmod +x "$staged_app/Contents/MacOS/HerdrBar"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/Assets.car "$staged_app/Contents/Resources/"
codesign --force --sign - --identifier dev.jewei.herdr-bar "$staged_app"
codesign --verify --deep --strict "$staged_app"

# Only replace the existing app after all build, copy, and signing steps succeed.
if [[ -e "$app_dir" ]]; then
    mv "$app_dir" "$previous_app"
fi
mv "$staged_app" "$app_dir"
printf 'Built %s\n' "$app_dir"

if [[ "${1:-}" == "--open" ]]; then
    open "$app_dir"
fi
