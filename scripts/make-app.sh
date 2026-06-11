#!/bin/bash
# Build Ambitick.app from the SwiftPM executable.
# Run on the Mac, from the repo root:  ./scripts/make-app.sh [output-dir]
set -euo pipefail

OUT="${1:-.}"
APP="$OUT/Ambitick.app"

swift build -c release --product AmbitickApp
BIN="$(swift build -c release --show-bin-path)/AmbitickApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Ambitick"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>org.example.ambitick</string>
    <key>CFBundleName</key><string>Ambitick</string>
    <key>CFBundleDisplayName</key><string>Ambitick</string>
    <key>CFBundleExecutable</key><string>Ambitick</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Ambitick reads the active browser tab URL to attribute time to the right task.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Ambitick observes whether the microphone is in use (call detection); it never records audio.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Ambitick talks to your own OpenProject instance, which may be on your local network.</string>
    <!-- v0.1: user-entered OP URLs may be plain http on a LAN/NAS; without
         this exception ATS silently blocks every request from a bundled app. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP"
echo "First run: right-click -> Open (ad-hoc signed), then grant Accessibility."
