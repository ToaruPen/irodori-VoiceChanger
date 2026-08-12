#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$repo_root/dist/IrodoriVoiceChanger.app"
contents_path="$app_path/Contents"
swift build --package-path "$repo_root" -c release -Xswiftc -warnings-as-errors
binary_path="$(swift build --package-path "$repo_root" -c release --show-bin-path)"

if [[ -e "$app_path" ]]; then
  rm -rf "$app_path"
fi
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_path/irodori-voicechanger" "$contents_path/MacOS/irodori-voicechanger"
cp "$repo_root/config/Info.plist" "$contents_path/Info.plist"
cp "$repo_root/config/irodori-voicechanger.example.json" \
  "$contents_path/Resources/irodori-voicechanger.example.json"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
