#!/bin/zsh
# Builds NoNotch.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
app=build/NoNotch.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/NoNotch" "$app/Contents/MacOS/NoNotch"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x NoNotch 2>/dev/null || true
  rm -rf /Applications/NoNotch.app
  cp -R "$app" /Applications/NoNotch.app
  open /Applications/NoNotch.app
  echo "Installed /Applications/NoNotch.app"
fi
