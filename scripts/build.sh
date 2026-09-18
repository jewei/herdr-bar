#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/dist/Herdr Bar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
staged_binary="$(mktemp "$app_dir/Contents/MacOS/.HerdrBar.XXXXXX")"
trap 'rm -f "$staged_binary"' EXIT
cp "$binary_dir/HerdrBar" "$staged_binary"
chmod +x "$staged_binary"
mv -f "$staged_binary" "$app_dir/Contents/MacOS/HerdrBar"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier dev.jewei.herdr-bar "$app_dir"
printf 'Built %s\n' "$app_dir"

if [[ "${1:-}" == "--open" ]]; then
    open "$app_dir"
fi
