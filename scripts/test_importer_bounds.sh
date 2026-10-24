#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/tests"
BIN="$OUT_DIR/importer_bounds_tests"

mkdir -p "$OUT_DIR"

cc -O2 -Wall -Wextra -Werror \
  -o "$BIN" \
  "$ROOT_DIR/Tests/importer_bounds_tests.c"

"$BIN"
