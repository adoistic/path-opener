#!/bin/zsh
# Builds "Path Opener.app" and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Path Opener.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement \
  Sources/*.swift -o "$APP/Contents/MacOS/PathOpener"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Path Opener</string>
  <key>CFBundleDisplayName</key><string>Path Opener</string>
  <key>CFBundleIdentifier</key><string>com.thothica.pathopener</string>
  <key>CFBundleExecutable</key><string>PathOpener</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep -s - "$APP"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x PathOpener 2>/dev/null || true
  rm -rf "/Applications/Path Opener.app"
  cp -R "$APP" /Applications/
  open "/Applications/Path Opener.app"
  echo "Installed and launched /Applications/Path Opener.app"
fi
