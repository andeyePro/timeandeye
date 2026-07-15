#!/bin/bash
# Build timeandeye.app (Time&I) from the SwiftPM executable.
# Run on the Mac, from the repo root:  ./scripts/make-app.sh [output-dir]
set -euo pipefail

OUT="${1:-.}"
APP="$OUT/timeandeye.app"
# The app's identity, single-sourced: quit lines and the Info.plist heredoc
# (via sed, like BUILD_STAMP) all read these. LEGACY_BUNDLE_ID is the
# pre-2026-07-09 identity, kept only so upgrades can quit/retire old
# installs — see the TODO.md expiry entry before touching either.
BUNDLE_ID="com.timeandeye.mac"
LEGACY_BUNDLE_ID="com.andeye.mac"
# With no output-dir arg we INSTALL into /Applications (where launchers —
# Raycast, Spotlight — find it) and relaunch. A running instance must quit
# first: replacing a running bundle in place can kill it mid-execution
# (the "menu bar icon disappeared" deaths).
INSTALL=0
[ $# -eq 0 ] && INSTALL=1
# Quit a running copy so the bundle swaps cleanly. The two identities differ
# (pre-rename builds carry $LEGACY_BUNDLE_ID, current builds $BUNDLE_ID), so
# quit BOTH by id; pgrep bridges them by matching the executable name, which
# is "andeye" in both (see CFBundleExecutable below). The `is running` guard
# matters: a bare `quit app id` LAUNCHES a registered-but-not-running bundle
# just to deliver the quit event, and one of these two ids is always not
# running — without the guard a stale old-id copy cold-starts mid-build.
if pgrep -xq andeye; then
    if [ "$INSTALL" = 1 ]; then
        echo "Quitting running app to replace it…"
        for QID in "$BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
            osascript -e "if application id \"$QID\" is running then quit app id \"$QID\"" 2>/dev/null || true
        done
        for _ in $(seq 1 10); do pgrep -xq andeye || break; sleep 0.5; done
        # The quits above swallow errors (an unanswered Automation-consent
        # prompt fails silently with -1743), so re-check before the install
        # step swaps the bundle under a still-running process.
        if pgrep -xq andeye; then
            echo "error: the running app did not quit (Automation consent denied, or a stuck copy);" >&2
            echo "       aborting before replacing the installed bundle. Quit it manually and re-run." >&2
            exit 1
        fi
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
# CFBundleIdentifier is $BUNDLE_ID (defined at the top; stamped into the
# plist below via sed, like BUILD_STAMP) — per-app ids across andeye apps,
# see CHANGELOG 2026-07-09. It MUST NOT change again: TCC grants
# (Accessibility, Automation, Calendar) key off this identifier plus the
# stable signing identity — a new id silently revokes every grant.
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
    <key>CFBundleIdentifier</key><string>BUNDLE_ID</string>
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

# Stamp the identity and build time into the plist (single-sourced values,
# quoted heredoc). Must run before signing.
/usr/bin/sed -i '' "s/BUNDLE_ID/$BUNDLE_ID/" "$APP/Contents/Info.plist"
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
        # First run only: this creates a dedicated login-keychain to hold a
        # self-signed code-signing certificate and adds it to your keychain
        # search list. It stores no personal data and touches nothing else on
        # your Mac; the self-signed cert is what keeps macOS permission grants
        # (Accessibility, Automation) stable across rebuilds. To undo:
        #   security delete-keychain "$KC"
        echo "Creating a local signing keychain ($KC) to code-sign the app – first run only."
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
    # Retire old-identity bundles from BOTH install locations (make-app.sh
    # installs to /Applications, the zip installer to ~/Applications): a
    # surviving $LEGACY_BUNDLE_ID copy stays LaunchServices-resolvable, lists
    # as a second Time&I in launchers, and is what the legacy quit above
    # would otherwise have to keep targeting. (Duplicate registrations are
    # also what once mislabelled the app as "andeye+".)
    rm -rf "/Applications/andeye.app" "$HOME/Applications/andeye.app"
    OLDHOME="$HOME/Applications/timeandeye.app"
    # Only retire it when its plist EXISTS, is readable, and verifiably lacks
    # the current id (grep -F: dots in the id must not pattern-match). A
    # missing/unreadable plist (e.g. a half-finished zip install) proves
    # nothing about the bundle's identity — deleting on grep FAILURE would
    # rm a possibly-current install.
    if [ -d "$OLDHOME" ] && [ -r "$OLDHOME/Contents/Info.plist" ] \
        && ! grep -qF "$BUNDLE_ID" "$OLDHOME/Contents/Info.plist"; then
        # Pre-rename id under the new folder name; a current-id copy there
        # is the zip install and is left alone.
        rm -rf "$OLDHOME"
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"          # preserves the signature + bundle structure
    # Make this copy THE LaunchServices registration for the bundle id, so
    # its name resolves to the new one and no stale registration lingers.
    LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    [ -x "$LSREG" ] && "$LSREG" -f "$DEST" >/dev/null 2>&1 || true
    echo "Installed to $DEST"
    open "$DEST"
    echo "Relaunched from /Applications."
else
    echo "First run: right-click -> Open, then grant Accessibility (once - grants now survive rebuilds)."
fi
