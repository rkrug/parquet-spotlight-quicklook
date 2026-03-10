#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_SRC="$ROOT_DIR/build/Parquet.mdimporter"
APP_SRC="$ROOT_DIR/build/ParquetPreviewHost.app"
BUNDLE_DST="$HOME/Library/Spotlight/Parquet.mdimporter"
APP_DST="$HOME/Applications/ParquetPreviewHost.app"
APPEX_DST="$APP_DST/Contents/PlugIns/ParquetPreview.appex"

if [[ ! -d "$BUNDLE_SRC" ]]; then
  echo "Importer bundle not found. Run scripts/build.sh first." >&2
  exit 1
fi

if [[ ! -d "$APP_SRC" ]]; then
  echo "Preview host app not found. Run scripts/build.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/Library/Spotlight" "$HOME/Applications"
rm -rf "$BUNDLE_DST" "$APP_DST" "$HOME/Library/QuickLook/Parquet.qlgenerator"
ditto "$BUNDLE_SRC" "$BUNDLE_DST"
ditto "$APP_SRC" "$APP_DST"

xattr -cr "$BUNDLE_DST"
xattr -cr "$APP_DST"

mdimport -r "$BUNDLE_DST"
pluginkit -a "$APPEX_DST" >/dev/null 2>&1 || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

echo "Installed and registered: $BUNDLE_DST"
echo "Installed app host: $APP_DST"
echo "Embedded preview extension: $APPEX_DST"
echo "Test with: mdimport -t -d2 /path/to/file.parquet"
echo "Inspect metadata with: mdls /path/to/file.parquet"
echo "Preview with: qlmanage -p /path/to/file.parquet"
