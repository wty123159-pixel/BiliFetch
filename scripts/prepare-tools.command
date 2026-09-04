#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
TOOLS_DIR="$HOME/Library/Application Support/BiliFetch/Tools"
WORK_DIR="$(mktemp -d -t bilifetch-tools)"
FFMPEG_TAG="n7.1.5"

finish() {
    local result=$?
    rm -rf "$WORK_DIR"
    if (( result != 0 )); then
        print ""
        print "组件准备失败，请检查上方错误信息和网络连接。"
        print "按回车键关闭窗口。"
        read -r
    fi
    return $result
}
trap finish EXIT

mkdir -p "$TOOLS_DIR"

print "BiliFetch 下载组件准备"
print "安装位置：$TOOLS_DIR"
print ""

if [[ -x "$SCRIPT_DIR/Tools/yt-dlp" ]]; then
    cp "$SCRIPT_DIR/Tools/yt-dlp" "$WORK_DIR/yt-dlp"
else
    curl -fL --retry 3 "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$WORK_DIR/yt-dlp"
fi
chmod +x "$WORK_DIR/yt-dlp"
mv "$WORK_DIR/yt-dlp" "$TOOLS_DIR/yt-dlp"
print "yt-dlp 已安装。"

if [[ -x "$SCRIPT_DIR/Tools/aria2c" ]]; then
    cp "$SCRIPT_DIR/Tools/aria2c" "$TOOLS_DIR/aria2c"
    chmod +x "$TOOLS_DIR/aria2c"
    print "aria2 已安装。"
fi

if [[ -x "$SCRIPT_DIR/Tools/ffmpeg" ]]; then
    cp "$SCRIPT_DIR/Tools/ffmpeg" "$TOOLS_DIR/ffmpeg"
    [[ -x "$SCRIPT_DIR/Tools/ffprobe" ]] && cp "$SCRIPT_DIR/Tools/ffprobe" "$TOOLS_DIR/ffprobe"
elif [[ -x /opt/homebrew/bin/ffmpeg ]]; then
    cp /opt/homebrew/bin/ffmpeg "$TOOLS_DIR/ffmpeg"
    [[ -x /opt/homebrew/bin/ffprobe ]] && cp /opt/homebrew/bin/ffprobe "$TOOLS_DIR/ffprobe"
elif [[ -x /usr/local/bin/ffmpeg ]]; then
    cp /usr/local/bin/ffmpeg "$TOOLS_DIR/ffmpeg"
    [[ -x /usr/local/bin/ffprobe ]] && cp /usr/local/bin/ffprobe "$TOOLS_DIR/ffprobe"
else
    print "未发现内嵌 FFmpeg，请从完整的 BiliFetch App 重新运行此脚本。"
    exit 1
fi

chmod +x "$TOOLS_DIR/ffmpeg" "$TOOLS_DIR/ffprobe" 2>/dev/null || true
print ""
"$TOOLS_DIR/yt-dlp" --version
"$TOOLS_DIR/ffmpeg" -version | head -n 1
[[ -x "$TOOLS_DIR/aria2c" ]] && "$TOOLS_DIR/aria2c" --version | head -n 1
print ""
print "全部组件准备完成。请回到 BiliFetch。"
print "按回车键关闭窗口。"
read -r
