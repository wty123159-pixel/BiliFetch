#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE="$PROJECT_DIR/Assets/BiliFetch-AppIcon.png"
ICONSET="$PROJECT_DIR/.build/AppIcon.iconset"
NODE_BIN="${NODE_BIN:-/Users/santoswang/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node}"
if [[ ! -x "$NODE_BIN" ]]; then NODE_BIN="$(command -v node)"; fi

mkdir -p "$ICONSET"
for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" "$SOURCE" --out "$ICONSET/icon_${icon_size}x${icon_size}.png" >/dev/null
    icon_double=$((icon_size * 2))
    sips -z "$icon_double" "$icon_double" "$SOURCE" --out "$ICONSET/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$PROJECT_DIR/Assets/BiliFetch.icns"
sips -z 1024 1024 "$SOURCE" --out "$PROJECT_DIR/Windows/assets/icon.png" >/dev/null
cd "$PROJECT_DIR/Windows"
"$NODE_BIN" --input-type=module <<'JS'
import fs from 'node:fs/promises';
import pngToIco from 'png-to-ico';
await fs.writeFile('assets/icon.ico', await pngToIco('assets/icon.png'));
JS
print "Updated macOS and Windows icons."
