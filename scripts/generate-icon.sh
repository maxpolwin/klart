#!/bin/bash

# Generate macOS .icns icon from a 1024x1024 master PNG (build/icon.png).
# Requires: sips and iconutil (both come with macOS / Xcode command line tools).
# If build/icon.png has transparency, it is flattened onto a solid
# background color (ICON_BG, default #1a1a2e) using ImageMagick, since
# macOS app icons should not rely on the Dock/Finder background showing
# through. Install ImageMagick with: brew install imagemagick

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
PNG_FILE="$BUILD_DIR/icon.png"
ICONSET_DIR="$BUILD_DIR/icon.iconset"
ICON_BG="${ICON_BG:-#1a1a2e}"

echo "Generating macOS icon from PNG..."

if [ ! -f "$PNG_FILE" ]; then
  echo "Error: $PNG_FILE not found." >&2
  echo "Put a 1024x1024 master PNG at build/icon.png first." >&2
  exit 1
fi

if ! command -v sips &> /dev/null; then
  echo "Error: sips not found (should ship with macOS)." >&2
  exit 1
fi

if command -v magick &> /dev/null; then
  IM_CMD="magick"
elif command -v convert &> /dev/null; then
  IM_CMD="convert"
else
  IM_CMD=""
fi

if [ -n "$IM_CMD" ]; then
  echo "Flattening $PNG_FILE onto solid background $ICON_BG..."
  "$IM_CMD" "$PNG_FILE" -background "$ICON_BG" -flatten "$PNG_FILE"
else
  echo "Warning: ImageMagick not found — if $PNG_FILE has transparency it will stay" >&2
  echo "transparent (invisible on light backgrounds). Install with:" >&2
  echo "  brew install imagemagick" >&2
  echo "and rerun, or flatten it yourself before running this script." >&2
fi

# Create iconset directory
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# macOS iconset naming -> pixel size to render at from the 1024 master.
# Plain array of "name:size" pairs instead of an associative array, since
# macOS ships bash 3.2 (no declare -A support) as its default /bin/bash.
SIZES="
icon_16x16.png:16
icon_16x16@2x.png:32
icon_32x32.png:32
icon_32x32@2x.png:64
icon_128x128.png:128
icon_128x128@2x.png:256
icon_256x256.png:256
icon_256x256@2x.png:512
icon_512x512.png:512
icon_512x512@2x.png:1024
"

for pair in $SIZES; do
  name="${pair%%:*}"
  size="${pair##*:}"
  echo "  Generating $name (${size}x${size})..."
  sips -z "$size" "$size" "$PNG_FILE" --out "$ICONSET_DIR/$name" > /dev/null
done

# Create .icns file
echo "Creating .icns file..."
iconutil -c icns "$ICONSET_DIR" -o "$BUILD_DIR/icon.icns"

# Cleanup
rm -rf "$ICONSET_DIR"

echo "Done! Icon created at: $BUILD_DIR/icon.icns"
