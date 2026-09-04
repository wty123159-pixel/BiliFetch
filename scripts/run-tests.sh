#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TEST_BINARY="$PROJECT_DIR/.build/bilifetch-self-test"

mkdir -p "$PROJECT_DIR/.build"
swiftc \
    "$PROJECT_DIR/Sources/BiliFetch/DownloadOptions.swift" \
    "$PROJECT_DIR/Sources/BiliFetch/CollectionModels.swift" \
    "$PROJECT_DIR/Sources/BiliFetch/AppUpdateModels.swift" \
    "$PROJECT_DIR/Sources/BiliFetch/ProcessRunner.swift" \
    "$PROJECT_DIR/Tests/SelfTest/main.swift" \
    -o "$TEST_BINARY"
"$TEST_BINARY"
