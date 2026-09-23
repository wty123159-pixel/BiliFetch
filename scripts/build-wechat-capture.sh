#!/bin/zsh
set -euo pipefail
CAPTURE_ROOT="${0:A:h:h}"
GO_BIN="${GO_BIN:-$(command -v go || true)}"
if [[ -z "$GO_BIN" && -x "$CAPTURE_ROOT/.build/toolchains/go/bin/go" ]]; then
  GO_BIN="$CAPTURE_ROOT/.build/toolchains/go/bin/go"
fi
if [[ ! -x "$GO_BIN" ]]; then print "需要 Go 1.27.1 或更新版本来编译视频号捕获组件。"; exit 1; fi
CAPTURE_BUILD="$CAPTURE_ROOT/build/wechat-capture"
mkdir -p "$CAPTURE_BUILD"
cd "$CAPTURE_ROOT/Shared/WeChatCapture"
if [[ "${1:-all}" == "test" ]]; then
  "$GO_BIN" test -race -count=1 ./...
  CGO_ENABLED=0 GOOS=windows GOARCH=amd64 "$GO_BIN" test -c -o "$CAPTURE_BUILD/capture-tests.exe" .
  exit 0
fi
if [[ "${1:-all}" == "all" || "${1:-all}" == "macos" ]]; then
  for CAPTURE_ARCH in arm64 amd64; do
    CGO_ENABLED=0 GOOS=darwin GOARCH="$CAPTURE_ARCH" "$GO_BIN" build -trimpath -ldflags="-s -w" -o "$CAPTURE_BUILD/macos-$CAPTURE_ARCH" .
  done
  lipo -create "$CAPTURE_BUILD/macos-arm64" "$CAPTURE_BUILD/macos-amd64" -output "$CAPTURE_BUILD/bilifetch-capture-macos"
fi
if [[ "${1:-all}" == "all" || "${1:-all}" == "windows" ]]; then
  CGO_ENABLED=0 GOOS=windows GOARCH=amd64 "$GO_BIN" build -trimpath -ldflags="-s -w" -o "$CAPTURE_BUILD/bilifetch-capture.exe" .
fi
cp "$("$GO_BIN" env GOROOT)/LICENSE" "$CAPTURE_BUILD/Go-LICENSE"
