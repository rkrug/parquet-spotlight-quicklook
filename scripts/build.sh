#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"

# Spotlight importer bundle
MD_BUNDLE_DIR="$BUILD_DIR/Parquet.mdimporter"
MD_MACOS_DIR="$MD_BUNDLE_DIR/Contents/MacOS"
MD_RESOURCES_DIR="$MD_BUNDLE_DIR/Contents/Resources"

# Modern Quick Look preview extension hosted in app bundle
APP_BUNDLE_DIR="$BUILD_DIR/Parquet Quick Look and Index.app"
APP_CONTENTS_DIR="$APP_BUNDLE_DIR/Contents"
APP_MACOS_DIR="$APP_CONTENTS_DIR/MacOS"
APP_PLUGINS_DIR="$APP_CONTENTS_DIR/PlugIns"
APP_RESOURCES_DIR="$APP_CONTENTS_DIR/Resources"

APPEX_DIR="$APP_PLUGINS_DIR/ParquetQuickLook.appex"
APPEX_CONTENTS_DIR="$APPEX_DIR/Contents"
APPEX_MACOS_DIR="$APPEX_CONTENTS_DIR/MacOS"

LEGACY_APP_BUNDLE_DIR="$BUILD_DIR/ParquetPreviewHost.app"
LEGACY_QUICKVIEW_APP_BUNDLE_DIR="$BUILD_DIR/Parquet QuickView and Index.app"
LEGACY_QLGEN_DIR="$BUILD_DIR/Parquet.qlgenerator"

rm -rf "$MD_BUNDLE_DIR" "$APP_BUNDLE_DIR" "$LEGACY_APP_BUNDLE_DIR" "$LEGACY_QUICKVIEW_APP_BUNDLE_DIR" "$LEGACY_QLGEN_DIR"
mkdir -p "$MD_MACOS_DIR" "$MD_RESOURCES_DIR" "$APP_MACOS_DIR" "$APP_RESOURCES_DIR" "$APPEX_MACOS_DIR"

SDK_PATH="$(xcrun --show-sdk-path)"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"
mkdir -p "$SWIFT_MODULE_CACHE"

sanitize_bundle() {
  local bundle_path="$1"
  xattr -cr "$bundle_path" >/dev/null 2>&1 || true
  # Some environments keep re-introducing these attributes on bundles in synced folders.
  for attr in com.apple.FinderInfo "com.apple.fileprovider.fpfs#P" com.apple.macl com.apple.provenance; do
    find "$bundle_path" -exec xattr -d "$attr" {} + >/dev/null 2>&1 || true
  done
}

sign_with_retry() {
  local target="$1"
  shift
  local attempts=0
  until codesign "$@" "$target"; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 3 ]]; then
      echo "FAIL: codesign failed for $target after $attempts attempts" >&2
      return 1
    fi
    sanitize_bundle "$target"
    sleep 0.2
  done
}

# Build metadata importer
clang \
  -isysroot "$SDK_PATH" \
  -F"$SDK_PATH/System/Library/Frameworks/CoreServices.framework/Frameworks" \
  -mmacosx-version-min=12.0 \
  -Wall -Wextra -Werror \
  -O2 \
  -bundle \
  "$ROOT_DIR/src/MetadataImporter.c" \
  -framework CoreFoundation \
  -framework CoreServices \
  -o "$MD_MACOS_DIR/ParquetImporter"

cp "$ROOT_DIR/plist/Info.plist" "$MD_BUNDLE_DIR/Contents/Info.plist"
cp "$ROOT_DIR/resources/schema.xml" "$MD_RESOURCES_DIR/schema.xml"

# Build host app with GUI manager (install/repair/uninstall/settings)
swiftc \
  -parse-as-library \
  -module-name ParquetQuickLookAndIndex \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -O \
  "$ROOT_DIR"/Sources/ParquetCore/*.swift \
  "$ROOT_DIR/preview/app/AppMain.swift" \
  -framework AppKit \
  -framework Foundation \
  -framework SwiftUI \
  -o "$APP_MACOS_DIR/ParquetQuickLookAndIndex"

cp "$ROOT_DIR/preview/app/Info.plist" "$APP_CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/preview/app/AppIcon.icns" "$APP_RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/NEWS.md" "$APP_RESOURCES_DIR/NEWS.md"
cp -R "$MD_BUNDLE_DIR" "$APP_RESOURCES_DIR/Parquet.mdimporter"

# Build extension entry point object (NSExtensionMain)
clang \
  -isysroot "$SDK_PATH" \
  -mmacosx-version-min=12.0 \
  -Wall -Wextra -Werror \
  -O2 \
  -c "$ROOT_DIR/preview/extension/NSExtensionMain.m" \
  -o "$BUILD_DIR/NSExtensionMain.o"

# Build modern Quick Look preview extension executable
swiftc \
  -parse-as-library \
  -module-name ParquetQuickLookExtension \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -O \
  "$ROOT_DIR/preview/extension/PreviewProvider.swift" \
  "$BUILD_DIR/NSExtensionMain.o" \
  -framework AppKit \
  -framework Foundation \
  -framework QuickLookUI \
  -framework UniformTypeIdentifiers \
  -o "$APPEX_MACOS_DIR/ParquetQuickLookExtension"

cp "$ROOT_DIR/preview/extension/Info.plist" "$APPEX_CONTENTS_DIR/Info.plist"

# Sign bundles
sanitize_bundle "$MD_BUNDLE_DIR"
sign_with_retry "$MD_BUNDLE_DIR" -s - -f --deep --timestamp=none
sanitize_bundle "$APP_BUNDLE_DIR"
sign_with_retry "$APPEX_DIR" -s - -f \
  --timestamp=none \
  --entitlements "$ROOT_DIR/preview/extension/Entitlements.plist"
# Signing the nested appex may reintroduce metadata; scrub again before outer app sign.
sanitize_bundle "$APP_BUNDLE_DIR"
sign_with_retry "$APP_BUNDLE_DIR" -s - -f \
  --timestamp=none \
  --entitlements "$ROOT_DIR/preview/app/Entitlements.plist"

echo "Built: $MD_BUNDLE_DIR"
echo "Built: $APP_BUNDLE_DIR (contains modern Quick Look extension)"
