# News

## 0.4.0 - 2026-03-12

- Added Quick Look support for parquet dataset folders.
- Added Hive-style partition summary (`key=value`) and merged schema display for folder previews.
- Added dataset scan settings (`Scan all files`, `Max files`, `Recursive scan folders`).
- Non-parquet folders now fall back to normal macOS folder Quick Look.
- Manager UI now combines status and actions in one pane.
- Added dedicated `Updates` tab with interval-based update checks and manual update check action.
- Update dialog now supports `Skip this version` and includes app/version context.
- Hardened update checks with strict trusted URL + semver tag validation and clearer network/API error messages.
- Added `Copy Diagnostic Report` in-app action with anonymized troubleshooting output (status, versions, paths, plugin registrations, recent errors).
- Added script smoke tests (`scripts/test_scripts.sh`) and CI execution for build/release guard checks.
- Added `scripts/test_core.sh` to validate update-check, diagnostics-redaction, and dependency-injected status logic.
- Uninstall now performs full settings/data cleanup (best effort) and restarts Finder.
- Added rollback guidance in README for reverting to a previous release quickly.

## 0.3.0 - 2026-03-11

- Standardized naming to **Quick Look** and renamed the manager app to `Parquet Quick Look and Index`.
- Added native macOS menu entries: About, Settings, Quit, News, and Issue Tracker link.
- Updated settings behavior (`Apply Settings`, removed font size, improved max-columns control behavior).
- Improved install/repair registration to prioritize installed app paths and remove stale legacy registrations.

## 0.2.2 - 2026-03-10

- Fixed manager status detection for app installs in both `/Applications` and `~/Applications`.
- Fixed false-red Quick Look extension status when extension is installed and working outside the previously hardcoded path.

## 0.2.1 - 2026-03-10

- Redesigned manager app UI to be more macOS-native (sidebar layout and grouped settings forms).
- Added custom app icon and icon generation scripts.
- Added automated release script (`scripts/release.sh`) for build + DMG/ZIP/SHA + GitHub release upload.

## 0.2.0 - 2026-03-10

- Improved Quick Look Parquet schema parsing and rendering.
- Added collapsible schema tree and Arrow-style logical type labels.
- Added manager app settings and uninstall support.

See `CHANGELOG.md` for full detailed history.
