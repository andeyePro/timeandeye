#!/bin/bash
# Build andeye.app from the SwiftPM executable.
# Run on the Mac, from the repo root:  ./scripts/make-app.sh [output-dir]
set -euo pipefail

OUT="${1:-.}"
APP="$OUT/andeye.app"
# With no output-dir arg we INSTALL into /Applications (where launchers —
# Raycast, Spotlight — find it) and relaunch. A running instance must quit
# first: replacing a running bundle in place can kill it mid-execution
# (the "menu bar icon disappeared" deaths).
INSTALL=0
[ $# -eq 0 ] && INSTALL=1
# Quit a running copy so the bundle swaps cleanly.
if pgrep -xq andeye; then
    if [ "$INSTALL" = 1 ]; then
        echo "Quitting running app to replace it…"
        osascript -e 'quit app "andeye"' 2>/dev/null || true
        for _ in $(seq 1 10); do pgrep -xq andeye || break; sleep 0.5; done
    else
        APP="$OUT/andeye+.app"
        echo "NOTE: app is running; building to $APP - quit the old one and rename to swap."
    fi
fi

swift build -c release --product andeyeApp
BIN="$(swift build -c release --show-bin-path)/andeyeApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/andeye"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.andeye.mac</string>
    <key>CFBundleName</key><string>andeye</string>
    <key>CFBundleDisplayName</key><string>andeye</string>
    <key>CFBundleExecutable</key><string>andeye</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>BUILD_STAMP</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>andeye reads the active browser tab URL to attribute time to the right task.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>andeye observes whether the microphone is in use (call detection); it never records audio.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>andeye talks to your own backend instance, which may be on your local network.</string>
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
IDENTITY="andeye Dev"
KC="$HOME/andeyett-dev.keychain-db"
KCPASS="andeyett-build"
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
CN = andeye Dev
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
        rm -rf "$TMP"
    fi
    # Re-assert the key's partition list on EVERY build, not just at creation:
    # this is what lets codesign use the key non-interactively. Doing it only
    # once left a stale ACL that re-prompted for the keychain password every
    # build. Idempotent; -s + the password authorises it without a GUI prompt.
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" \
        >/dev/null 2>&1 || true
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

# Install into /Applications and relaunch, so the build you just made is the
# one that actually runs. The repo-local bundle is only a staging copy; without
# this the freshly-built app sits in the repo while launchers keep opening the
# old /Applications copy.
if [ "$INSTALL" = 1 ]; then
    DEST="/Applications/andeye.app"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"          # preserves the signature + bundle structure
    echo "Installed to $DEST"
    open "$DEST"
    echo "Relaunched from /Applications."
else
    echo "First run: right-click -> Open, then grant Accessibility (once - grants now survive rebuilds)."
fi
