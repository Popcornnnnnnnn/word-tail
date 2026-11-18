#!/usr/bin/env bash
set -euo pipefail

SCRATCH_BUILD=0
INSTALL_APP=0

for arg in "$@"; do
    case "$arg" in
        --scratch) SCRATCH_BUILD=1 ;;
        --install) INSTALL_APP=1 ;;
        *)
            echo "Usage: $0 [--scratch] [--install]" >&2
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

# Prefer a stable local Apple Development identity so macOS TCC Accessibility permissions persist across rebuilds.
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}')"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
    echo "==> Signing with ad-hoc identity (-)"
else
    echo "==> Signing with Apple Development certificate..."
fi

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
echo "==> Built: $APP_DIR"

if [[ "$INSTALL_APP" -eq 1 ]]; then
    rm -rf "/Applications/WordTail.app"
    cp -R "$APP_DIR" "/Applications/WordTail.app"
    echo "==> Installed: /Applications/WordTail.app"
fi
