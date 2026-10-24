#!/usr/bin/env zsh
set -euo pipefail

# Builds the importer's Swift bridge with a small C harness and checks the Spotlight
# importer entry point against Tests/fixtures/expected.txt (Arrow-derived expectations).
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/tests"
BIN="$OUT_DIR/importer_summary_tests"
SWIFT_MODULE_CACHE="$ROOT_DIR/build/swift-module-cache"
SDK_PATH="$(xcrun --show-sdk-path)"

mkdir -p "$OUT_DIR" "$SWIFT_MODULE_CACHE"

xcrun swiftc \
  -parse-as-library \
  -module-name ParquetImporter \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -sdk "$SDK_PATH" \
  -O -wmo \
  -emit-object \
  "$ROOT_DIR/Sources/ParquetCore/ParserBounds.swift" \
  "$ROOT_DIR/Sources/ParquetCore/ParquetFooterParser.swift" \
  "$ROOT_DIR/src/ImporterBridge.swift" \
  -o "$OUT_DIR/ImporterSwift.o"

xcrun clang -O2 -Wall -Wextra -Werror \
  -isysroot "$SDK_PATH" \
  "$ROOT_DIR/Tests/importer_summary_tests.c" \
  "$OUT_DIR/ImporterSwift.o" \
  -L "$SDK_PATH/usr/lib/swift" \
  -L "$(dirname "$(xcrun --find swiftc)")/../lib/swift/macosx" \
  -Wl,-rpath,/usr/lib/swift \
  -framework CoreFoundation \
  -o "$BIN"

"$BIN" "$ROOT_DIR/Tests/fixtures"
