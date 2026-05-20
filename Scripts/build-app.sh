#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CryptoTickerBar"
APP_DIR="$ROOT_DIR/.build/${APP_NAME}.app"
SCRATCH_DIR="$ROOT_DIR/.build/local"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/clang-module-cache}"

swift build -c release --scratch-path "$SCRATCH_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH_DIR" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
