#!/usr/bin/env bash
# Assembles a distributable Noschen.app from the SwiftPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Noschen.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Noschen "$APP/Contents/MacOS/Noschen"
cp Sources/NoschenApp/Resources/Info.plist "$APP/Contents/Info.plist"

# Reuse the project icon if present (repo root /build/icon.icns).
if [ -f ../build/icon.icns ]; then
  cp ../build/icon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so Gatekeeper treats the bundle as intact locally.
# For distribution, replace "-" with a Developer ID identity and notarize.
codesign --force --sign - "$APP"

echo "Built $APP"
