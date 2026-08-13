#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$repo_root/dist/IrodoriVoiceChanger.app"
staging_root="$(mktemp -d /private/tmp/irodori-voicechanger-build.XXXXXX)"
staging_app="$staging_root/IrodoriVoiceChanger.app"
contents_path="$staging_app/Contents"
trap 'rm -rf "$staging_root"' EXIT
swift build --package-path "$repo_root" -c release -Xswiftc -warnings-as-errors
binary_path="$(swift build --package-path "$repo_root" -c release --show-bin-path)"

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_path/irodori-voicechanger" "$contents_path/MacOS/irodori-voicechanger"
cp "$repo_root/config/Info.plist" "$contents_path/Info.plist"
cp "$repo_root/config/irodori-voicechanger.example.json" \
  "$contents_path/Resources/irodori-voicechanger.example.json"
cp "$repo_root/Sources/IrodoriVoiceChangerSmartTurn/Resources/smart-turn-v3.2-cpu.onnx" \
  "$contents_path/Resources/smart-turn-v3.2-cpu.onnx"
cp "$repo_root/Sources/IrodoriVoiceChangerSmartTurn/Resources/PIPECAT-LICENSE.txt" \
  "$contents_path/Resources/PIPECAT-LICENSE.txt"
test -s "$contents_path/Resources/smart-turn-v3.2-cpu.onnx"
test -s "$contents_path/Resources/PIPECAT-LICENSE.txt"
codesign --force --sign - "$staging_app"
codesign --verify --deep --strict "$staging_app"

if [[ -e "$app_path" ]]; then
  rm -rf "$app_path"
fi
mkdir -p "$(dirname "$app_path")"
cp -R "$staging_app" "$app_path"
for _ in {1..10}; do
  xattr -d com.apple.FinderInfo "$app_path" 2>/dev/null || true
  xattr -d com.apple.ResourceFork "$app_path" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$app_path" 2>/dev/null || true
  if codesign --verify --deep --strict "$app_path" 2>/dev/null; then
    exit 0
  fi
  sleep 0.05
done
codesign --verify --deep --strict "$app_path"
