#!/bin/bash
# Double-click this to update andeye. No passwords, no rename dance.
#
# Claude ships the build as a ZIP (not a loose .app) so there is never a second
# unpacked bundle with the same id sitting where Spotlight/LaunchServices will
# index it — that duplicate-id confusion is what mislabelled the app as
# "andeye+". This installer unpacks the zip into your OWN ~/Applications (your
# folder → no admin prompt) and relaunches. The stable signature means the
# keychain and Accessibility never re-challenge you after the first grant.
set -euo pipefail

SRC="/Users/Shared/andeye-build.zip"
DEST="$HOME/Applications/andeye.app"

if [ ! -f "$SRC" ]; then
    echo "No build found at $SRC — ask Claude to build it first."
    read -r -p "Press return to close. "
    exit 1
fi

mkdir -p "$HOME/Applications"

# Quit the running copy so the bundle swaps cleanly.
osascript -e 'tell application "andeye" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "Ambitick" to quit' >/dev/null 2>&1 || true
pkill -x Ambitick >/dev/null 2>&1 || true
for _ in $(seq 1 25); do pgrep -xq Ambitick || break; sleep 0.2; done

# Unpack the zip and install at the canonical path in your own account.
TMP="$(mktemp -d)"
ditto -x -k "$SRC" "$TMP"
NEW="$TMP/andeye.app"
rm -rf "$DEST"
ditto "$NEW" "$DEST"
rm -rf "$TMP"

# Make this app THE registration for its bundle id, so its name resolves to
# "andeye" (not a stray duplicate).
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$DEST" >/dev/null 2>&1 || true

open "$DEST"
echo "Updated andeye → $DEST and relaunched."
