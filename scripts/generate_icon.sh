#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET_DIR="$ROOT_DIR/build/AppIcon.iconset"
OUTPUT_ICNS="$ROOT_DIR/preview/app/AppIcon.icns"
RENDER_SCRIPT="$ROOT_DIR/scripts/render_icon.swift"
RENDER_BIN="$ROOT_DIR/build/render_icon"
SWIFT_MODULE_CACHE="$ROOT_DIR/build/swift-module-cache"
SDK_PATH="$(xcrun --show-sdk-path)"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
mkdir -p "$SWIFT_MODULE_CACHE"

swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -sdk "$SDK_PATH" \
  "$RENDER_SCRIPT" \
  -framework AppKit \
  -framework Foundation \
  -o "$RENDER_BIN"

sizes=(
  "16 icon_16x16.png"
  "32 icon_16x16@2x.png"
  "32 icon_32x32.png"
  "64 icon_32x32@2x.png"
  "128 icon_128x128.png"
  "256 icon_128x128@2x.png"
  "256 icon_256x256.png"
  "512 icon_256x256@2x.png"
  "512 icon_512x512.png"
  "1024 icon_512x512@2x.png"
)

for spec in "${sizes[@]}"; do
  size="${spec%% *}"
  file="${spec#* }"
  "$RENDER_BIN" "$size" "$ICONSET_DIR/$file"
done

python3 - <<'PY'
from PIL import Image

master = Image.open("build/AppIcon.iconset/icon_512x512@2x.png").convert("RGBA")
master.save(
    "preview/app/AppIcon.icns",
    format="ICNS",
    sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)],
)
PY
echo "Generated icon: $OUTPUT_ICNS"
