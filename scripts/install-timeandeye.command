#!/bin/bash
# Double-click this to update Time&I (timeandeye.app). No passwords, no
# rename dance.
#
# Claude ships the build as a ZIP (not a loose .app) so there is never a second
# unpacked bundle with the same id sitting where Spotlight/LaunchServices will
# index it — that duplicate-id confusion is what mislabelled the app as
# "andeye+". This installer unpacks the zip into your OWN ~/Applications (your
# folder → no admin prompt) and relaunches. The stable signature and bundle id
# mean keychain and Accessibility grants survive updates; an app-identity
# change (a new bundle id) is the one case that re-asks, once.
set -euo pipefail

SRC="/Users/Shared/timeandeye-build.zip"
DEST="$HOME/Applications/timeandeye.app"

if [ ! -f "$SRC" ]; then
    echo "No build found at $SRC — ask Claude to build it first."
    read -r -p "Press return to close. "
    exit 1
fi

mkdir -p "$HOME/Applications"

# Quit the running copy so the bundle swaps cleanly — both identities: current
# builds carry com.timeandeye.mac, pre-rename builds com.andeye.mac. The
# `is running` guard stops AppleScript LAUNCHING a dormant registered copy
# just to deliver the quit event. (Ids are duplicated from make-app.sh's
# BUNDLE_ID/LEGACY_BUNDLE_ID — this file must stay self-contained for
# double-click use; change them in lockstep.)
for QID in com.timeandeye.mac com.andeye.mac; do
    osascript -e "if application id \"$QID\" is running then quit app id \"$QID\"" >/dev/null 2>&1 || true
done
# Wait for the process to exit, and stop rather than swap the bundle under a
# still-running app (a denied Automation prompt fails silently above).
for _ in $(seq 1 10); do pgrep -xq andeye || break; sleep 0.5; done
if pgrep -xq andeye; then
    echo "Time&I is still running and would not quit — quit it from the menu bar, then run this again."
    read -r -p "Press return to close. "
    exit 1
fi

# Unpack the zip and install at the canonical path in your own account.
TMP="$(mktemp -d)"
ditto -x -k "$SRC" "$TMP"
NEW="$TMP/timeandeye.app"
# Retire the pre-rename bundle: a surviving old-identity copy stays
# LaunchServices-resolvable and lists as a second Time&I in launchers.
rm -rf "$HOME/Applications/andeye.app"
rm -rf "$DEST"
ditto "$NEW" "$DEST"
rm -rf "$TMP"

# Make this app THE registration for its bundle id, so its name resolves to
# "Time&I" (not a stray duplicate).
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$DEST" >/dev/null 2>&1 || true

open "$DEST"
echo "Updated Time&I → $DEST and relaunched."
