#!/bin/bash

# Generate macOS .icns icon from a 1024x1024 master PNG (build/icon.png).
# Requires: sips and iconutil (both come with macOS / Xcode command line tools).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
PNG_FILE="$BUILD_DIR/icon.png"
ICONSET_DIR="$BUILD_DIR/icon.iconset"

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

# Create iconset directory
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# macOS iconset naming -> pixel size to render at from the 1024 master
declare -A SIZES=(
  [icon_16x16.png]=16
  [icon_16x16@2x.png]=32
  [icon_32x32.png]=32
  [icon_32x32@2x.png]=64
  [icon_128x128.png]=128
  [icon_128x128@2x.png]=256
  [icon_256x256.png]=256
  [icon_256x256@2x.png]=512
  [icon_512x512.png]=512
  [icon_512x512@2x.png]=1024
)

for name in "${!SIZES[@]}"; do
  size="${SIZES[$name]}"
  echo "  Generating $name (${size}x${size})..."
  sips -z "$size" "$size" "$PNG_FILE" --out "$ICONSET_DIR/$name" > /dev/null
done

# Create .icns file
echo "Creating .icns file..."
iconutil -c icns "$ICONSET_DIR" -o "$BUILD_DIR/icon.icns"

# Cleanup
rm -rf "$ICONSET_DIR"

echo "Done! Icon created at: $BUILD_DIR/icon.icns"
