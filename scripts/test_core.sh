#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/tests"
BIN="$OUT_DIR/core_tests"
SWIFT_MODULE_CACHE="$ROOT_DIR/build/swift-module-cache"
SDK_PATH="$(xcrun --show-sdk-path)"

mkdir -p "$OUT_DIR"
mkdir -p "$SWIFT_MODULE_CACHE"

# Vendored zstd decoder used by ParquetRowReader (see scripts/build.sh).
xcrun clang -isysroot "$SDK_PATH" -O2 -c "$ROOT_DIR/third_party/zstd/parquet_zstd.c" -o "$OUT_DIR/parquet_zstd.o"

xcrun swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -sdk "$SDK_PATH" \
  -O \
  -import-objc-header "$ROOT_DIR/third_party/zstd/parquet_zstd.h" \
  "$ROOT_DIR"/Sources/ParquetCore/*.swift \
  "$ROOT_DIR/Tests/core_tests.swift" \
  "$OUT_DIR/parquet_zstd.o" \
  -o "$BIN"

PARQUET_FIXTURES_DIR="$ROOT_DIR/Tests/fixtures" "$BIN"
