#!/usr/bin/env bash
# Builds Inkwell via SwiftPM and packages the binary into a .app bundle.
# Used in development without Xcode (Command Line Tools sufficient).
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

# Build the executable
swift build -c "$CONFIG"

EXEC=".build/$CONFIG/Inkwell"
APP="build/Inkwell.app"

if [[ ! -f "$EXEC" ]]; then
    echo "error: built executable not found at $EXEC" >&2
    exit 1
fi

# Stage the .app bundle structure
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXEC" "$APP/Contents/MacOS/Inkwell"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign for local development (no developer ID required)
codesign --force --sign - "$APP"

echo "Built $APP"
