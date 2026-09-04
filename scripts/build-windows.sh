#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WINDOWS_DIR="$PROJECT_DIR/Windows"
DIST_DIR="$PROJECT_DIR/dist"
BUILD_DIR="$PROJECT_DIR/build/windows"
PNPM_BIN="${PNPM_BIN:-/Users/santoswang/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/fallback/pnpm}"
NODE_BIN="${NODE_BIN:-/Users/santoswang/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node}"

if [[ ! -x "$PNPM_BIN" ]]; then
  PNPM_BIN="$(command -v pnpm || true)"
fi
if [[ -z "$PNPM_BIN" ]]; then
  echo "缺少 pnpm，请先安装 Node.js 20+ 和 pnpm。"
  exit 1
fi
if [[ ! -x "$NODE_BIN" ]]; then
  NODE_BIN="$(command -v node || true)"
fi
if [[ -z "$NODE_BIN" ]]; then
  echo "缺少 Node.js 20+。"
  exit 1
fi

# pnpm can invoke package scripts through /bin/sh, so make the selected Node
# runtime visible there as well as to the direct commands below.
export PATH="$(dirname "$NODE_BIN"):$PATH"

APP_VERSION="$("$NODE_BIN" -p "require('$WINDOWS_DIR/package.json').version")"
ARCHIVE_NAME="BiliFetch-Windows-x64-$APP_VERSION.zip"

mkdir -p "$DIST_DIR" "$BUILD_DIR"
cd "$WINDOWS_DIR"
"$PNPM_BIN" install --frozen-lockfile --config.node-linker=hoisted
"$PNPM_BIN" test
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
"$PNPM_BIN" run package:win

cp "$WINDOWS_DIR/README.md" "$BUILD_DIR/BiliFetch-win32-x64/README-Windows.md"
cp "$WINDOWS_DIR/THIRD_PARTY_NOTICES.txt" "$BUILD_DIR/BiliFetch-win32-x64/THIRD_PARTY_NOTICES.txt"

cd "$BUILD_DIR"
find "$DIST_DIR" -maxdepth 1 -name "$ARCHIVE_NAME" -delete
COPYFILE_DISABLE=1 zip -qry "$DIST_DIR/$ARCHIVE_NAME" "BiliFetch-win32-x64"
shasum -a 256 "$DIST_DIR/$ARCHIVE_NAME"

if [[ -n "${BILIFETCH_UPDATE_DOWNLOAD_URL:-}" ]]; then
  "$NODE_BIN" "$PROJECT_DIR/scripts/create-windows-update-manifest.mjs" \
    "$DIST_DIR/$ARCHIVE_NAME" \
    "$BILIFETCH_UPDATE_DOWNLOAD_URL" \
    "${BILIFETCH_UPDATE_NOTES_FILE:-}" \
    "$DIST_DIR/windows-update.json"
fi
