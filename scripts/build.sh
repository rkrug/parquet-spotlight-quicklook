#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"

# Spotlight importer bundle
MD_BUNDLE_DIR="$BUILD_DIR/Parquet.mdimporter"
MD_MACOS_DIR="$MD_BUNDLE_DIR/Contents/MacOS"
MD_RESOURCES_DIR="$MD_BUNDLE_DIR/Contents/Resources"

# Modern Quick Look preview extension hosted in app bundle
APP_BUNDLE_DIR="$BUILD_DIR/ParquetPreviewHost.app"
APP_CONTENTS_DIR="$APP_BUNDLE_DIR/Contents"
APP_MACOS_DIR="$APP_CONTENTS_DIR/MacOS"
APP_PLUGINS_DIR="$APP_CONTENTS_DIR/PlugIns"

APPEX_DIR="$APP_PLUGINS_DIR/ParquetPreview.appex"
APPEX_CONTENTS_DIR="$APPEX_DIR/Contents"
APPEX_MACOS_DIR="$APPEX_CONTENTS_DIR/MacOS"

rm -rf "$MD_BUNDLE_DIR" "$APP_BUNDLE_DIR"
mkdir -p "$MD_MACOS_DIR" "$MD_RESOURCES_DIR" "$APP_MACOS_DIR" "$APPEX_MACOS_DIR"

SDK_PATH="$(xcrun --show-sdk-path)"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"
mkdir -p "$SWIFT_MODULE_CACHE"

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

# Build minimal host app for modern preview extension discovery
clang \
  -isysroot "$SDK_PATH" \
  -mmacosx-version-min=12.0 \
  -Wall -Wextra -Werror \
  -O2 \
  "$ROOT_DIR/preview/app/main.m" \
  -framework Cocoa \
  -o "$APP_MACOS_DIR/ParquetPreviewHost"

cp "$ROOT_DIR/preview/app/Info.plist" "$APP_CONTENTS_DIR/Info.plist"

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
  -module-name ParquetPreviewExtension \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -O \
  "$ROOT_DIR/preview/extension/PreviewProvider.swift" \
  "$BUILD_DIR/NSExtensionMain.o" \
  -framework AppKit \
  -framework Foundation \
  -framework QuickLookUI \
  -framework UniformTypeIdentifiers \
  -o "$APPEX_MACOS_DIR/ParquetPreviewExtension"

cp "$ROOT_DIR/preview/extension/Info.plist" "$APPEX_CONTENTS_DIR/Info.plist"

# Sign bundles
xattr -cr "$MD_BUNDLE_DIR"
codesign -s - -f --deep --timestamp=none "$MD_BUNDLE_DIR"
xattr -cr "$APP_BUNDLE_DIR"
codesign -s - -f \
  --timestamp=none \
  --entitlements "$ROOT_DIR/preview/extension/Entitlements.plist" \
  "$APPEX_DIR"
codesign -s - -f \
  --timestamp=none \
  --entitlements "$ROOT_DIR/preview/app/Entitlements.plist" \
  "$APP_BUNDLE_DIR"

echo "Built: $MD_BUNDLE_DIR"
echo "Built: $APP_BUNDLE_DIR (contains modern preview extension)"
