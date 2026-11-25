#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

swift build --configuration release --product meeting-assistant
binary_dir="$(swift build --configuration release --show-bin-path)"
app_dir="$project_dir/dist/MeetingAssistant.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/meeting-assistant" "$app_dir/Contents/MacOS/meeting-assistant"
cp "$project_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
echo "$app_dir"
