#!/usr/bin/env bash
# Generates Klart.xcodeproj from project.yml (XcodeGen) and opens it in Xcode.
#
# The project is disposable and git-ignored — regenerate it whenever project.yml
# or the source layout changes. For quick UI iteration you don't need this at
# all: `xed .` opens the Swift package directly in Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: xcodegen is not installed.

Install it, then re-run this script:

    brew install xcodegen

Or skip the app target and open the Swift package directly (no tooling needed):

    xed .            # equivalently: open Package.swift
EOF
  exit 1
fi

xcodegen generate
echo "Generated Klart.xcodeproj"

if [ "${NO_OPEN:-}" != "1" ]; then
  open Klart.xcodeproj
fi
