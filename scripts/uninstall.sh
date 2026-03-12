#!/usr/bin/env zsh
set -euo pipefail

BUNDLE_DST="$HOME/Library/Spotlight/Parquet.mdimporter"
APP_DST="$HOME/Applications/Parquet Quick Look and Index.app"
APPEX_DST="$APP_DST/Contents/PlugIns/ParquetQuickLook.appex"
LEGACY_QUICKVIEW_APP_DST="$HOME/Applications/Parquet QuickView and Index.app"
LEGACY_QUICKVIEW_APPEX_DST="$LEGACY_QUICKVIEW_APP_DST/Contents/PlugIns/ParquetQuickView.appex"
LEGACY_APP_DST="$HOME/Applications/ParquetPreviewHost.app"
LEGACY_APPEX_DST="$LEGACY_APP_DST/Contents/PlugIns/ParquetPreview.appex"
LEGACY_QL_DST="$HOME/Library/QuickLook/Parquet.qlgenerator"
SETTINGS_CONTAINER="$HOME/Library/Containers/com.rkrug.parquetindexer.previewhost.preview"
SETTINGS_CONTAINER_DATA="$SETTINGS_CONTAINER/Data"
SETTINGS_SUPPORT="$HOME/Library/Application Support/ParquetPreview"
SETTINGS_CACHE="$HOME/Library/Caches/com.rkrug.parquetindexer.previewhost.preview"
SETTINGS_DOMAIN="com.rkrug.parquetindexer.previewhost.preview"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run enabled. No files will be removed."
fi

if [[ -d "$APPEX_DST" ]]; then
  run "pluginkit -r \"$APPEX_DST\" >/dev/null 2>&1 || true"
fi
if [[ -d "$LEGACY_QUICKVIEW_APPEX_DST" ]]; then
  run "pluginkit -r \"$LEGACY_QUICKVIEW_APPEX_DST\" >/dev/null 2>&1 || true"
fi
if [[ -d "$LEGACY_APPEX_DST" ]]; then
  run "pluginkit -r \"$LEGACY_APPEX_DST\" >/dev/null 2>&1 || true"
fi

run "rm -rf \"$APP_DST\""
run "rm -rf \"$LEGACY_QUICKVIEW_APP_DST\""
run "rm -rf \"$LEGACY_APP_DST\""
run "rm -rf \"$BUNDLE_DST\""
run "rm -rf \"$LEGACY_QL_DST\""
run "rm -rf \"$SETTINGS_SUPPORT\""
run "rm -rf \"$SETTINGS_CACHE\""
run "rm -rf \"$SETTINGS_CONTAINER_DATA\""
run "rm -rf \"$SETTINGS_CONTAINER\""
run "defaults delete \"$SETTINGS_DOMAIN\" >/dev/null 2>&1 || true"

run "qlmanage -r >/dev/null 2>&1 || true"
run "qlmanage -r cache >/dev/null 2>&1 || true"
run "killall quicklookd QuickLookUIService Finder >/dev/null 2>&1 || true"

echo "Uninstalled Parquet Spotlight importer and Quick Look app from user locations."
echo "Removed: $BUNDLE_DST"
echo "Removed: $APP_DST"
echo "Removed (legacy): $LEGACY_QUICKVIEW_APP_DST"
echo "Removed (legacy): $LEGACY_APP_DST"
echo "Removed legacy generator (if present): $LEGACY_QL_DST"
echo "Removed settings support: $SETTINGS_SUPPORT"
echo "Removed settings cache: $SETTINGS_CACHE"
echo "Removed settings container data: $SETTINGS_CONTAINER_DATA"
echo "Removed settings container (if permitted): $SETTINGS_CONTAINER"
echo "Removed defaults domain (if present): $SETTINGS_DOMAIN"
