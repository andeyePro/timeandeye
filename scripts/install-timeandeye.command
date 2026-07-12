#!/bin/bash
# Double-click this to install or update Time&I (timeandeye.app). No
# passwords, no rename dance.
#
# It installs from a locally built or downloaded bundle. Point it at either a
# zipped app or a loose timeandeye.app; if you give it nothing, it looks for
# one next to this script and then in your Downloads folder. Build a fresh
# bundle with scripts/make-app.sh, or download the release zip.
#
# The app is installed into your OWN ~/Applications (your folder → no admin
# prompt) and relaunched. A zip is preferred over a loose .app so there is
# never a second unpacked bundle with the same id sitting where
# Spotlight/LaunchServices will index it — that duplicate-id confusion is what
# can mislabel the app as "andeye+". The stable signature and bundle id mean
# keychain and Accessibility grants survive updates; an app-identity change (a
# new bundle id) is the one case that re-asks, once.
set -euo pipefail

DEST="$HOME/Applications/timeandeye.app"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Resolve the source. Priority: explicit argument, then a bundle/zip next to
# this script, then one in ~/Downloads. Accepts either timeandeye.app or a zip
# containing it.
find_source() {
    if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
        printf '%s\n' "$1"
        return 0
    fi
    for CANDIDATE in \
        "$HERE/timeandeye.app" \
        "$HERE/timeandeye.zip" \
        "$HERE/timeandeye-build.zip" \
        "$HOME/Downloads/timeandeye.app" \
        "$HOME/Downloads/timeandeye.zip" \
        "$HOME/Downloads/timeandeye-build.zip"; do
        if [ -e "$CANDIDATE" ]; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    done
    return 1
}

if ! SRC="$(find_source "${1:-}")"; then
    echo "No timeandeye.app (or a zip of it) found."
    echo "Pass one as an argument, or drop it next to this script or in your"
    echo "Downloads folder. Build one with scripts/make-app.sh, or download the"
    echo "release zip."
    read -r -p "Press return to close. "
    exit 1
fi
if [ ! -e "$SRC" ]; then
    echo "Nothing at: $SRC"
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

# Stage the bundle to install. A loose .app is used in place; a zip is
# unpacked into a scratch dir. The trap cleans the scratch dir on EVERY exit
# (including the aborts below).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
case "$SRC" in
    *.zip)
        ditto -x -k "$SRC" "$TMP"
        NEW="$TMP/timeandeye.app"
        ;;
    *)
        NEW="$SRC"
        ;;
esac
# Verify the bundle BEFORE touching the installed copy: a zip with a different
# root (e.g. a stale pre-rename build) must abort with the current install
# intact, not leave you with no app at all.
if [ ! -d "$NEW" ] || [ ! -f "$NEW/Contents/Info.plist" ]; then
    echo "$SRC doesn't contain a valid timeandeye.app."
    echo "Your installed copy is untouched."
    read -r -p "Press return to close. "
    exit 1
fi
# Retire duplicates from BOTH install locations: the pre-rename bundles, and
# a make-app.sh install of the current app at /Applications — any survivor
# stays LaunchServices-resolvable and lists as a second Time&I in launchers
# (that duplicate registration is the "andeye+" mislabel, see the header).
# /Applications may need admin rights this double-click flow doesn't have,
# so failures warn instead of aborting the install.
rm -rf "$HOME/Applications/andeye.app"
for OLD in "/Applications/andeye.app" "/Applications/timeandeye.app"; do
    if [ -e "$OLD" ] && ! rm -rf "$OLD" 2>/dev/null; then
        echo "note: couldn't remove $OLD (needs admin) — drag it to the Trash in Finder"
        echo "      so launchers don't show two copies of Time&I."
    fi
done
# Don't clobber the install with itself if someone points this at the already
# installed copy.
if [ "$NEW" != "$DEST" ]; then
    rm -rf "$DEST"
    ditto "$NEW" "$DEST"
fi

# Make this app THE registration for its bundle id, so its name resolves to
# "Time&I" (not a stray duplicate).
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$DEST" >/dev/null 2>&1 || true

open "$DEST"
echo "Installed Time&I → $DEST and relaunched."
