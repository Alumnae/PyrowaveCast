#!/bin/bash
# Build the unified PyrowaveCast iOS app (server + receiver) and package it as
# an unsigned .ipa.
#
# The app is built through the Xcode project at PyrowaveCastiOS/PyrowaveCastiOS.xcodeproj.
# It compiles PyrowaveKit, PyrowaveServerKit, SPPWCommon, and the vendored
# Metal sources directly (not through SwiftPM).
#
# Versioning:
#   Automatically bumps VERSION and syncs PyrowaveCastiOS/PyrowaveCastiOS/Info.plist:
#     --patch (default)    0.5.x -> 0.5.(x+1)  (minor fixes)
#     --minor/--major-fix  0.x.y -> 0.(x+1).0  (major fixes)
#     --no-bump            keep VERSION unchanged
#
# Usage:
#   ./scripts/build-ios.sh [--patch|--minor|--major-fix|--no-bump] [output.ipa path]
#
# Default output: build/PyrowaveCastiOS-v<VERSION>-build<BUILD_NUMBER>-<COMMIT>.ipa
#                 (with convenience symlink build/PyrowaveCastiOS.ipa)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/scripts/version.sh"
pyrowave_parse_build_args "$@"
pyrowave_apply_version "$ROOT" "$PYROWAVE_BUMP_MODE"

OUT="${PYROWAVE_OUT_ARG:-$ROOT/build/PyrowaveCastiOS-${PYROWAVE_VERSION_TAG}.ipa}"
PROJECT="$ROOT/PyrowaveCastiOS/PyrowaveCastiOS.xcodeproj"
SCHEME="PyrowaveCastiOS"
PRODUCT_NAME="Pyrowavecast"
ARCHIVE_PATH="$ROOT/build/PyrowaveCastiOS.xcarchive"

echo "==> Building iOS app ${PYROWAVE_BUILD_VERSION_TEXT} (release, generic/iOS device)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=iOS" \
    PRODUCT_NAME="$PRODUCT_NAME" \
    PRODUCT_BUNDLE_IDENTIFIER="com.pyrowavecast.ios" \
    MARKETING_VERSION="$PYROWAVE_VERSION" \
    CURRENT_PROJECT_VERSION="$PYROWAVE_BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    clean archive \
    2>&1

echo "==> Packaging unsigned .ipa"
APP_PATH="$ARCHIVE_PATH/Products/Applications/${PRODUCT_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
    if [[ -d "$ARCHIVE_PATH/Products/Applications/PyrowaveCastiOS.app" ]]; then
        APP_PATH="$ARCHIVE_PATH/Products/Applications/PyrowaveCastiOS.app"
    elif [[ -d "$ARCHIVE_PATH/Products/Applications/PyrowaveCast.app" ]]; then
        APP_PATH="$ARCHIVE_PATH/Products/Applications/PyrowaveCast.app"
    else
        echo "error: built .app not found at $APP_PATH" >&2
        exit 1
    fi
fi

PAYLOAD_DIR="$ROOT/build/ipa-staging/Payload"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"

rm -f "$OUT"
(cd "$ROOT/build/ipa-staging" && zip -r -q "$OUT" Payload)
rm -rf "$ROOT/build/ipa-staging"

# Update convenience symlink build/PyrowaveCastiOS.ipa if default output was used
if [[ -z "${PYROWAVE_OUT_ARG:-}" ]]; then
    rm -f "$ROOT/build/PyrowaveCastiOS.ipa"
    ln -s "$(basename "$OUT")" "$ROOT/build/PyrowaveCastiOS.ipa"
fi

echo "==> Done: $OUT (${PYROWAVE_BUILD_VERSION_TEXT})"
echo "    Install with: ideviceinstaller -i \"$OUT\""
echo "    Or drag into Xcode > Window > Devices and Simulators"
