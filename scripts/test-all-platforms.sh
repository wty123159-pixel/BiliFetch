#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PNPM_BIN="${PNPM_BIN:-/Users/santoswang/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/fallback/pnpm}"
NODE_BIN="${NODE_BIN:-/Users/santoswang/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node}"

if [[ ! -x "$PNPM_BIN" ]]; then PNPM_BIN="$(command -v pnpm || true)"; fi
if [[ ! -x "$NODE_BIN" ]]; then NODE_BIN="$(command -v node || true)"; fi
if [[ -z "$PNPM_BIN" || -z "$NODE_BIN" ]]; then
    print "需要 Node.js 20+ 和 pnpm。"
    exit 1
fi

"$PROJECT_DIR/scripts/run-tests.sh"
"$NODE_BIN" --test "$PROJECT_DIR/scripts/tests/"*.test.mjs

cd "$PROJECT_DIR/Windows"
"$PNPM_BIN" install --frozen-lockfile --config.node-linker=hoisted
"$NODE_BIN" --check main.js
"$NODE_BIN" --check renderer/app.js
"$NODE_BIN" --test tests/*.test.js

print ""
print "macOS 与 Windows 测试全部通过。"
