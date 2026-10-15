#!/bin/bash
# Builds ScreenAnswers.app next to this script.
set -e
cd "$(dirname "$0")"
APP="ScreenAnswers.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/ScreenAnswers"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Screen Answers</string>
  <key>CFBundleDisplayName</key><string>Screen Answers</string>
  <key>CFBundleIdentifier</key><string>com.coopercohen.screenanswers2</string>
  <key>CFBundleExecutable</key><string>ScreenAnswers</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
# Note: each rebuild changes the app's signature, so macOS needs Screen Recording
# permission granted again afterwards (tccutil reset ScreenCapture com.coopercohen.screenanswers2).
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
