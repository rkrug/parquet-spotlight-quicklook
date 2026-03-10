#!/usr/bin/env zsh
set -euo pipefail

BUNDLE_PATH="$HOME/Library/Spotlight/Parquet.mdimporter"
APP_PATH="$HOME/Applications/ParquetPreviewHost.app"
APPEX_PATH="$APP_PATH/Contents/PlugIns/ParquetPreview.appex"

if [[ ! -d "$BUNDLE_PATH" ]]; then
  echo "FAIL: Importer bundle not found at $BUNDLE_PATH"
  exit 1
fi

if ! mdimport -L | rg -Fq "$BUNDLE_PATH"; then
  echo "FAIL: Importer bundle is not registered in mdimport -L output"
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "FAIL: Preview host app not found at $APP_PATH"
  exit 1
fi

if [[ ! -d "$APPEX_PATH" ]]; then
  echo "FAIL: Embedded preview extension missing at $APPEX_PATH"
  exit 1
fi

PREVIEW_REGISTERED="yes"
if ! pluginkit -mAvvv -i com.rkrug.parquetindexer.previewhost.preview | rg -Fq "com.rkrug.parquetindexer.previewhost.preview"; then
  PREVIEW_REGISTERED="no"
fi

TARGET_FILE="${1:-}"
TEMP_DIR=""

if [[ -z "$TARGET_FILE" ]]; then
  TARGET_FILE="$(mdfind 'kMDItemFSName == "*.parquet"' | head -n 1 || true)"
fi

if [[ -z "$TARGET_FILE" ]]; then
  TEMP_DIR="$(mktemp -d /tmp/parquet_indexer_test.XXXXXX)"
  TARGET_FILE="$TEMP_DIR/test.parquet"
  perl -e 'print "PAR1"; print "\x00" x 16; print pack("V",0); print "PAR1";' > "$TARGET_FILE"
fi

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "FAIL: Target parquet file does not exist: $TARGET_FILE"
  [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  exit 1
fi

TEST_OUTPUT="$(mdimport -t -d2 "$TARGET_FILE" 2>&1 || true)"

if ! print -r -- "$TEST_OUTPUT" | rg -Fq "with plugIn $BUNDLE_PATH"; then
  echo "FAIL: Spotlight did not select Parquet importer for: $TARGET_FILE"
  echo
  echo "mdimport output:"
  echo "$TEST_OUTPUT"
  [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  exit 1
fi

if ! print -r -- "$TEST_OUTPUT" | rg -Fq "kMDItemKind = \"Apache Parquet file\""; then
  echo "FAIL: Importer ran, but expected Parquet metadata was not found"
  echo
  echo "mdimport output:"
  echo "$TEST_OUTPUT"
  [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  exit 1
fi

echo "PASS: Parquet Spotlight importer is installed and active"
echo "Bundle: $BUNDLE_PATH"
echo "Preview host app: $APP_PATH"
echo "Embedded preview extension: $APPEX_PATH"
if [[ "$PREVIEW_REGISTERED" == "no" ]]; then
  echo "WARN: Preview extension is installed but not listed by pluginkit yet."
  echo "      Open Finder once or run: pluginkit -a \"$APPEX_PATH\""
fi
echo "Test file: $TARGET_FILE"

if [[ -n "$TEMP_DIR" ]]; then
  rm -rf "$TEMP_DIR"
fi
