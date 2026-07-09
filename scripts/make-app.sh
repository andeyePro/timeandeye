#!/bin/bash
# Build timeandeye.app (Time&I) from the SwiftPM executable.
# Run on the Mac, from the repo root:  ./scripts/make-app.sh [output-dir]
set -euo pipefail

OUT="${1:-.}"
APP="$OUT/timeandeye.app"
# With no output-dir arg we INSTALL into /Applications (where launchers —
# Raycast, Spotlight — find it) and relaunch. A running instance must quit
# first: replacing a running bundle in place can kill it mid-execution
# (the "menu bar icon disappeared" deaths).
INSTALL=0
[ $# -eq 0 ] && INSTALL=1
# Quit a running copy so the bundle swaps cleanly. Quit by BUNDLE ID, not by
# name: the id is shared by the pre-rename andeye.app and today's
# timeandeye.app, so this targets whichever is running. pgrep matches the
# executable name, which is "andeye" in both (see CFBundleExecutable below).
if pgrep -xq andeye; then
    if [ "$INSTALL" = 1 ]; then
        echo "Quitting running app to replace it…"
        # Quit whichever identity is running: pre-rename builds carry
        # com.andeye.mac, current builds com.timeandeye.mac.
        osascript -e 'quit app id "com.timeandeye.mac"' 2>/dev/null || true
        osascript -e 'quit app id "com.andeye.mac"' 2>/dev/null || true
        for _ in $(seq 1 10); do pgrep -xq andeye || break; sleep 0.5; done
    else
        APP="$OUT/timeandeye+.app"
        echo "NOTE: app is running; building to $APP - quit the old one and rename to swap."
    fi
fi

swift build -c release --product timeandeyeApp
BIN="$(swift build -c release --show-bin-path)/timeandeyeApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/andeye"

# Naming: bundle/folder = timeandeye, human name = Time&I (XML-escaped as
# Time&amp;I below; there is no separate long form — CFBundleName and
# CFBundleDisplayName are both Time&I).
# CFBundleIdentifier is com.timeandeye.mac — Martin's per-app-id decision
# (2026-07-09: every andeye app gets its own id; a sibling andeye app etc. cannot share
# one). Changed from com.andeye.mac BEFORE the entitled build, so no iCloud
# container or provisioning existed to migrate; the one-time cost was a
# re-grant of TCC permissions. From here it MUST NOT change again: TCC
# grants (Accessibility, Automation, Calendar) key off this identifier plus
# the stable signing identity — a new id silently revokes every grant.
# CFBundleExecutable stays "andeye" deliberately: the quit-wait above
# (pgrep -x andeye) must match BOTH the old andeye.app and this bundle's
# process during an upgrade, and nothing user-visible shows the executable
# name (LSUIElement app) — renaming it buys nothing and risks the
# replace-a-running-bundle deaths.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.timeandeye.mac</string>
    <key>CFBundleName</key><string>Time&amp;I</string>
    <key>CFBundleDisplayName</key><string>Time&amp;I</string>
    <key>CFBundleExecutable</key><string>andeye</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>BUILD_STAMP</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Time&amp;I reads the active browser tab URL to attribute time to the right task.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Time&amp;I observes whether the microphone is in use (call detection); it never records audio.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Time&amp;I reads your calendar (read-only) to guess what you're supposed to be doing right now and to hint at old review-queue rows that overlap a past event. It never creates, edits or deletes anything on your calendar.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Time&amp;I talks to your own backend instance, which may be on your local network.</string>
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
    DEST="/Applications/timeandeye.app"
    # Retire the pre-rename bundle: two apps with the same bundle id must
    # never coexist (duplicate-id confusion is what once mislabelled the
    # app as "andeye+"), so remove the old copy before installing the new.
    rm -rf "/Applications/andeye.app"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"          # preserves the signature + bundle structure
    # Make this copy THE LaunchServices registration for com.timeandeye.mac, so
    # its name resolves to the new one and no stale registration lingers.
    LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    [ -x "$LSREG" ] && "$LSREG" -f "$DEST" >/dev/null 2>&1 || true
    echo "Installed to $DEST"
    open "$DEST"
    echo "Relaunched from /Applications."
else
    echo "First run: right-click -> Open, then grant Accessibility (once - grants now survive rebuilds)."
fi
