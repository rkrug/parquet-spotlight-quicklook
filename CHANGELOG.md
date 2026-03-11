# Changelog

All notable changes to this project will be documented in this file.

## 0.3.0 - 2026-03-11

- Standardized product naming to Apple's official term **Quick Look** (replacing prior "QuickView/Quick View" wording).
- Renamed the manager app to `Parquet Quick Look and Index.app` and aligned bundle/executable naming.
- Renamed the embedded extension artifact to `ParquetQuickLook.appex`.
- Improved app menu integration for a more native macOS experience:
  - `About ...`, `Settings...`, and `Quit ...` in the app menu
  - `Help -> News`
  - `Help -> Report Issue or Send Feedback...`
- Added in-app `News` action that opens bundled `NEWS.md`.
- Updated settings UX:
  - `Save Settings` -> `Apply Settings`
  - removed font-size setting
  - disabled/greyed max-columns control when "Show all columns" is enabled
- Hardened install/repair registration behavior:
  - prefers installed app locations over build paths
  - unregisters stale build and legacy extension paths before re-registering
  - cleans up legacy app names (`ParquetPreviewHost.app`, `Parquet QuickView and Index.app`) and legacy appex names.
- Bumped importer, app, and extension versions to `0.3.0`.

## 0.2.2 - 2026-03-10

- Fixed manager status detection for app installs in both `/Applications` and `~/Applications`.
- Fixed false-red Quick Look extension status when extension was installed and working but outside the previously hardcoded path.

## 0.2.1 - 2026-03-10

- Redesigned the manager app settings window to a more native macOS-style interface with sidebar navigation (`Status`, `Actions`, `Preview Settings`) and grouped forms.
- Added a custom app icon and icon generation scripts:
  - `scripts/render_icon.swift`
  - `scripts/generate_icon.sh`
  - embedded icon bundle resource `preview/app/AppIcon.icns`
- Added automated release packaging/publishing script `scripts/release.sh`:
  - builds artifacts
  - packages DMG + ZIP + SHA256
  - creates/updates GitHub release assets
  - enforces release preflight checks (branch `main`, clean worktree, synced with upstream)
- Added `release/` to `.gitignore` so generated release artifacts are not tracked.
- Updated README with:
  - release automation usage
  - GitHub Releases DMG download guidance
  - unsigned app/Gatekeeper considerations for first launch.
- Bumped app and preview extension versions to `0.2.1`.

## 0.2.0 - 2026-03-10

- Reworked modern Quick Look preview parsing to use a structured Parquet footer parser instead of simple byte-pattern heuristics.
- Improved row and column extraction reliability for nested schemas.
- Added Arrow-style logical type display in preview (for example `string`, `bool`, `date32[day]`, `timestamp[...]`) rather than mostly physical storage labels.
- Changed preview schema rendering to hierarchical tree display with indentation and group rows.
- Added collapsible schema nodes (`▸` / `▾`) so nested fields are hidden by default and can be expanded on demand.
- Removed preview table truncation so all parsed columns are shown.
- Hardened installer behavior and validation checks for preview app/extension bundle integrity.
- Added `scripts/uninstall.sh` for clean user-level removal of importer and preview extension (with `--dry-run`).
- Replaced minimal host app with a GUI manager app exposing `Install`, `Repair`, `Uninstall`, and preview settings.
- Added preview settings integration (expand depth, show all vs limited rows, type display mode, path token filtering, font size).

## 0.1.0 - 2026-03-10

- Added a Spotlight `.mdimporter` for `.parquet` files.
- Implemented metadata-only footer parsing (`PAR1` trailer validation and footer length).
- Added custom metadata fields:
  - `com_rkrug_parquet_is_valid`
  - `com_rkrug_parquet_file_size`
  - `com_rkrug_parquet_footer_length`
  - `com_rkrug_parquet_row_count`
  - `com_rkrug_parquet_column_count`
  - `com_rkrug_parquet_columns` (multivalue, best-effort extraction)
- Added keyword tokens for search:
  - `parquet-valid` / `parquet-invalid`
  - `parquet-footer-<N>`
  - `parquet-size-<N>`
  - `parquet-rows-<N>`
  - `parquet-cols-<N>`
  - `col-<column_name>`
- Added build/install scripts and schema packaging.
- Added modern Quick Look preview extension (embedded as `ParquetPreview.appex` in `ParquetPreviewHost.app`) showing:
  - file size
  - row count
  - column count
  - column names and types (best-effort metadata extraction)
- Added `scripts/test_install.sh` for end-to-end installation verification.
- Added CI workflow for macOS build validation.
- Added repository baseline files:
  - `.gitignore`
  - `CONTRIBUTING.md`
  - `SECURITY.md`
  - `LICENSE` (MIT)
  - `CONTRIBUTORS.md`
- Added documentation, license, and contributor metadata.
