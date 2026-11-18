#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift test
pkill -x WordTail 2>/dev/null || true
"$ROOT_DIR/scripts/build_app.sh" --scratch --install
open "/Applications/WordTail.app"
echo "==> WordTail reloaded from /Applications/WordTail.app."
