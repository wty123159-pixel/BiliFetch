#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_PYTHON_DIR="$PROJECT_DIR/.build/douyin-python"
export PYTHONDONTWRITEBYTECODE=1
if ! PYTHONPATH="$TEST_PYTHON_DIR" python3 -c 'import yt_dlp.version; assert yt_dlp.version.__version__ == "2026.08.19"' 2>/dev/null; then
    python3 -m pip install --disable-pip-version-check --upgrade --target "$TEST_PYTHON_DIR" 'yt-dlp==2026.8.19'
fi
PYTHONPATH="$TEST_PYTHON_DIR" python3 "$PROJECT_DIR/Tests/Extractor/test_douyin_share.py"
