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
# Sign with a self-signed "Screen Answers Signing" certificate if you've made one
# (Keychain Access → Certificate Assistant → Create a Certificate, type Code Signing).
# That keeps the app's identity stable, so Screen Recording permission survives rebuilds.
# Without it, the app is ad-hoc signed and permission must be granted again after each build.
if security find-identity -p codesigning | grep -q "Screen Answers Signing"; then
  codesign --force --sign "Screen Answers Signing" "$APP"
  echo "Signed with Screen Answers Signing certificate"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (re-grant Screen Recording permission after this build)"
fi
echo "Built $(pwd)/$APP"
