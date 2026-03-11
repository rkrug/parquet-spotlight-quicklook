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

run "qlmanage -r >/dev/null 2>&1 || true"
run "qlmanage -r cache >/dev/null 2>&1 || true"
run "killall quicklookd QuickLookUIService Finder >/dev/null 2>&1 || true"

echo "Uninstalled Parquet Spotlight importer and Quick Look app from user locations."
echo "Removed: $BUNDLE_DST"
echo "Removed: $APP_DST"
echo "Removed (legacy): $LEGACY_QUICKVIEW_APP_DST"
echo "Removed (legacy): $LEGACY_APP_DST"
echo "Removed legacy generator (if present): $LEGACY_QL_DST"
