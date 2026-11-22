#!/bin/bash
# Build the PyrowaveCast Receiver GUI and package it as a macOS .app bundle.
#
# SwiftPM builds the executable plus the PyrowaveKit resource bundle
# (PyrowaveKit_PyrowaveKit.bundle, which holds the Metal shaders). The
# decoder crashes unless that bundle is embedded in the .app, so this
# script copies it into Contents/Resources/ for you.
#
# Versioning:
#   Automatically bumps VERSION on each package:
#     --patch (default)    0.5.x -> 0.5.(x+1)  (minor fixes)
#     --minor/--major-fix  0.x.y -> 0.(x+1).0  (major fixes)
#     --no-bump            keep VERSION unchanged
#
# Usage:
#   ./scripts/build-receiver.sh [--patch|--minor|--major-fix|--no-bump] [output.app path]
#
# Default output: build/PyrowaveCastReceiver-v<VERSION>-build<BUILD_NUMBER>.app
#                 (with convenience symlink build/PyrowaveCastReceiver.app)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/scripts/version.sh"
pyrowave_parse_build_args "$@"
pyrowave_apply_version "$ROOT" "$PYROWAVE_BUMP_MODE"

OUT="${PYROWAVE_OUT_ARG:-$ROOT/build/PyrowaveCastReceiver-${PYROWAVE_VERSION_TAG}.app}"

echo "==> Building pyrowave-receiver-gui (release)"
swift build -c release --product pyrowave-receiver-gui --disable-sandbox

BIN="$ROOT/.build/out/Products/Release/pyrowave-receiver-gui"
BUNDLE="$ROOT/.build/out/Products/Release/PyrowaveKit_PyrowaveKit.bundle"

# Fall back to the alternate build path used by some Xcode versions.
if [[ ! -f "$BIN" ]]; then
    BIN="$ROOT/.build/release/pyrowave-receiver-gui"
fi
if [[ ! -d "$BUNDLE" ]]; then
    BUNDLE="$ROOT/.build/release/PyrowaveKit_PyrowaveKit.bundle"
fi

if [[ ! -f "$BIN" ]]; then
    echo "error: executable not found" >&2
    exit 1
fi
if [[ ! -d "$BUNDLE" ]]; then
    echo "error: resource bundle not found" >&2
    exit 1
fi

echo "==> Packaging $OUT (v$PYROWAVE_VERSION, build $PYROWAVE_BUILD_NUMBER)"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp "$BIN" "$OUT/Contents/MacOS/PyrowaveCastReceiver"
cp -R "$BUNDLE" "$OUT/Contents/Resources/"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PyrowaveCast Receiver</string>
    <key>CFBundleDisplayName</key>
    <string>PyrowaveCast Receiver</string>
    <key>CFBundleIdentifier</key>
    <string>com.pyrowavecast.receiver</string>
    <key>CFBundleVersion</key>
    <string>${PYROWAVE_BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${PYROWAVE_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>PyrowaveCastReceiver</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>PyrowaveCast Receiver needs local network access to connect to the streaming server.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_pyrowavecast._udp</string>
        <string>_pyrowave._udp</string>
    </array>
</dict>
</plist>
PLIST

# Update convenience symlink build/PyrowaveCastReceiver.app if default output was used
if [[ -z "${PYROWAVE_OUT_ARG:-}" ]]; then
    rm -rf "$ROOT/build/PyrowaveCastReceiver.app"
    ln -s "$(basename "$OUT")" "$ROOT/build/PyrowaveCastReceiver.app"
fi

echo "==> Done: $OUT (v$PYROWAVE_VERSION, build $PYROWAVE_BUILD_NUMBER)"
echo "    Launch it with: open \"$OUT\""
