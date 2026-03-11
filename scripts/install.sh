#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_SRC="$ROOT_DIR/build/Parquet.mdimporter"
APP_SRC="$ROOT_DIR/build/Parquet Quick Look and Index.app"
BUNDLE_DST="$HOME/Library/Spotlight/Parquet.mdimporter"
APP_DST="$HOME/Applications/Parquet Quick Look and Index.app"
APPEX_DST="$APP_DST/Contents/PlugIns/ParquetQuickLook.appex"
LEGACY_APP_DST="$HOME/Applications/ParquetPreviewHost.app"
LEGACY_QUICKVIEW_APP_DST="$HOME/Applications/Parquet QuickView and Index.app"
BUILD_APPEX_NEW="$ROOT_DIR/build/Parquet Quick Look and Index.app/Contents/PlugIns/ParquetQuickLook.appex"
BUILD_APPEX_QUICKVIEW="$ROOT_DIR/build/Parquet QuickView and Index.app/Contents/PlugIns/ParquetQuickView.appex"
BUILD_APPEX_OLD="$ROOT_DIR/build/ParquetPreviewHost.app/Contents/PlugIns/ParquetPreview.appex"
SYSTEM_APPEX_NEW="/Applications/Parquet Quick Look and Index.app/Contents/PlugIns/ParquetQuickLook.appex"
SYSTEM_APPEX_QUICKVIEW="/Applications/Parquet QuickView and Index.app/Contents/PlugIns/ParquetQuickView.appex"
SYSTEM_APPEX_OLD="/Applications/ParquetPreviewHost.app/Contents/PlugIns/ParquetPreview.appex"
USER_APPEX_QUICKVIEW="$HOME/Applications/Parquet QuickView and Index.app/Contents/PlugIns/ParquetQuickView.appex"
USER_APPEX_OLD="$HOME/Applications/ParquetPreviewHost.app/Contents/PlugIns/ParquetPreview.appex"

if [[ ! -d "$BUNDLE_SRC" ]]; then
  echo "Importer bundle not found. Run scripts/build.sh first." >&2
  exit 1
fi

if [[ ! -d "$APP_SRC" ]]; then
  echo "Quick Look app not found. Run scripts/build.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/Library/Spotlight" "$HOME/Applications"
rm -rf "$BUNDLE_DST" "$APP_DST" "$LEGACY_APP_DST" "$LEGACY_QUICKVIEW_APP_DST" "$HOME/Library/QuickLook/Parquet.qlgenerator"
mkdir -p "$BUNDLE_DST" "$APP_DST"
rsync -a --delete "$BUNDLE_SRC/" "$BUNDLE_DST/"
rsync -a --delete "$APP_SRC/" "$APP_DST/"

xattr -cr "$BUNDLE_DST"
xattr -cr "$APP_DST"

if [[ ! -f "$APPEX_DST/Contents/Info.plist" ]]; then
  # Retry once: some systems intermittently expose incomplete copied app bundles
  # immediately after sync when queried by path.
  rsync -a --delete "$APP_SRC/" "$APP_DST/"
fi

if [[ ! -f "$APPEX_DST/Contents/Info.plist" ]]; then
  echo "FAIL: Installed Quick Look extension is incomplete (missing Info.plist): $APPEX_DST" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$APP_DST" >/dev/null 2>&1; then
  echo "FAIL: Installed Quick Look app failed code signature verification: $APP_DST" >&2
  exit 1
fi

# Ensure stale registrations from build/legacy paths do not take precedence.
for stale in "$BUILD_APPEX_NEW" "$BUILD_APPEX_QUICKVIEW" "$BUILD_APPEX_OLD" "$SYSTEM_APPEX_NEW" "$SYSTEM_APPEX_QUICKVIEW" "$SYSTEM_APPEX_OLD" "$USER_APPEX_QUICKVIEW" "$USER_APPEX_OLD"; do
  if [[ -d "$stale" ]]; then
    pluginkit -r "$stale" >/dev/null 2>&1 || true
  fi
done

mdimport -r "$BUNDLE_DST"
pluginkit -a "$APPEX_DST" >/dev/null 2>&1 || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

echo "Installed and registered: $BUNDLE_DST"
echo "Installed app: $APP_DST"
echo "Embedded Quick Look extension: $APPEX_DST"
echo "Test with: mdimport -t -d2 /path/to/file.parquet"
echo "Inspect metadata with: mdls /path/to/file.parquet"
echo "Quick Look with: qlmanage -p /path/to/file.parquet"
