#!/usr/bin/env bash
# Packages dist/Klart.app (built by Scripts/make-app.sh) into a
# drag-to-install disk image: dist/Klart.dmg.
#
# Run this AFTER make-app.sh. For a DMG that opens without any Gatekeeper
# warning for people besides you, sign both the app and the DMG with your
# Developer ID, then notarize + staple:
#
#   ID="Developer ID Application: Your Name (TEAM1234ID)"
#   SIGN_IDENTITY="$ID" bash Scripts/make-app.sh
#   SIGN_IDENTITY="$ID" bash Scripts/make-dmg.sh
#   bash Scripts/notarize-app.sh dist/Klart.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Klart.app"
DMG="dist/Klart.dmg"
VOLUME_NAME="Klårt"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run Scripts/make-app.sh first" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# Drag-to-Applications layout: the app plus a symlink to /Applications.
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$DMG"
  echo "Built $DMG (ad-hoc signed — only trusted on this Mac)"
else
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  echo "Built $DMG (signed with: $SIGN_IDENTITY)"
  echo "Next: bash Scripts/notarize-app.sh dist/Klart.dmg"
fi
