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
BUNDLED_TOOLS_DIR="$BUILD_DIR/bundled-tools"

mkdir -p "$DIST_DIR" "$BUILD_DIR"
cd "$WINDOWS_DIR"
"$PNPM_BIN" install --frozen-lockfile --config.node-linker=hoisted
"$PNPM_BIN" test
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
"$PNPM_BIN" run package:win

LOCALES_DIR="$BUILD_DIR/BiliFetch-win32-x64/locales"
for locale_file in "$LOCALES_DIR"/*.pak; do
  case "${locale_file:t}" in
    en-US.pak|zh-CN.pak|zh-TW.pak) ;;
    *) find "$locale_file" -delete ;;
  esac
done

"$PROJECT_DIR/scripts/prepare-windows-tools.sh" "$BUNDLED_TOOLS_DIR"
PACKAGED_TOOLS_DIR="$BUILD_DIR/BiliFetch-win32-x64/resources/tools"
mkdir -p "$PACKAGED_TOOLS_DIR"
cp "$BUNDLED_TOOLS_DIR"/* "$PACKAGED_TOOLS_DIR/"

for tool_name in yt-dlp.exe ffmpeg.exe ffprobe.exe aria2c.exe; do
  if [[ ! -s "$PACKAGED_TOOLS_DIR/$tool_name" ]]; then
    echo "Windows 发布包缺少内置组件：$tool_name"
    exit 1
  fi
  if ! file "$PACKAGED_TOOLS_DIR/$tool_name" | grep -q 'PE32'; then
    echo "Windows 内置组件格式错误：$tool_name"
    exit 1
  fi
done

FFMPEG_RUNTIME_FILES=(
  avcodec-63.dll
  avdevice-63.dll
  avfilter-12.dll
  avformat-63.dll
  avutil-61.dll
  swresample-7.dll
  swscale-10.dll
)
for runtime_file in "${FFMPEG_RUNTIME_FILES[@]}"; do
  if [[ ! -s "$PACKAGED_TOOLS_DIR/$runtime_file" ]]; then
    echo "Windows 发布包的 FFmpeg 共享运行库不完整：缺少 $runtime_file"
    exit 1
  fi
  if ! file "$PACKAGED_TOOLS_DIR/$runtime_file" | grep -q 'PE32'; then
    echo "Windows FFmpeg 共享运行库格式错误：$runtime_file"
    exit 1
  fi
done

cp "$WINDOWS_DIR/README.md" "$BUILD_DIR/BiliFetch-win32-x64/README-Windows.md"
cp "$WINDOWS_DIR/THIRD_PARTY_NOTICES.txt" "$BUILD_DIR/BiliFetch-win32-x64/THIRD_PARTY_NOTICES.txt"
mkdir -p "$BUILD_DIR/BiliFetch-win32-x64/ThirdPartyLicenses"
cp "$PROJECT_DIR/Vendor/Tools/FFmpeg-COPYING.LGPLv2.1" "$BUILD_DIR/BiliFetch-win32-x64/ThirdPartyLicenses/FFmpeg-COPYING.LGPLv2.1"
cp "$PROJECT_DIR/Vendor/Tools/aria2-COPYING" "$BUILD_DIR/BiliFetch-win32-x64/ThirdPartyLicenses/aria2-COPYING"

cd "$BUILD_DIR"
find "$DIST_DIR" -maxdepth 1 -name "$ARCHIVE_NAME" -delete
COPYFILE_DISABLE=1 zip -9qry "$DIST_DIR/$ARCHIVE_NAME" "BiliFetch-win32-x64"
shasum -a 256 "$DIST_DIR/$ARCHIVE_NAME"

if [[ -n "${BILIFETCH_UPDATE_DOWNLOAD_URL:-}" ]]; then
  "$NODE_BIN" "$PROJECT_DIR/scripts/create-windows-update-manifest.mjs" \
    "$DIST_DIR/$ARCHIVE_NAME" \
    "$BILIFETCH_UPDATE_DOWNLOAD_URL" \
    "${BILIFETCH_UPDATE_NOTES_FILE:-}" \
    "$DIST_DIR/windows-update.json"
fi
