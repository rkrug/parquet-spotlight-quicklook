#!/usr/bin/env zsh
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh <tag> [--notes <file>] [--skip-gh]

Examples:
  ./scripts/release.sh v0.7.0
  ./scripts/release.sh v0.7.0 --notes /tmp/release-notes.md
  ./scripts/release.sh v0.7.0 --skip-gh
  ./scripts/release.sh v0.8.0-beta.1          # pre-release (beta channel), from dev or main

Behavior:
  1) Generates app icon and builds artifacts
  2) Packages Parquet Quick Look and Index.app into a DMG
  3) Creates/updates GitHub release and uploads DMG + SHA256 (unless --skip-gh)

Pre-release tags (vX.Y.Z-<pre-release>, e.g. v0.8.0-beta.1) are published as GitHub
pre-releases, which only apps on the Beta update channel are offered.

Preflight checks:
  - the tag must match the app version (ParquetReleaseVersion, else CFBundleShortVersionString)
  - current git branch must be main (dev is also allowed for pre-releases)
  - git working tree must be clean (no tracked or untracked changes)
  - local main must be fully synced with its upstream (no ahead/behind)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  exit 0
fi

TAG="$1"
shift
NOTES_FILE=""
SKIP_GH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes)
      NOTES_FILE="${2:-}"
      if [[ -z "$NOTES_FILE" ]]; then
        echo "error: --notes requires a file path" >&2
        exit 2
      fi
      shift 2
      ;;
    --skip-gh)
      SKIP_GH=1
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! "$TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
  echo "error: tag must look like v0.7.1 or v0.8.0-beta.1 (the v is optional)" >&2
  exit 2
fi
[[ "$TAG" == v* ]] || TAG="v$TAG"
PRERELEASE=0
[[ "$TAG" == *-* ]] && PRERELEASE=1

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${TAG#v}"
RELEASE_DIR="$ROOT_DIR/release"
STAGING_DIR="$RELEASE_DIR/Parquet-Spotlight-$VERSION"
DMG_PATH="$RELEASE_DIR/Parquet-Spotlight-$VERSION.dmg"
SHA_PATH="$DMG_PATH.sha256"
ZIP_PATH="$RELEASE_DIR/Parquet-Spotlight-$VERSION.zip"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required command: $1" >&2
    exit 1
  }
}

require_cmd hdiutil
require_cmd shasum
require_cmd zip
require_cmd git

if [[ $SKIP_GH -eq 0 ]]; then
  require_cmd gh
fi

if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  echo "error: notes file does not exist: $NOTES_FILE" >&2
  exit 2
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not inside a git worktree" >&2
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" && ! ( $PRERELEASE -eq 1 && "$CURRENT_BRANCH" == "dev" ) ]]; then
  echo "error: release must be run from branch 'main' (or 'dev' for a pre-release; current: $CURRENT_BRANCH)" >&2
  echo "hint: git checkout main" >&2
  exit 1
fi

APP_PLIST="$ROOT_DIR/preview/app/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ParquetReleaseVersion' "$APP_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
if [[ "$VERSION" != "$APP_VERSION" ]]; then
  echo "error: tag $TAG does not match the app version $APP_VERSION (preview/app/Info.plist)" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo "error: git working tree is not clean; commit/stash/remove changes first" >&2
  exit 1
fi

UPSTREAM_REF="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [[ -z "$UPSTREAM_REF" ]]; then
  echo "error: $CURRENT_BRANCH has no upstream tracking branch configured" >&2
  echo "hint: git branch --set-upstream-to origin/$CURRENT_BRANCH $CURRENT_BRANCH" >&2
  exit 1
fi

UPSTREAM_REMOTE="${UPSTREAM_REF%%/*}"
UPSTREAM_BRANCH="${UPSTREAM_REF#*/}"
if ! git fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"; then
  echo "error: failed to fetch upstream ($UPSTREAM_REF); cannot verify pushed/synced state" >&2
  exit 1
fi

read -r BEHIND_COUNT AHEAD_COUNT <<<"$(git rev-list --left-right --count "${UPSTREAM_REF}...HEAD")"
if [[ "$AHEAD_COUNT" -ne 0 ]]; then
  echo "error: local $CURRENT_BRANCH is ahead of $UPSTREAM_REF by $AHEAD_COUNT commit(s); push first" >&2
  exit 1
fi
if [[ "$BEHIND_COUNT" -ne 0 ]]; then
  echo "error: local $CURRENT_BRANCH is behind $UPSTREAM_REF by $BEHIND_COUNT commit(s); pull/rebase first" >&2
  exit 1
fi

echo "==> Generating icon"
"$ROOT_DIR/scripts/generate_icon.sh"

echo "==> Building bundles"
"$ROOT_DIR/scripts/build.sh"

echo "==> Preparing release staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R "$ROOT_DIR/build/Parquet Quick Look and Index.app" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating ZIP"
rm -f "$ZIP_PATH"
(
  cd "$RELEASE_DIR"
  zip -r -y "$(basename "$ZIP_PATH")" "$(basename "$STAGING_DIR")" >/dev/null
)

echo "==> Creating DMG"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "Parquet Spotlight $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "==> Writing checksum"
shasum -a 256 "$DMG_PATH" > "$SHA_PATH"

if [[ $SKIP_GH -eq 1 ]]; then
  echo "==> Skipping GitHub release upload (--skip-gh)"
  echo "DMG: $DMG_PATH"
  echo "ZIP: $ZIP_PATH"
  echo "SHA: $SHA_PATH"
  exit 0
fi

echo "==> Publishing release assets with gh"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG_PATH" "$ZIP_PATH" "$SHA_PATH" --clobber
else
  CREATE_ARGS=(--title "$TAG" --target "$CURRENT_BRANCH")
  if [[ $PRERELEASE -eq 1 ]]; then
    CREATE_ARGS+=(--prerelease)
  fi
  if [[ -n "$NOTES_FILE" ]]; then
    CREATE_ARGS+=(--notes-file "$NOTES_FILE")
  else
    CREATE_ARGS+=(--generate-notes)
  fi
  gh release create "$TAG" "$DMG_PATH" "$ZIP_PATH" "$SHA_PATH" "${CREATE_ARGS[@]}"
fi

echo "==> Done"
echo "Release tag: $TAG"
echo "DMG: $DMG_PATH"
echo "ZIP: $ZIP_PATH"
echo "SHA: $SHA_PATH"
