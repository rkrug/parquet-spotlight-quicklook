#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/tests"
BIN="$OUT_DIR/core_tests"
SWIFT_MODULE_CACHE="$ROOT_DIR/build/swift-module-cache"
SDK_PATH="$(xcrun --show-sdk-path)"

mkdir -p "$OUT_DIR"
mkdir -p "$SWIFT_MODULE_CACHE"

xcrun swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -sdk "$SDK_PATH" \
  -O \
  "$ROOT_DIR"/Sources/ParquetCore/*.swift \
  "$ROOT_DIR/Tests/core_tests.swift" \
  -o "$BIN"

"$BIN"
