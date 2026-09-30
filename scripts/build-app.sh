#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/dist/Codex Token Bar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/CodexTokenBar" "$app_dir/Contents/MacOS/CodexTokenBar"
cp Packaging/Info.plist "$app_dir/Contents/Info.plist"
# Copy the unprocessed JSON directly; SwiftPM resource-bundle layouts vary.
cp Sources/TokenBarCore/Resources/prices.json "$app_dir/Contents/Resources/prices.json"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
