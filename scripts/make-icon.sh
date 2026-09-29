#!/bin/bash
# Render the layers in design/app-icon.html into design/AppIcon.icon.
# Then compile Resources/Assets.car and Resources/AppIcon.icns with actool.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "$chrome" ]] || { printf 'Chrome not found. Set CHROME to a Chrome executable.\n' >&2; exit 1; }
icon="$project_dir/design/AppIcon.icon"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-icon.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$icon/Assets"
for layer in background sheep; do
    image="$icon/Assets/$layer.png"
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --default-background-color=00000000 --window-size=1024,1024 --screenshot="$image" \
        "file://$project_dir/design/app-icon.html#$layer" > /dev/null 2>&1
    [[ "$(sips -g pixelWidth -g pixelHeight "$image" | awk '/pixel/ { print $2 }' | xargs)" == "1024 1024" ]] \
        || { printf 'Chrome did not render a 1024 x 1024 %s layer.\n' "$layer" >&2; exit 1; }
done

# Icon Composer icons require Xcode 26 or later.
mkdir "$work_dir/compiled"
xcrun actool "$icon" --compile "$work_dir/compiled" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$work_dir/partial.plist" > /dev/null
cp "$work_dir/compiled/Assets.car" "$work_dir/compiled/AppIcon.icns" "$project_dir/Resources/"
printf 'Wrote Resources/Assets.car and Resources/AppIcon.icns\n'
