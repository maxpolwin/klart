#!/usr/bin/env bash
# Notarizes and staples a signed build artifact — dist/Klart.dmg (what you
# actually hand to users to install) or dist/Klart.app. This is the step
# that removes the "Apple could not verify..." Gatekeeper warning for anyone
# besides you who opens the app or mounts the DMG.
#
# Run Scripts/make-app.sh (and Scripts/make-dmg.sh, for a DMG) with a real
# Developer ID SIGN_IDENTITY first — notarization rejects ad-hoc signed or
# unsigned bundles.
#
# One-time setup (stores credentials in your login Keychain, not in the repo):
#
#   xcrun notarytool store-credentials "klart-notary" \
#     --apple-id "you@example.com" \
#     --team-id "TEAM1234ID" \
#     --password "an-app-specific-password"
#
# The app-specific password comes from https://appleid.apple.com/account/manage
# (Sign-In and Security → App-Specific Passwords) — NOT your normal Apple ID
# password. Team ID is on https://developer.apple.com/account under Membership.
#
# Usage: bash Scripts/notarize-app.sh [path-to-dmg-or-app]
#        (defaults to dist/Klart.dmg if it exists, else dist/Klart.app)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-klart-notary}"
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  if [ -e "dist/Klart.dmg" ]; then
    TARGET="dist/Klart.dmg"
  else
    TARGET="dist/Klart.app"
  fi
fi

if [ ! -e "$TARGET" ]; then
  echo "error: $TARGET not found — run Scripts/make-app.sh (and Scripts/make-dmg.sh for a DMG) with SIGN_IDENTITY set first" >&2
  exit 1
fi

case "$TARGET" in
  *.dmg)
    echo "Submitting $TARGET to Apple for notarization (this can take a few minutes)..."
    xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait
    echo "Stapling the notarization ticket to $TARGET..."
    xcrun stapler staple "$TARGET"
    ;;
  *.app)
    ZIP="dist/$(basename "$TARGET" .app)-notarize.zip"
    ditto -c -k --keepParent "$TARGET" "$ZIP"
    echo "Submitting $TARGET to Apple for notarization (this can take a few minutes)..."
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    echo "Stapling the notarization ticket to $TARGET..."
    xcrun stapler staple "$TARGET"
    rm -f "$ZIP"
    ;;
  *)
    echo "error: don't know how to notarize $TARGET (expected a .app or .dmg)" >&2
    exit 1
    ;;
esac

echo "Done. Verify with: spctl --assess --verbose \"$TARGET\""
