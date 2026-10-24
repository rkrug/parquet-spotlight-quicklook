# News

## 0.4.3 - 2026-03-20

### Enhancements

- Added `Export Schema (JSON)` button in Quick Look (file and dataset previews).
- Export now provides Arrow-friendly schema JSON with nested/flat views and reusable snippet stubs for R and Python.
- Export JSON is now wrapped in a saved, versioned scheme envelope (`parquet-quicklook-arrow-schema-v1`) to allow adding additional export schemes later without breaking compatibility.

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
