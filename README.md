# parquet_indexer (Spotlight Importer for `.parquet`)

> [!WARNING]
> **This repository was written completely using Codex.**
> **Model:** GPT-5 (Codex coding agent)
> **Version:** Codex GPT-5 session build (2026-03-12)
> It works for me, but I take no guarantee if it works for you.

This project provides:

- a macOS Spotlight importer (`.mdimporter`) for Parquet metadata indexing
- a modern Quick Look preview extension (`.appex`, embedded in a host app) for Parquet metadata preview with:
  - hierarchical schema tree (collapsible groups)
  - full parsed column list (no preview truncation)
  - Arrow-style logical scalar type labels where available
  - `Export Schema (JSON)` button for Arrow-friendly schema reuse in R/Python
  - versioned export-scheme envelope (`parquet-quicklook-arrow-schema-v1`) for forward-compatible additional schema formats
- a small GUI manager app (`Parquet Quick Look and Index.app`) with:
  - `Re-Install`, `Repair Registration`, and `Uninstall` actions
  - `Copy Diagnostic Report` action for support/issue reports (anonymized)
  - Quick Look rendering settings (schema display + dataset scan controls)
  - dedicated `Updates` tab for release checks (`Daily`/`Weekly`/`Monthly`)
  - automatic importer install on app launch if missing

Since `0.3.0`, naming is standardized to Apple's official **Quick Look** terminology.

The importer reads only Parquet footer metadata (`...<metadata_len><PAR1>`), does not parse row contents, and writes Spotlight metadata for search.

## Prerequisites

- **Minimum supported macOS version: 13.0 (Ventura).** Builds are universal (Apple silicon and Intel).

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
- `build/Parquet Quick Look and Index.app` (contains `ParquetQuickLook.appex`)

The build script also:

- copies `Info.plist` and `resources/schema.xml`
- clears extended attributes
- signs the bundle ad-hoc (required for reliable loading)

## Release Packaging

Automate build + DMG + GitHub release upload:

```bash
./scripts/release.sh v0.7.0
```

What it does:

- runs `./scripts/generate_icon.sh` and `./scripts/build.sh`
- creates `release/Parquet-Spotlight-0.6.0.dmg`
- creates `release/Parquet-Spotlight-0.6.0.zip`
- creates `release/Parquet-Spotlight-0.6.0.dmg.sha256`
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
- On first launch, Gatekeeper blocks the app with a security warning.
- To allow it, try to open the app once, then go to:
  - `System Settings -> Privacy & Security -> Open Anyway`
- On macOS 13/14, right-click the app and choosing `Open` also works; macOS 15 and later removed that shortcut.
- Alternatively, remove the download quarantine flag after copying the app:

```bash
xattr -dr com.apple.quarantine "/Applications/Parquet Quick Look and Index.app"
```

## Update

### In-app (0.6.0 onwards)

When `Check for Updates` (menu or `Updates` tab) finds a newer release, click `Install Update`. The app downloads the release ZIP, verifies its Ed25519 signature against the key built into the app, checks the unpacked app (bundle ID, version, code signature), then quits, swaps itself in place, and relaunches; the new app updates the Spotlight importer on launch. If the release has no signature, the app's folder is not writable, or any check fails, nothing is installed and the release page is offered instead.

### Beta channel (0.7.0-beta.1 onwards)

`Updates` → `Release channel`: `Stable` (default) offers only regular releases; `Beta` also offers pre-releases (tags like `v0.8.0-beta.1`, published as GitHub pre-releases, signed and installed the same way). Switching back to `Stable` never downgrades: a beta stays installed until a newer stable release is out (e.g. `0.8.0` after `0.8.0-beta.2`). Apps older than 0.7.0-beta.1 only see stable releases.

Signing for maintainers: `swift scripts/sign_update.swift keygen` creates a key pair once. The private key goes into the GitHub secret `PARQUET_UPDATE_SIGNING_KEY` (the release workflow then uploads `Parquet-Spotlight-<version>.zip.sig`), the public key into `ParquetUpdatePublicKey` in `preview/app/Info.plist`.

### Manually

1. Quit `Parquet Quick Look and Index` if it is running.
2. Replace `Parquet Quick Look and Index.app` in `/Applications` with the one from the new DMG.
3. Open the app once. On launch it replaces the Spotlight importer in `~/Library/Spotlight` when the bundled one is newer, re-registers it, and Spotlight re-indexes your Parquet files. The sidebar shows the new version.

Versions before 0.5.1 do not have this check: when installing 0.5.0 or older, click `Re-Install` once. `Repair Registration` re-registers but keeps the installed importer.

## Rollback (Revert To A Previous Version)

If a new release causes problems:

1. Uninstall current version (recommended):
```bash
./scripts/uninstall.sh
```
2. Download an older DMG from:
   - [GitHub Releases](https://github.com/rkrug/parquet-spotlight-quicklook/releases)
3. Install that older app and run `Re-Install` once (the app never downgrades the importer on its own, and `Repair Registration` keeps the installed importer).

Optional verification after rollback:

```bash
mdimport -t -d2 /path/to/file.parquet
qlmanage -p /path/to/file.parquet
```

## Install

Install for current user:

```bash
./scripts/install.sh
```

This installs and registers:

- `~/Library/Spotlight/Parquet.mdimporter`
- `~/Applications/Parquet Quick Look and Index.app` (embedded modern Quick Look extension), or the existing copy in `/Applications` if the app was installed from the DMG

Use `Parquet Quick Look and Index.app` from `~/Applications` to:

- auto-install importer payload if missing (on launch)
- re-install importer payload from inside the app bundle
- repair registration and refresh caches
- uninstall importer + Quick Look app (including settings cleanup)
- change preview settings used by Quick Look
- check for updates (menu item + Updates tab), with `Skip this version` option

## Uninstall

Remove importer and preview for current user:

```bash
./scripts/uninstall.sh
```

This performs full user-level cleanup:

- app/importer/plugin removal
- Quick Look cache refresh + Finder restart
- settings/preferences/cache cleanup (best effort for container root metadata)

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

6. Test dataset folder preview:

```bash
qlmanage -p /path/to/parquet-dataset-folder
```

Behavior:

- folders containing parquet files render a dataset summary preview
- non-parquet folders fall back to standard macOS folder Quick Look

Dataset scan behavior is controlled in app settings:

- `Scan all files`
- `Max files (if not all)`
- `Recursive scan folders`

7. Run script + core logic test suite:

```bash
./scripts/test_scripts.sh
```

This also runs:

```bash
./scripts/test_core.sh
./scripts/test_importer_summary.sh
```

`test_core.sh` validates trusted update URL/tag checks, version comparisons, error mapping, diagnostics redaction rules, uninstall argument construction, parser sanity bounds, and the footer parser against the fixtures in `Tests/fixtures`.

`test_importer_summary.sh` calls the Spotlight importer's entry point on the same fixtures. Both tests compare with `Tests/fixtures/expected.txt`, whose row and column counts come from Apache Arrow; regenerate fixtures with `Rscript Tests/fixtures/make_fixtures.R` (needs the R `arrow` package).

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
mdfind 'com_rkrug_parquet_partitions == "year=2024"'
mdfind 'com_rkrug_parquet_column_types == "*:timestamp*"'
mdfind 'kMDItemKeywords == "part-year-2024"'
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
- `kMDItemCreator` (the writer from the footer's `created_by`, e.g. `parquet-cpp-arrow version 24.0.0`)

Custom Parquet fields:

- `com_rkrug_parquet_is_valid` (`CFBoolean`)
- `com_rkrug_parquet_file_size` (`CFNumber`)
- `com_rkrug_parquet_footer_length` (`CFNumber`)
- `com_rkrug_parquet_row_count` (`CFNumber`)
- `com_rkrug_parquet_column_count` (`CFNumber`)
- `com_rkrug_parquet_columns` (`CFString`, multivalued)
- `com_rkrug_parquet_column_types` (`CFString`, multivalued)
- `com_rkrug_parquet_partitions` (`CFString`, multivalued)
- `com_rkrug_parquet_metadata_keys` (`CFString`, multivalued)
- `com_rkrug_parquet_date_min` / `com_rkrug_parquet_date_max` (`CFDate`)

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
  - Row count from the Parquet footer (file `num_rows`, or the sum over row groups).
  - Example: `mdfind 'com_rkrug_parquet_row_count > 1000000'`

- `com_rkrug_parquet_column_count` (`CFNumber`):
  - Number of extracted columns stored in `com_rkrug_parquet_columns`.
  - Example: `mdfind 'com_rkrug_parquet_column_count > 100'`

- `com_rkrug_parquet_columns` (`CFString`, multivalued):
  - Leaf column paths parsed from the footer schema (nested fields joined with `.`, e.g. `point.x`, `tags.list.element`).
  - Example: `mdfind 'com_rkrug_parquet_columns == "Species"'`

- `com_rkrug_parquet_column_types` (`CFString`, multivalued):
  - `name:type` per leaf column, with the Arrow-style logical type shown in Quick Look, e.g. `species:string`, `ts:timestamp[us]`, `amount:decimal(10,2)`.
  - Example: `mdfind 'com_rkrug_parquet_column_types == "*:timestamp*"'`

- `com_rkrug_parquet_partitions` (`CFString`, multivalued):
  - Hive-style partitions from the file's folder path (`key=value` folder names, outermost first, values percent-decoded), e.g. `year=2024` for `.../year=2024/region=EU/part-0.parquet`. Taken from the path only; row data is never read.
  - Example: `mdfind 'com_rkrug_parquet_partitions == "year=2024"'`

- `kMDItemCreator` (`CFString`):
  - The program that wrote the file (footer `created_by`), e.g. `parquet-cpp-arrow version 24.0.0`, DuckDB, Spark.
  - Example: `mdfind 'kMDItemCreator == "*duckdb*"c'`

- `com_rkrug_parquet_metadata_keys` (`CFString`, multivalued):
  - Keys of the footer key/value metadata (e.g. `ARROW:schema`, `pandas`, custom keys); values are not indexed.
  - Example: `mdfind 'com_rkrug_parquet_metadata_keys == "pandas"'`

- `com_rkrug_parquet_date_min` / `com_rkrug_parquet_date_max` (`CFDate`):
  - Earliest and latest value over all date and timestamp columns, from the footer's column statistics (no row data is read). Timestamps are read as UTC; columns without statistics are left out, and files without date/timestamp statistics have neither attribute.
  - Example (files with data from 2024): `mdfind 'com_rkrug_parquet_date_max >= $time.iso(2024-01-01) && com_rkrug_parquet_date_min < $time.iso(2025-01-01)'`

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
- `part-<key>-<value>` (hive partitions, e.g. `part-year-2024`)
- `meta-<key>` (footer key/value metadata keys, e.g. `meta-pandas`)

## Notes

- UTI: `com.rkrug.parquet` (`.parquet` files, "Apache Parquet File") and `com.rkrug.parquet-database` (folders named `*.parquet_ds`, "Parquet Database"; a normal folder, not a package). Both are declared by the app and registered once it has been launched; Quick Look shows the dataset summary for `.parquet_ds` folders.
- Bundle ID: `com.rkrug.parquetindexer.importer`
- Plugin factory UUID: `0E198062-E6D8-4AC2-BBCE-FB860A43A116`
- Preview extension bundle ID: `com.rkrug.parquetindexer.previewhost.preview`
- Quick Look host app bundle ID: `com.rkrug.parquetindexer.previewhost`
- The importer extracts column names only from footers up to 16 MiB and indexes at most 4096 columns per file; larger footers are still indexed as Parquet files, without column names.
- Quick Look shows footer details below the schema: writer, row groups, compressed/uncompressed size, date range, codec and size per column, and the key/value metadata (at most 200 row groups and 256 metadata entries listed; values cut to 4 KiB).
- Quick Look preview parsing bounds nesting depth, declared container sizes, and skip work, and saturates dataset size/row totals. Well-formed files render as before; malformed footers are rejected.

## License

This project is licensed under the MIT License. See [LICENSE](/Users/rkrug/Documents/GitHub/parquet_indexer/LICENSE).
