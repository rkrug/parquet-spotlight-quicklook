# Changelog

All notable changes to this project will be documented in this file.

## 0.2.0 - 2026-03-10

- Reworked modern Quick Look preview parsing to use a structured Parquet footer parser instead of simple byte-pattern heuristics.
- Improved row and column extraction reliability for nested schemas.
- Added Arrow-style logical type display in preview (for example `string`, `bool`, `date32[day]`, `timestamp[...]`) rather than mostly physical storage labels.
- Changed preview schema rendering to hierarchical tree display with indentation and group rows.
- Added collapsible schema nodes (`▸` / `▾`) so nested fields are hidden by default and can be expanded on demand.
- Removed preview table truncation so all parsed columns are shown.
- Hardened installer behavior and validation checks for preview app/extension bundle integrity.
- Added `scripts/uninstall.sh` for clean user-level removal of importer and preview extension (with `--dry-run`).

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
