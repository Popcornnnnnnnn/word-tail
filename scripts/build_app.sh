#!/usr/bin/env bash
set -euo pipefail

SCRATCH_BUILD=0
INSTALL_APP=0
NOTARIZE_APP=0
RELEASE_ZIP=0
NOTARY_PROFILE="${WORDTAIL_NOTARY_PROFILE:-port-tools-notary}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scratch) SCRATCH_BUILD=1; shift ;;
        --install) INSTALL_APP=1; shift ;;
        --notarize) NOTARIZE_APP=1; RELEASE_ZIP=1; shift ;;
        --release-zip) RELEASE_ZIP=1; shift ;;
        --notary-profile)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "Error: --notary-profile requires a profile name." >&2
                exit 1
            fi
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --notary-profile=*)
            NOTARY_PROFILE="${1#*=}"
            if [[ -z "$NOTARY_PROFILE" ]]; then
                echo "Error: --notary-profile requires a profile name." >&2
                exit 1
            fi
            shift
            ;;
        *)
            echo "Usage: $0 [--scratch] [--install] [--notarize] [--release-zip] [--notary-profile <profile>]" >&2
            exit 1
            ;;
    esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$SCRATCH_BUILD" -eq 0 ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Error: Working tree is dirty. Commit changes before building a release candidate, or pass --scratch for a dev test build." >&2
        exit 1
    fi
fi

DEV_ID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ {print $2; exit}')"
APPLE_DEV_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}')"

if [[ "$NOTARIZE_APP" -eq 1 && -z "$DEV_ID_IDENTITY" ]]; then
    echo "Error: --notarize requires a Developer ID Application certificate in your keychain." >&2
    exit 1
fi

echo "==> Building WordTail (release)..."
swift build -c release

APP_DIR="$ROOT_DIR/dist/WordTail.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "==> Generating AppIcon.icns..."
ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT_DIR/scripts/make_icon.swift" "$ICONSET_TMP"
iconutil -c icns "$ICONSET_TMP" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_TMP")"

cp "$ROOT_DIR/.build/release/WordTail" "$APP_DIR/Contents/MacOS/WordTail"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Prefer Developer ID Application so updates install cleanly across Macs and preserve macOS TCC permissions,
# falling back to Apple Development or ad-hoc (-) for local source builds.
if [[ -n "$DEV_ID_IDENTITY" ]]; then
    echo "==> Signing with Developer ID Application certificate (hardened runtime)..."
    codesign --force --deep --options runtime --timestamp --sign "$DEV_ID_IDENTITY" "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR"
elif [[ -n "$APPLE_DEV_IDENTITY" ]]; then
    echo "==> Signing with Apple Development certificate..."
    codesign --force --deep --sign "$APPLE_DEV_IDENTITY" "$APP_DIR"
else
    echo "==> Signing with ad-hoc identity (-)"
    codesign --force --deep --sign "-" "$APP_DIR"
fi
echo "==> Built: $APP_DIR"

if [[ "$NOTARIZE_APP" -eq 1 ]]; then
    TMP_NOTARY_ZIP="$ROOT_DIR/dist/WordTail-notary.zip"
    rm -f "$TMP_NOTARY_ZIP"
    echo "==> Archiving for Apple notarization..."
    ditto -c -k --keepParent "$APP_DIR" "$TMP_NOTARY_ZIP"
    echo "==> Submitting to Apple notary service (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$TMP_NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$TMP_NOTARY_ZIP"
    echo "==> Stapling and validating notarization ticket..."
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    spctl -a -vv --type execute "$APP_DIR"
fi

if [[ "$RELEASE_ZIP" -eq 1 ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/Resources/Info.plist")"
    RELEASE_ZIP_PATH="$ROOT_DIR/dist/WordTail-v${VERSION}-macOS.zip"
    rm -f "$RELEASE_ZIP_PATH"
    ditto -c -k --keepParent "$APP_DIR" "$RELEASE_ZIP_PATH"
    echo "==> Release archive: $RELEASE_ZIP_PATH"
    shasum -a 256 "$RELEASE_ZIP_PATH"
fi

if [[ "$INSTALL_APP" -eq 1 ]]; then
    rm -rf "/Applications/WordTail.app"
    cp -R "$APP_DIR" "/Applications/WordTail.app"
    echo "==> Installed: /Applications/WordTail.app"
fi
