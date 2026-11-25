#!/bin/bash
# Build the unified PyrowaveCast app (server + receiver) and package it as a
# macOS .app bundle.
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
# Mac App Store flavour (--app-store):
#   Compiles with -DPYROWAVE_APP_STORE (no keyboard/mouse injection, which the App Sandbox
#   forbids) and signs ad hoc WITH Resources/AppStore/PyrowaveCast-AppStore.entitlements, so
#   the sandboxed app can be tried locally. For submission, re-sign it yourself with your own
#   Apple Distribution identity and a provisioning profile, then package it with productbuild
#   (see README, "App Store"). This script never uses a personal signing identity.
#
# Usage:
#   ./scripts/build-app.sh [--patch|--minor|--major-fix|--no-bump] [--app-store] [output.app path]
#
# Default output: build/PyrowaveCast-v<VERSION>-build<BUILD_NUMBER>-<COMMIT>.app
#                 (with convenience symlink build/PyrowaveCast.app)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_STORE=0
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--app-store" ]]; then APP_STORE=1; else ARGS+=("$arg"); fi
done

source "$ROOT/scripts/version.sh"
pyrowave_parse_build_args ${ARGS[@]+"${ARGS[@]}"}
pyrowave_apply_version "$ROOT" "$PYROWAVE_BUMP_MODE"

FLAVOR=""
SWIFT_FLAGS=()
if [[ "$APP_STORE" == 1 ]]; then
    FLAVOR="-AppStore"
    SWIFT_FLAGS=(-Xswiftc -DPYROWAVE_APP_STORE)
fi
OUT="${PYROWAVE_OUT_ARG:-$ROOT/build/PyrowaveCast${FLAVOR}-${PYROWAVE_VERSION_TAG}.app}"

echo "==> Building pyrowave-app (release${FLAVOR:+, Mac App Store flavour})"
swift build -c release --product pyrowave-app --disable-sandbox ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

BIN="$ROOT/.build/out/Products/Release/pyrowave-app"
BUNDLE="$ROOT/.build/out/Products/Release/PyrowaveKit_PyrowaveKit.bundle"

# Fall back to the alternate build path used by some Xcode versions.
if [[ ! -f "$BIN" ]]; then
    BIN="$ROOT/.build/release/pyrowave-app"
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

echo "==> Packaging $OUT (${PYROWAVE_BUILD_VERSION_TEXT})"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp "$BIN" "$OUT/Contents/MacOS/PyrowaveCast"
# Strip debug symbols: they list every object file by absolute build path, which
# exposes the builder's home folder (the repositories are public).
strip -S -x "$OUT/Contents/MacOS/PyrowaveCast"
cp -R "$BUNDLE" "$OUT/Contents/Resources/"
cp "$ROOT/Resources/AppIcon/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
# Privacy manifest (App Store requirement): no tracking, no data collected, required-reason APIs.
cp "$ROOT/Resources/AppStore/PrivacyInfo.xcprivacy" "$OUT/Contents/Resources/PrivacyInfo.xcprivacy"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PyrowaveCast</string>
    <key>CFBundleDisplayName</key>
    <string>PyrowaveCast</string>
    <key>CFBundleIdentifier</key>
    <string>com.pyrowavecast.app</string>
    <key>CFBundleVersion</key>
    <string>${PYROWAVE_BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${PYROWAVE_VERSION}</string>
    <key>PyrowaveGitCommit</key>
    <string>${PYROWAVE_COMMIT}</string>
    <key>PyrowaveBuildVersion</key>
    <string>${PYROWAVE_BUILD_VERSION_TEXT}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>PyrowaveCast</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>PyrowaveCast needs screen recording permission to stream your display.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>PyrowaveCast streams the selected microphone as the stream's audio when you choose it as audio source.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>PyrowaveCast needs local network access to connect to streaming servers.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_pyrowavecast._udp</string>
        <string>_pyrowave._udp</string>
    </array>
</dict>
</plist>
PLIST

xattr -cr "$OUT" 2>/dev/null || true

# Always ad-hoc: the repositories are public, so builds must never carry a
# personal Apple Development / Developer ID identity (name and team ID end up in
# the signature of anything that gets shared). macOS may ask again for the
# Screen Recording permission after a rebuild.
if [[ "$APP_STORE" == 1 ]]; then
    # Ad hoc but sandboxed, so the App Store behaviour can be tried locally.
    echo "==> Signing $OUT with ad-hoc signature and App Sandbox entitlements"
    codesign --force --deep --sign - --identifier com.pyrowavecast.app \
        --entitlements "$ROOT/Resources/AppStore/PyrowaveCast-AppStore.entitlements" "$OUT"
else
    echo "==> Signing $OUT with ad-hoc signature"
    codesign --force --deep --sign - --identifier com.pyrowavecast.app "$OUT"
fi

# Update convenience symlink build/PyrowaveCast[-AppStore].app if default output was used
if [[ -z "${PYROWAVE_OUT_ARG:-}" ]]; then
    rm -rf "$ROOT/build/PyrowaveCast${FLAVOR}.app"
    ln -s "$(basename "$OUT")" "$ROOT/build/PyrowaveCast${FLAVOR}.app"
fi

echo "==> Done: $OUT (${PYROWAVE_BUILD_VERSION_TEXT})"
echo "    Launch it with: open \"$OUT\""
