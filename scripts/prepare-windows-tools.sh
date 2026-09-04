#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
CACHE_DIR="${BILIFETCH_WINDOWS_TOOL_CACHE:-$PROJECT_DIR/build/windows-tools-cache}"
DESTINATION="${1:-$PROJECT_DIR/build/windows-bundled-tools}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bilifetch-windows-tools.XXXXXX")"

YTDLP_VERSION="2026.08.19"
YTDLP_ARCHIVE="yt-dlp-$YTDLP_VERSION.exe"
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp.exe"
YTDLP_SHA256="66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a"

FFMPEG_VERSION="n9.0.1-11-ge47273f4d9"
FFMPEG_ARCHIVE="ffmpeg-$FFMPEG_VERSION-win64-lgpl-shared-9.0.zip"
FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-09-02-13-13/$FFMPEG_ARCHIVE"
FFMPEG_SHA256="ce5ad562220905f976c57442ac2e752e8d80ab6c0a668c2caa2b3d39dde6636f"
FFMPEG_RUNTIME_FILES=(
    avcodec-63.dll
    avdevice-63.dll
    avfilter-12.dll
    avformat-63.dll
    avutil-61.dll
    swresample-7.dll
    swscale-10.dll
)

ARIA2_VERSION="1.37.0"
ARIA2_ARCHIVE="aria2-$ARIA2_VERSION-win-64bit-build1.zip"
ARIA2_URL="https://github.com/aria2/aria2/releases/download/release-$ARIA2_VERSION/$ARIA2_ARCHIVE"
# aria2's release does not publish a digest. This value is pinned from the
# immutable GitHub release asset and prevents a changed binary being packaged.
ARIA2_SHA256="67d015301eef0b612191212d564c5bb0a14b5b9c4796b76454276a4d28d9b288"

cleanup() {
    find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

download_verified() {
    local url="$1"
    local destination="$2"
    local expected="$3"
    local label="$4"

    if [[ -f "$destination" && "$(sha256_of "$destination")" == "$expected" ]]; then
        print "使用缓存：$label"
        return
    fi
    for stale_file in "$destination" "$destination.aria2"; do
        if [[ -f "$stale_file" ]]; then
            find "$stale_file" -delete
        fi
    done

    print "下载：$label"
    local bundled_aria2="$PROJECT_DIR/Vendor/Tools/aria2c"
    if [[ -x "$bundled_aria2" ]]; then
        local proxy_arguments=()
        if [[ -n "${BILIFETCH_BUILD_PROXY:-}" ]]; then
            proxy_arguments=(--all-proxy="$BILIFETCH_BUILD_PROXY")
        fi
        "$bundled_aria2" \
            "${proxy_arguments[@]}" \
            --allow-overwrite=true \
            --auto-file-renaming=false \
            --continue=true \
            --file-allocation=none \
            --max-connection-per-server=8 \
            --min-split-size=1M \
            --split=8 \
            --dir="${destination:h}" \
            --out="${destination:t}" \
            "$url"
    else
        curl -fL --retry 3 --connect-timeout 20 "$url" -o "$destination"
    fi

    local actual="$(sha256_of "$destination")"
    if [[ "$actual" != "$expected" ]]; then
        print "校验失败：$label"
        print "预期：$expected"
        print "实际：$actual"
        exit 1
    fi
}

find_one() {
    local root="$1"
    local name="$2"
    local found="$(find "$root" -type f -iname "$name" -print -quit)"
    if [[ -z "$found" ]]; then
        print "组件压缩包中缺少 $name"
        exit 1
    fi
    print "$found"
}

mkdir -p "$CACHE_DIR"
download_verified "$YTDLP_URL" "$CACHE_DIR/$YTDLP_ARCHIVE" "$YTDLP_SHA256" "yt-dlp $YTDLP_VERSION"
download_verified "$FFMPEG_URL" "$CACHE_DIR/$FFMPEG_ARCHIVE" "$FFMPEG_SHA256" "FFmpeg $FFMPEG_VERSION"
download_verified "$ARIA2_URL" "$CACHE_DIR/$ARIA2_ARCHIVE" "$ARIA2_SHA256" "aria2 $ARIA2_VERSION"

mkdir -p "$TEMP_DIR/ffmpeg" "$TEMP_DIR/aria2"
unzip -q "$CACHE_DIR/$FFMPEG_ARCHIVE" -d "$TEMP_DIR/ffmpeg"
unzip -q "$CACHE_DIR/$ARIA2_ARCHIVE" -d "$TEMP_DIR/aria2"

if [[ -d "$DESTINATION" ]]; then
    find "$DESTINATION" -depth -delete
fi
mkdir -p "$DESTINATION"
cp "$CACHE_DIR/$YTDLP_ARCHIVE" "$DESTINATION/yt-dlp.exe"
FFMPEG_BIN_DIR="$(dirname "$(find_one "$TEMP_DIR/ffmpeg" ffmpeg.exe)")"
cp "$FFMPEG_BIN_DIR/ffmpeg.exe" "$DESTINATION/ffmpeg.exe"
cp "$FFMPEG_BIN_DIR/ffprobe.exe" "$DESTINATION/ffprobe.exe"
cp "$FFMPEG_BIN_DIR"/*.dll "$DESTINATION/"
cp "$(find_one "$TEMP_DIR/aria2" aria2c.exe)" "$DESTINATION/aria2c.exe"

for executable in yt-dlp.exe ffmpeg.exe ffprobe.exe aria2c.exe; do
    if [[ ! -s "$DESTINATION/$executable" ]]; then
        print "内置组件无效：$executable"
        exit 1
    fi
done

for runtime_file in "${FFMPEG_RUNTIME_FILES[@]}"; do
    if [[ ! -s "$DESTINATION/$runtime_file" ]]; then
        print "FFmpeg 共享运行库不完整：缺少 $runtime_file"
        exit 1
    fi
done

printf '%s\n' \
    "BiliFetch bundled Windows tools" \
    "yt-dlp $YTDLP_VERSION | $YTDLP_URL | SHA-256 $YTDLP_SHA256" \
    "FFmpeg $FFMPEG_VERSION LGPL shared | $FFMPEG_URL | SHA-256 $FFMPEG_SHA256" \
    "aria2 $ARIA2_VERSION | $ARIA2_URL | SHA-256 $ARIA2_SHA256" \
    > "$DESTINATION/VERSIONS.txt"

print "Windows 内置组件已准备：$DESTINATION"
