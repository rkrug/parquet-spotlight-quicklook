#!/usr/bin/env zsh
set -euo pipefail

BUNDLE_DST="$HOME/Library/Spotlight/Parquet.mdimporter"
APP_DST="$HOME/Applications/ParquetPreviewHost.app"
APPEX_DST="$APP_DST/Contents/PlugIns/ParquetPreview.appex"
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

run "rm -rf \"$APP_DST\""
run "rm -rf \"$BUNDLE_DST\""
run "rm -rf \"$LEGACY_QL_DST\""

run "qlmanage -r >/dev/null 2>&1 || true"
run "qlmanage -r cache >/dev/null 2>&1 || true"
run "killall quicklookd QuickLookUIService Finder >/dev/null 2>&1 || true"

echo "Uninstalled Parquet Spotlight importer and Quick Look preview from user locations."
echo "Removed: $BUNDLE_DST"
echo "Removed: $APP_DST"
echo "Removed legacy generator (if present): $LEGACY_QL_DST"
