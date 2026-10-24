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

# Universal binaries with an explicit deployment target; without these, swiftc
# targets the build host's macOS version and architecture only.
MIN_MACOS="13.0"
ARCHS=(arm64 x86_64)
SLICE_DIR="$BUILD_DIR/slices"
rm -rf "$SLICE_DIR"
mkdir -p "$SLICE_DIR"

# swiftc builds one architecture at a time; build each slice and merge with lipo.
swift_universal() {
  local output="$1"
  shift
  local slices=()
  for arch in "${ARCHS[@]}"; do
    local slice="$SLICE_DIR/$(basename "$output")-$arch"
    swiftc -target "$arch-apple-macos$MIN_MACOS" "$@" -o "$slice"
    slices+=("$slice")
  done
  lipo -create "${slices[@]}" -output "$output"
}

# Build metadata importer: C CFPlugIn shell + shared Swift footer parser, linked as a
# loadable bundle against the OS Swift runtime (/usr/lib/swift).
SWIFT_LIB_DIRS=(-L "$SDK_PATH/usr/lib/swift" -L "$(dirname "$(xcrun --find swiftc)")/../lib/swift/macosx")
importer_slices=()
for arch in "${ARCHS[@]}"; do
  clang \
    -isysroot "$SDK_PATH" \
    -F"$SDK_PATH/System/Library/Frameworks/CoreServices.framework/Frameworks" \
    -arch "$arch" \
    -mmacosx-version-min="$MIN_MACOS" \
    -Wall -Wextra -Werror \
    -O2 \
    -c "$ROOT_DIR/src/MetadataImporter.c" \
    -o "$SLICE_DIR/MetadataImporter-$arch.o"
  swiftc \
    -target "$arch-apple-macos$MIN_MACOS" \
    -parse-as-library \
    -module-name ParquetImporter \
    -module-cache-path "$SWIFT_MODULE_CACHE" \
    -O -wmo \
    -emit-object \
    "$ROOT_DIR/Sources/ParquetCore/ParserBounds.swift" \
    "$ROOT_DIR/Sources/ParquetCore/ParquetFooterParser.swift" \
    "$ROOT_DIR/src/ImporterBridge.swift" \
    -o "$SLICE_DIR/ImporterSwift-$arch.o"
  clang \
    -isysroot "$SDK_PATH" \
    -arch "$arch" \
    -mmacosx-version-min="$MIN_MACOS" \
    -bundle \
    "$SLICE_DIR/MetadataImporter-$arch.o" \
    "$SLICE_DIR/ImporterSwift-$arch.o" \
    "${SWIFT_LIB_DIRS[@]}" \
    -Wl,-rpath,/usr/lib/swift \
    -framework CoreFoundation \
    -framework CoreServices \
    -o "$SLICE_DIR/ParquetImporter-$arch"
  importer_slices+=("$SLICE_DIR/ParquetImporter-$arch")
done
lipo -create "${importer_slices[@]}" -output "$MD_MACOS_DIR/ParquetImporter"

cp "$ROOT_DIR/plist/Info.plist" "$MD_BUNDLE_DIR/Contents/Info.plist"
cp "$ROOT_DIR/resources/schema.xml" "$MD_RESOURCES_DIR/schema.xml"

# Build host app with GUI manager (install/repair/uninstall/settings)
swift_universal "$APP_MACOS_DIR/ParquetQuickLookAndIndex" \
  -parse-as-library \
  -module-name ParquetQuickLookAndIndex \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -O \
  "$ROOT_DIR"/Sources/ParquetCore/*.swift \
  "$ROOT_DIR/preview/app/AppMain.swift" \
  -framework AppKit \
  -framework Foundation \
  -framework SwiftUI

cp "$ROOT_DIR/preview/app/Info.plist" "$APP_CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/preview/app/AppIcon.icns" "$APP_RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/NEWS.md" "$APP_RESOURCES_DIR/NEWS.md"
cp -R "$MD_BUNDLE_DIR" "$APP_RESOURCES_DIR/Parquet.mdimporter"

# Build extension entry point object (NSExtensionMain)
clang \
  -isysroot "$SDK_PATH" \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min="$MIN_MACOS" \
  -Wall -Wextra -Werror \
  -O2 \
  -c "$ROOT_DIR/preview/extension/NSExtensionMain.m" \
  -o "$BUILD_DIR/NSExtensionMain.o"

# Build modern Quick Look preview extension executable
swift_universal "$APPEX_MACOS_DIR/ParquetQuickLookExtension" \
  -parse-as-library \
  -module-name ParquetQuickLookExtension \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -O \
  "$ROOT_DIR/Sources/ParquetCore/ParserBounds.swift" \
  "$ROOT_DIR/Sources/ParquetCore/ParquetFooterParser.swift" \
  "$ROOT_DIR/Sources/ParquetCore/ParquetDataset.swift" \
  "$ROOT_DIR/preview/extension/PreviewProvider.swift" \
  "$BUILD_DIR/NSExtensionMain.o" \
  -framework AppKit \
  -framework Foundation \
  -framework QuickLookUI \
  -framework UniformTypeIdentifiers

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
