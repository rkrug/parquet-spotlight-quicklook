# News

## Unreleased

### Changes

- Quick Look has a `Data` tab with the first rows of the file (100 by default, up to 10,000, set in the app's Quick Look Settings). For dataset folders it shows the first rows across the files, with partition keys (e.g. `year`) as columns.
- A folder that contains several datasets in subfolders no longer shows a (merged, incomplete) dataset preview; open the dataset folders themselves. Nested values (lists, structs, maps) appear as `[a, b]` or `{x: 1}`; click one to open it as a tree. Columns with very large pages are read from the start of each page. If a column cannot be shown (e.g. ZSTD compression, not supported yet), a note says so; the file itself is fine.

## 0.7.2-beta.1 - 2026-10-30 (pre-release)

### Changes

- `Updates` → `Reinstall Latest Release…` installs the latest release of your channel (last beta or last stable), e.g. to get back to an official build or repair an install.
- The Quick Look preview says where its settings are: in Parquet Quick Look and Index (⌘,).

## 0.7.1 - 2026-10-24

First stable release since 0.6.0; includes 0.7.0-beta.1 and 0.7.1-beta.1.

### Changes

- Beta channel: `Updates` → `Release channel` → `Beta` also offers pre-releases; `Stable` (default) offers only regular releases.
- `Updates` → `Downgrade to Stable…` (shown on beta builds) goes back to the newest stable release: signed download, channel set to Stable, Spotlight importer replaced.
- `.parquet` files are now a registered file type ("Apache Parquet File"), and folders named `*.parquet_ds` are recognised as "Parquet Database".
- Spotlight finds files by the date range of their data, from the footer statistics: e.g. files with data from 2024: `mdfind 'com_rkrug_parquet_date_max >= $time.iso(2024-01-01) && com_rkrug_parquet_date_min < $time.iso(2025-01-01)'`.
- Spotlight indexes the writer (`kMDItemCreator`, e.g. DuckDB, Spark, Arrow) and the names of the footer's key/value metadata.
- Quick Look shows footer details: writer, row groups, compression per column, date range and key/value metadata.
- Spotlight indexes column types, e.g. `mdfind 'com_rkrug_parquet_column_types == "*:timestamp*"'`.

## 0.7.1-beta.1 - 2026-10-24 (pre-release)

### Changes

- `Updates` → `Downgrade to Stable…` (shown on beta builds) goes back to the newest stable release: signed download, channel set to Stable, Spotlight importer replaced.

## 0.7.0-beta.1 - 2026-10-24 (pre-release)

### Changes

- Beta channel: `Updates` → `Release channel` → `Beta` also offers pre-releases. This is the first one.
- `.parquet` files are now a registered file type ("Apache Parquet File"), and folders named `*.parquet_ds` are recognised as "Parquet Database".
- Spotlight finds files by the date range of their data, from the footer statistics: e.g. files with data from 2024: `mdfind 'com_rkrug_parquet_date_max >= $time.iso(2024-01-01) && com_rkrug_parquet_date_min < $time.iso(2025-01-01)'`.
- Spotlight indexes the writer (`kMDItemCreator`, e.g. DuckDB, Spark, Arrow) and the names of the footer's key/value metadata.
- Quick Look shows footer details: writer, row groups, compression per column, date range and key/value metadata.
- Spotlight indexes column types, e.g. `mdfind 'com_rkrug_parquet_column_types == "*:timestamp*"'`.

## 0.6.0 - 2026-10-24

### Enhancements

- Updates can be installed from within the app (`Install Update`), with a signature check before anything is replaced.

## 0.5.1 - 2026-10-24

### Changes

- Updating is now just replacing the app: on launch it replaces an older Spotlight importer automatically. (Installing 0.5.0 or an older version still needs `Re-Install` once.)

## 0.5.0 - 2026-10-24

### Bug Fixes

- Spotlight now indexes correct row counts and the full list of column names. Quick Look and Spotlight share one footer parser, checked against Apache Arrow in the test suite.
- The app and Quick Look extension now run on macOS 13 and later on both Apple silicon and Intel Macs. 0.4.3 builds only ran on macOS 26 with Apple silicon.
- `install.sh` and `uninstall.sh` now handle apps installed from the DMG into `/Applications`, and uninstall no longer stops on the protected settings container.

### Changes

- Spotlight now indexes hive partitions (`key=value` folders), e.g. `mdfind 'com_rkrug_parquet_partitions == "year=2024"'`.
- Minimum macOS is now 13.0 (Ventura).
- The manager app shows its version in the sidebar.
- Updated Gatekeeper instructions for macOS 15 and later.

## 0.4.3 - 2026-10-24

### Enhancements

- Added `Export Schema (JSON)` button in Quick Look (file and dataset previews).
- Export now provides Arrow-friendly schema JSON with nested/flat views and reusable snippet stubs for R and Python.
- Export JSON is now wrapped in a saved, versioned scheme envelope (`parquet-quicklook-arrow-schema-v1`) to allow adding additional export schemes later without breaking compatibility.
- Quick Look previews now show the version in the heading, e.g. `Parquet Quick Look (v0.4.3)`.
- `Show JSON` now toggles the export pane (`Hide JSON` closes it again).

### Security

- Hardened Quick Look footer parsing so malformed metadata is rejected instead of exhausting the preview process.
- Quick Look no longer reads footers larger than 16 MiB; such files are still shown as valid Parquet files, without columns (same limit as the Spotlight importer).
- Dataset folder totals now saturate instead of wrapping.
- Uninstall hands the app bundle path to the shell as an argument rather than interpolating it into a command string.
- Spotlight column extraction skips oversize footers and caps the number of indexed columns. Files beyond those limits are still indexed as Parquet files.

### Testing

- Added sanity-bounds checks for importer limits, parse helpers, uninstall argument construction, and release-workflow pinning.

## 0.4.2 - 2026-03-12

### Bug Fixes

- Fixed Release Assets workflow shell compatibility by switching the packaging step to `bash`.
- Improved test-script portability by adding `grep` fallback when `rg` is unavailable.

## 0.4.1 - 2026-03-12

### Enhancements

- Hardened update checks with strict trusted URL + semver tag validation and clearer network/API error messages.
- Added `Copy Diagnostic Report` in-app action with anonymized troubleshooting output (status, versions, paths, plugin registrations, recent errors).
- Hardened build signing to handle intermittent xattr metadata contamination.

### Testing and CI

- Added script smoke tests (`scripts/test_scripts.sh`) and CI execution for build/release guard checks.
- Added `scripts/test_core.sh` to validate update-check, diagnostics-redaction, and dependency-injected status logic.

### Documentation

- Added rollback guidance in README for reverting to a previous release quickly.
- Added a GitHub bug-report template requiring a diagnostic report and offering optional diagnostic-file attachment guidance.

## 0.4.0 - 2026-03-12

### Enhancements

- Added Quick Look support for parquet dataset folders.
- Added Hive-style partition summary (`key=value`) and merged schema display for folder previews.
- Added dataset scan settings (`Scan all files`, `Max files`, `Recursive scan folders`).
- Non-parquet folders now fall back to normal macOS folder Quick Look.
- Manager UI now combines status and actions in one pane.
- Added dedicated `Updates` tab with interval-based update checks and manual update check action.
- Update dialog now supports `Skip this version` and includes app/version context.

### Bug Fixes

- Uninstall now performs full settings/data cleanup (best effort) and restarts Finder.

## 0.3.0 - 2026-03-11

### Enhancements

- Standardized naming to **Quick Look** and renamed the manager app to `Parquet Quick Look and Index`.
- Added native macOS menu entries: About, Settings, Quit, News, and Issue Tracker link.
- Updated settings behavior (`Apply Settings`, removed font size, improved max-columns control behavior).

### Bug Fixes

- Improved install/repair registration to prioritize installed app paths and remove stale legacy registrations.

## 0.2.2 - 2026-03-10

### Bug Fixes

- Fixed manager status detection for app installs in both `/Applications` and `~/Applications`.
- Fixed false-red Quick Look extension status when extension is installed and working outside the previously hardcoded path.

## 0.2.1 - 2026-03-10

### Enhancements

- Redesigned manager app UI to be more macOS-native (sidebar layout and grouped settings forms).
- Added custom app icon and icon generation scripts.
- Added automated release script (`scripts/release.sh`) for build + DMG/ZIP/SHA + GitHub release upload.

## 0.2.0 - 2026-03-10

### Enhancements

- Improved Quick Look Parquet schema parsing and rendering.
- Added collapsible schema tree and Arrow-style logical type labels.
- Added manager app settings and uninstall support.

See `CHANGELOG.md` for full detailed history.
