# parquet_indexer (Spotlight Importer for `.parquet`)

> [!WARNING]
> **This repository was written completely using Codex.**
> **Model:** GPT-5 (Codex coding agent)
> **Version:** Codex GPT-5 session build (2026-03-10)
> It works for me, but I take no guarantee if it works for you.

This project provides:

- a macOS Spotlight importer (`.mdimporter`) for Parquet metadata indexing
- a modern Quick Look preview extension (`.appex`, embedded in a host app) for Parquet metadata preview with:
  - hierarchical schema tree (collapsible groups)
  - full parsed column list (no preview truncation)
  - Arrow-style logical scalar type labels where available
- a small GUI manager app (`ParquetPreviewHost.app`) with:
  - `Install`, `Repair`, and `Uninstall` actions
  - preview rendering settings (expand depth, row limits, type display, font size)

The importer reads only Parquet footer metadata (`...<metadata_len><PAR1>`), does not parse row contents, and writes Spotlight metadata for search.

## Prerequisites

- macOS with Spotlight enabled
- Xcode Command Line Tools (`xcrun`, `clang`, `codesign`)
- shell access (`zsh`)
- permission to write to `~/Library/Spotlight` and `~/Applications`

Optional checks:

```bash
xcrun --show-sdk-path
clang --version
codesign --version
```

## Build

From the project root:

```bash
./scripts/build.sh
```

This creates:

- `build/Parquet.mdimporter`
- `build/ParquetPreviewHost.app` (contains `ParquetPreview.appex`)

The build script also:

- copies `Info.plist` and `resources/schema.xml`
- clears extended attributes
- signs the bundle ad-hoc (required for reliable loading)

## Release Packaging

Automate build + DMG + GitHub release upload:

```bash
./scripts/release.sh v0.2.1
```

What it does:

- runs `./scripts/generate_icon.sh` and `./scripts/build.sh`
- creates `release/Parquet-Spotlight-0.2.1.dmg`
- creates `release/Parquet-Spotlight-0.2.1.zip`
- creates `release/Parquet-Spotlight-0.2.1.dmg.sha256`
- creates or updates the GitHub release tag and uploads those assets
- verifies release preflight before packaging:
  - current branch is `main`
  - working tree is clean
  - local `main` is fully synced with upstream

Optional flags:

- `--notes <file>`: use a custom release notes file
- `--skip-gh`: package artifacts only, do not call GitHub CLI

## GitHub Release Install (DMG)

Download the latest DMG from:

- [GitHub Releases](https://github.com/rkrug/parquet-spotlight-quicklook/releases)

Typical asset name:

- `Parquet-Spotlight-<version>.dmg`

Unsigned app note (important):

- Releases are currently unsigned (ad-hoc signed for local loading, but not Apple Developer ID notarized).
- On first launch, macOS may block the app with a security warning.
- If blocked, right-click the app and choose `Open`, or go to:
  - `System Settings -> Privacy & Security -> Open Anyway`

## Install

Install for current user:

```bash
./scripts/install.sh
```

This installs and registers:

- `~/Library/Spotlight/Parquet.mdimporter`
- `~/Applications/ParquetPreviewHost.app` (embedded modern preview extension)

Use `ParquetPreviewHost.app` from `~/Applications` to:

- install importer payload from inside the app bundle
- repair registration and refresh caches
- uninstall importer + preview app
- change preview settings used by Quick Look

## Uninstall

Remove importer and preview for current user:

```bash
./scripts/uninstall.sh
```

Dry-run mode:

```bash
./scripts/uninstall.sh --dry-run
```

## Test

1. Test-import a file and confirm plugin selection:

```bash
mdimport -t -d2 /path/to/file.parquet
```

Expected output includes:

- `with plugIn /Users/<you>/Library/Spotlight/Parquet.mdimporter`

2. Inspect indexed metadata for one file:

```bash
mdls -name kMDItemKind \
     -name com_rkrug_parquet_is_valid \
     -name com_rkrug_parquet_file_size \
     -name com_rkrug_parquet_footer_length \
     -name com_rkrug_parquet_row_count \
     -name com_rkrug_parquet_column_count \
     /path/to/file.parquet
```

3. Reindex if needed:

```bash
mdimport -r ~/Library/Spotlight/Parquet.mdimporter
mdimport /path/to/file.parquet
```

3.1. Reload Quick Look preview plugins if needed:

```bash
qlmanage -r
qlmanage -r cache
```

4. Run installation self-test:

```bash
./scripts/test_install.sh
```

Optional explicit test file:

```bash
./scripts/test_install.sh /path/to/file.parquet
```

5. Test Quick Look preview plugin:

```bash
qlmanage -p /path/to/file.parquet
```

## Search

### Spotlight GUI

Use:

- `kind:Apache Parquet file`
- `name:.parquet`

### Terminal (`mdfind`)

```bash
mdfind 'kMDItemKind == "Apache Parquet file"'
mdfind 'com_rkrug_parquet_is_valid == 1'
mdfind 'com_rkrug_parquet_footer_length > 100000'
mdfind 'com_rkrug_parquet_file_size > 100000000'
mdfind 'com_rkrug_parquet_row_count > 1000000'
mdfind 'com_rkrug_parquet_column_count > 100'
mdfind 'com_rkrug_parquet_columns == "species"'
mdfind 'kMDItemKeywords == "col-species"'
```

## Troubleshooting

### `mdimport` says `with no plugIn`

Run:

```bash
mdimport -r ~/Library/Spotlight/Parquet.mdimporter
mdimport -t -d2 /path/to/file.parquet
```

If needed, reinstall:

```bash
./scripts/build.sh
./scripts/install.sh
```

### Custom fields are null in `mdls`

Force reindex the file:

```bash
mdimport /path/to/file.parquet
```

Then check again:

```bash
mdls -name com_rkrug_parquet_is_valid \
     -name com_rkrug_parquet_footer_length \
     -name com_rkrug_parquet_file_size \
     /path/to/file.parquet
```

### Spotlight results seem stale

Re-register plugin and reindex a folder:

```bash
mdimport -r ~/Library/Spotlight/Parquet.mdimporter
mdimport /path/to/folder
```

### Preview plugin not listed in `qlmanage -m plugins`

`qlmanage -m plugins` primarily lists legacy generators and may not reflect modern preview extensions.

Use this instead:

```bash
pluginkit -m -p com.apple.quicklook.preview | rg parquet
```

Spotlight indexing via `.mdimporter` is independent and unaffected.

## Exposed Properties

Standard Spotlight fields:

- `kMDItemTitle`
- `kMDItemKind` (`Apache Parquet file`)
- `kMDItemDescription`
- `kMDItemKeywords`
- `kMDItemTextContent` (metadata tokens only; no row text)

Custom Parquet fields:

- `com_rkrug_parquet_is_valid` (`CFBoolean`)
- `com_rkrug_parquet_file_size` (`CFNumber`)
- `com_rkrug_parquet_footer_length` (`CFNumber`)
- `com_rkrug_parquet_row_count` (`CFNumber`)
- `com_rkrug_parquet_column_count` (`CFNumber`)
- `com_rkrug_parquet_columns` (`CFString`, multivalued)

## Queryable `mdfind` Properties

- `com_rkrug_parquet_is_valid` (`CFBoolean`):
  - `1` if the file has a readable Parquet trailer/footer (`PAR1` + footer length), else `0`.
  - Example: `mdfind 'com_rkrug_parquet_is_valid == 1'`

- `com_rkrug_parquet_file_size` (`CFNumber`):
  - Total parquet file size in bytes (from filesystem stat at import time).
  - Example: `mdfind 'com_rkrug_parquet_file_size > 100000000'`

- `com_rkrug_parquet_footer_length` (`CFNumber`):
  - Footer metadata length in bytes (value from Parquet trailer).
  - Example: `mdfind 'com_rkrug_parquet_footer_length > 50000'`

- `com_rkrug_parquet_row_count` (`CFNumber`):
  - Best-effort extracted row count from footer metadata.
  - Example: `mdfind 'com_rkrug_parquet_row_count > 1000000'`

- `com_rkrug_parquet_column_count` (`CFNumber`):
  - Number of extracted columns stored in `com_rkrug_parquet_columns`.
  - Example: `mdfind 'com_rkrug_parquet_column_count > 100'`

- `com_rkrug_parquet_columns` (`CFString`, multivalued):
  - Best-effort extracted column names from footer metadata.
  - Example: `mdfind 'com_rkrug_parquet_columns == "Species"'`

- `kMDItemKeywords` (`CFString`, multivalued):
  - Includes generated tokens such as `col-<column_name>`, `parquet-valid`, `parquet-footer-<N>`.
  - Example: `mdfind 'kMDItemKeywords == "col-species"'`

Keyword tokens written by importer:

- `parquet`
- `parquet-valid` / `parquet-invalid`
- `parquet-footer-<N>`
- `parquet-size-<N>`
- `parquet-rows-<N>`
- `parquet-cols-<N>`
- `col-<column_name>`

## Notes

- UTI: `com.rkrug.parquet`
- Bundle ID: `com.rkrug.parquetindexer.importer`
- Plugin factory UUID: `0E198062-E6D8-4AC2-BBCE-FB860A43A116`
- Preview extension bundle ID: `com.rkrug.parquetindexer.previewhost.preview`
- Preview host app bundle ID: `com.rkrug.parquetindexer.previewhost`

## License

This project is licensed under the MIT License. See [LICENSE](/Users/rkrug/Documents/GitHub/parquet_indexer/LICENSE).
