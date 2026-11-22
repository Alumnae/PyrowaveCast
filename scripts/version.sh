#!/bin/bash
# Shared semantic versioning helper for PyrowaveCast macOS and iOS packaging scripts.
#
# Versioning policy:
#   - patch (default): 0.5.x -> 0.5.(x+1)  (minor fixes / incremental packages)
#   - minor / major-fix: 0.x.y -> 0.(x+1).0 (major fixes / milestones)
#   - major: x.y.z -> (x+1).0.0
#   - none (--no-bump): keep VERSION unchanged
#
# Usage when sourced from a build script:
#   source "$ROOT/scripts/version.sh"
#   pyrowave_parse_build_args "$@"   # sets PYROWAVE_BUMP_MODE and PYROWAVE_OUT_ARG
#   pyrowave_apply_version "$ROOT" "$PYROWAVE_BUMP_MODE"
#   # Exports: PYROWAVE_VERSION (e.g. 0.5.1), PYROWAVE_BUILD_NUMBER (e.g. 501),
#   #          PYROWAVE_VERSION_TAG (e.g. v0.5.1-build501)
#
# Usage standalone:
#   bash scripts/version.sh [patch|minor|major-fix|major|none]

pyrowave_parse_build_args() {
    PYROWAVE_BUMP_MODE="${PYROWAVE_BUMP:-patch}"
    PYROWAVE_OUT_ARG=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --patch)
                PYROWAVE_BUMP_MODE="patch"
                shift
                ;;
            --minor|--major-fix)
                PYROWAVE_BUMP_MODE="minor"
                shift
                ;;
            --major)
                PYROWAVE_BUMP_MODE="major"
                shift
                ;;
            --no-bump)
                PYROWAVE_BUMP_MODE="none"
                shift
                ;;
            -h|--help)
                echo "Options:"
                echo "  --patch              Increment patch version (0.5.x -> 0.5.x+1) [default]"
                echo "  --minor, --major-fix Increment minor version (0.x.y -> 0.x+1.0)"
                echo "  --major              Increment major version (x.y.z -> x+1.0.0)"
                echo "  --no-bump            Keep current VERSION unchanged"
                echo "  [output path]        Optional custom output bundle/IPA path"
                exit 0
                ;;
            *)
                if [[ -z "$PYROWAVE_OUT_ARG" ]]; then
                    PYROWAVE_OUT_ARG="$1"
                    shift
                else
                    echo "error: unexpected argument: $1" >&2
                    exit 1
                fi
                ;;
        esac
    done
}

pyrowave_apply_version() {
    local root="$1"
    local mode="${2:-patch}"
    local version_file="$root/VERSION"

    local current="0.5.0"
    if [[ -f "$version_file" ]]; then
        current="$(tr -d '[:space:]' < "$version_file")"
    fi

    if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "error: invalid VERSION '$current' in $version_file (expected MAJOR.MINOR.PATCH)" >&2
        exit 1
    fi

    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"

    case "$mode" in
        patch)
            patch=$((patch + 1))
            ;;
        minor|major-fix)
            minor=$((minor + 1))
            patch=0
            ;;
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        none)
            ;;
        *)
            echo "error: unknown bump mode '$mode' (use patch, minor, major-fix, major, or none)" >&2
            exit 1
            ;;
    esac

    PYROWAVE_VERSION="${major}.${minor}.${patch}"
    PYROWAVE_BUILD_NUMBER=$((major * 10000 + minor * 100 + patch))
    PYROWAVE_VERSION_TAG="v${PYROWAVE_VERSION}-build${PYROWAVE_BUILD_NUMBER}"
    export PYROWAVE_VERSION PYROWAVE_BUILD_NUMBER PYROWAVE_VERSION_TAG

    printf '%s\n' "$PYROWAVE_VERSION" > "$version_file"

    # Keep the iOS Xcode project's Info.plist synchronized with VERSION.
    local ios_plist="$root/iOSServer/iPyroServer/Info.plist"
    if [[ -f "$ios_plist" && -x /usr/libexec/PlistBuddy ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PYROWAVE_VERSION" "$ios_plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PYROWAVE_BUILD_NUMBER" "$ios_plist"
    fi

    echo "==> Version: $PYROWAVE_VERSION (build $PYROWAVE_BUILD_NUMBER, mode: $mode)"
}

# Allow standalone invocation: bash scripts/version.sh [mode]
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    _ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    pyrowave_apply_version "$_ROOT" "${1:-none}"
fi
