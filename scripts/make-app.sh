#!/bin/bash
# Build Ambitick.app from the SwiftPM executable.
# Run on the Mac, from the repo root:  ./scripts/make-app.sh [output-dir]
set -euo pipefail

OUT="${1:-.}"
APP="$OUT/Ambitick.app"
# Never replace a RUNNING app in place - macOS may kill it mid-execution
# (the "menu bar icon disappeared" deaths). Stage beside it instead.
if pgrep -xq Ambitick; then
    APP="$OUT/Ambitick+.app"
    echo "NOTE: Ambitick is running; building to $APP - quit the old one and rename to swap."
fi

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
    <key>CFBundleVersion</key><string>BUILD_STAMP</string>
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

# Stamp the build time into CFBundleVersion so the running app can show exactly
# which build it is (Settings → About). Must run before signing.
BUILD_STAMP="$(date '+%Y-%m-%d %H:%M')"
/usr/bin/sed -i '' "s/BUILD_STAMP/$BUILD_STAMP/" "$APP/Contents/Info.plist"

# Stable signing identity: ad-hoc signing changes the app's identity every
# build, which silently invalidates TCC grants (Accessibility, Automation)
# each time. A persistent self-signed cert keeps grants across rebuilds.
IDENTITY="Ambitick Dev"
KC="$HOME/ambitick-dev.keychain-db"
KCPASS="ambitick-build"
ensure_identity() {
    security list-keychains -d user | grep -q "$KC" || {
        security create-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
        security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
    }
    security unlock-keychain -p "$KCPASS" "$KC"
    security set-keychain-settings "$KC"   # no auto-lock
    if ! security find-identity -p codesigning "$KC" | grep -q "$IDENTITY"; then
        TMP=$(mktemp -d)
        cat > "$TMP/ext.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Ambitick Dev
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
CNF
        # System LibreSSL: Homebrew OpenSSL 3 writes a .p12 `security import`
        # silently rejects (AES-256 default), so this must NOT use PATH openssl.
        /usr/bin/openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
            -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf"
        /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
            -out "$TMP/dev.p12" -passout pass:"$KCPASS" -name "$IDENTITY" 2>/dev/null
        security import "$TMP/dev.p12" -k "$KC" -P "$KCPASS" -T /usr/bin/codesign
        security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
        rm -rf "$TMP"
    fi
}

# Sign by hash: duplicate same-named identities make name-signing ambiguous.
ensure_identity || true
ID_HASH=$(security find-identity -p codesigning "$KC" 2>/dev/null \
    | awk -v id="$IDENTITY" '$0 ~ id {print $2; exit}')
if [ -n "$ID_HASH" ] && codesign --force -s "$ID_HASH" --keychain "$KC" "$APP"; then
    echo "Signed with stable identity $ID_HASH"
else
    echo "warning: stable identity unavailable, falling back to ad-hoc (TCC grants will not survive rebuilds)"
    codesign --force -s - "$APP"
fi

echo "Built $APP"
echo "First run: right-click -> Open, then grant Accessibility (once - grants now survive rebuilds)."
