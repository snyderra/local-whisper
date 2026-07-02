#!/usr/bin/env bash
#
# Build the distributable dmg from a signed "Local Whisper.app".
# Plain hdiutil (no create-dmg dependency): staging dir with the app and a
# /Applications symlink, APFS + ULMO (lzma) compression — the app already
# requires macOS 26+, so no legacy dmg-reader concerns.
#
# Env:
#   SIGN_IDENTITY   identity for signing the dmg itself (default "-";
#                   ad-hoc builds get an -adhoc suffix so a Gatekeeper-
#                   rejected artifact can never be mistaken for a release).
#
# Usage: scripts/make_dmg.sh "build/Local Whisper.app"
# Prints the dmg path on the last line.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: make_dmg.sh <path to .app>}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

[[ -d "$APP" ]] || { echo "not a bundle: $APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
SUFFIX=""
[[ "$SIGN_IDENTITY" == "-" ]] && SUFFIX="-adhoc"
DMG="$REPO_ROOT/build/LocalWhisper-$VERSION$SUFFIX.dmg"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Local Whisper" -srcfolder "$STAGING" \
    -format ULMO -fs APFS -ov "$DMG" >/dev/null

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$DMG"
else
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

du -h "$DMG" | cut -f1 | xargs -I{} echo "dmg size: {}" >&2
echo "$DMG"
