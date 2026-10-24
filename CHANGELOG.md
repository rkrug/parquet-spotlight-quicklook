# Changelog

All notable changes to this project will be documented in this file.

## 0.7.0 - 2026-10-24

- Bumped importer, app, and extension versions to `0.7.0`.
- The app declares the file types: `.parquet` as `com.rkrug.parquet` ("Apache Parquet File"; previously macOS only knew a dynamic type) and folders named `*.parquet_ds` as `com.rkrug.parquet-database` ("Parquet Database", a normal folder). Quick Look supports the database type. The importer now imports the `.parquet` declaration instead of exporting it.
- Spotlight indexes column types as `com_rkrug_parquet_column_types` (`name:type`, e.g. `ts:timestamp[us]`).
- Footer parser reads `created_by`, key/value metadata, and per row group the column chunks (codec, compressed/uncompressed size, statistics), keeping per-column totals, the first 200 row groups, 256 metadata entries and values up to 4 KiB (`ParquetParserBounds`). `parse(footer:)` now returns a `Summary`.
- Spotlight: `kMDItemCreator` from `created_by` (#15), `com_rkrug_parquet_metadata_keys` and `meta-<key>` keywords (#15), and `com_rkrug_parquet_date_min` / `_date_max` (`CFDate`) over all date/timestamp columns from `min_value`/`max_value` statistics, falling back to legacy `min`/`max` (valid for signed INT32/INT64); timestamps are read as UTC (#18).
- Importer bridge: `parquet_copy_attributes` returns the full attribute dictionary built in Swift; `MetadataImporter.c` only copies it (replaces `parquet_read_summary` / `parquet_read_partitions`).
- Quick Look: footer details section with writer, row-group count, data size and compression ratio, date range, storage per column (codec, sizes, date range), row-group table and key/value metadata (#19).
- New fixture `footer.parquet` (3 row groups, ZSTD/SNAPPY, `owner` metadata, date/ms/ns timestamp ranges) with core and importer tests.
- Core tests corrupt the fixture footers (bit flips, truncation, `0xff` runs, random length fields, random bytes; 3000 seeded cases, `PARQUET_FUZZ_SEED` / `PARQUET_FUZZ_CASES` to override) and check `ParquetFooter.parse` / `read` for no trap, no hang (< 1 s per case), and the column bound (#16).
- CI: a `compat` job runs the build and tests natively on `macos-15-intel` and `macos-15`, the oldest hosted macOS now that macOS 13/14 runners are retired (#17).

## 0.6.0 - 2026-10-24

- Bumped importer, app, and extension versions to `0.6.0`.
- In-app updates: `Install Update` in the update dialog downloads the release ZIP, verifies an Ed25519 signature (CryptoKit; public key `ParquetUpdatePublicKey` in the app's Info.plist), checks bundle ID, version and code signature, then swaps the app via a helper after quit and relaunches. Falls back to the release page when the release is unsigned, the app folder is not writable, or a check fails.
- Release workflow signs the ZIP with the `PARQUET_UPDATE_SIGNING_KEY` secret (`scripts/sign_update.swift`) and uploads `<zip>.sig`; without the secret it warns and publishes unsigned.

## 0.5.1 - 2026-10-24

- Bumped importer, app, and extension versions to `0.5.1`.
- The manager app now updates an older Spotlight importer in `~/Library/Spotlight` on launch (compares `CFBundleShortVersionString`, then `CFBundleVersion`; never downgrades), so updating is just replacing the app. Previously the importer was only installed when missing, and replacing the app left the old importer in place.
- README: update procedure; rollback needs `Re-Install`.

## 0.5.0 - 2026-10-24

- Bumped importer, app, and extension versions to `0.5.0`.
- Moved the folder/dataset summary (file and row totals, column union, hive partition values) from the Quick Look extension to `Sources/ParquetCore/ParquetDataset.swift`, with tests on a generated hive-partitioned dataset.
- Spotlight indexes hive partitions from the file's folder path as `com_rkrug_parquet_partitions` (`key=value`, percent-decoded, up to 32) and `part-<key>-<value>` keywords. Quick Look's folder preview uses the same partition parser (values are now percent-decoded there too).
- Manager window: content now shares the window toolbar, so the first section header is no longer blurred.

- One footer parser for Quick Look and Spotlight: the Thrift compact-protocol parser moved from `PreviewProvider.swift` to `Sources/ParquetCore/ParquetFooterParser.swift`. The importer is now a thin C CFPlugIn shell (`src/MetadataImporter.c`) calling it through `src/ImporterBridge.swift`.
  - Fixes Spotlight values: the old C importer searched for Thrift *binary*-protocol markers, so row counts were usually 0 and column names came from an ASCII heuristic (capped at 128, with stray tokens such as `duckdb_schema`). It now stores the footer's row count and leaf column paths (nested fields joined with `.`).
  - Files whose declared footer does not fit in the file are now indexed as invalid, matching Quick Look.
  - Removed `src/ParquetBounds.h` and its test; limits live in `ParquetParserBounds`.
- Added Arrow-generated fixtures (`Tests/fixtures`, `make_fixtures.R`) and tests that check both the Swift parser and the importer's C entry point against Arrow's row and column counts.

- Build universal binaries (arm64 + x86_64) with an explicit macOS 13.0 deployment target. Previous builds silently required the build host's macOS (26 for 0.4.3) and Apple silicon.
- Raised the documented and declared minimum macOS from 12.0 to 13.0; the manager app's SwiftUI layout requires macOS 13.
- `install.sh` updates an existing `/Applications` install in place instead of adding a second copy in `~/Applications`.
- `uninstall.sh` treats the protected container removal as best effort and also removes the `/Applications` copy.
- Manager app shows its version in the sidebar.
- README: updated Gatekeeper instructions for macOS 15+.
- CI: pinned `actions/checkout` to a full commit SHA and stopped persisting checkout credentials.

## 0.4.3 - 2026-10-24

- Added `Export Schema (JSON)` button in Quick Look previews (file and dataset views).
- Added Arrow-friendly schema export payload:
  - nested schema tree
  - flat field map with logical/physical types
  - reusable R and Python Arrow snippet stubs.
- Added a versioned schema-export envelope (`parquet-quicklook-arrow-schema-v1`) so additional export schemes can be added later in a compatible way.
- Quick Look headings now show the installed version (`Parquet Quick Look (vX.Y.Z)`, `Parquet Dataset Quick Look (vX.Y.Z)`).
- The `Show JSON` button now toggles the export pane and reads `Hide JSON` while it is open.
- Hardened Quick Look footer parsing against malformed metadata:
  - bound nesting depth and declared container sizes by remaining input
  - overflow-checked field ids, binary lengths, and row-group sums
  - cap total skip work so parse cost stays linear in the footer size
  - skip reading footers larger than 16 MiB (file is still shown as valid Parquet, without columns), matching the importer
- Use saturating sums for Quick Look dataset size and row totals.
- Pass the app bundle path to the uninstall shell as a positional argument.
- Bound Spotlight importer footer reads (16 MiB) and column extraction (4096).
- Harden the release workflow: pin actions to full commit SHAs, pass the tag via the environment, and do not persist checkout credentials.
- Added sanity-bounds tests for importer footer limits, parser count/total helpers, uninstall argument construction, and release-workflow pinning (any full commit SHA is accepted).
- Bumped importer, app, and extension versions to `0.4.3`.

## 0.4.2 - 2026-03-12

- Fixed GitHub Release Assets workflow shell compatibility:
  - use `bash` in the packaging step (`release.yml`) instead of unsupported `/bin/zsh`.
- Improved script test portability:
  - `scripts/test_scripts.sh` now falls back to `grep -Fq` when `rg` is unavailable.
- Bumped importer, app, and extension versions to `0.4.2`.

## 0.4.1 - 2026-03-12

- Hardened update checks:
  - pinned trusted GitHub API/release URL hosts and paths
  - strict release tag validation (`vX.Y.Z`) before version comparison
  - clearer offline/timeout/HTTP/rate-limit error messages.
- Added in-app diagnostics export (`Copy Diagnostic Report`) for issue reporting:
  - includes plugin status, key paths, versions, registration snapshots, settings, and recent errors
  - anonymizes usernames and redacts common secret/token patterns before copying.
- Added script smoke test suite (`scripts/test_scripts.sh`) and wired it into CI:
  - CI runs on every push and pull request
  - build script success + artifact existence
  - uninstall dry-run behavior
  - release script guard checks (`--help`, invalid tag, missing notes file)
  - core logic harness (`scripts/test_core.sh`) for update validation, diagnostics redaction, and dependency-injected status/registration evaluation.
- Hardened build signing against intermittent metadata/xattr contamination:
  - bundle sanitization before signing
  - signed-bundle retry logic in `scripts/build.sh`.
- Added rollback documentation with a short "revert to previous version" path in `README.md`.
- Added GitHub bug report template at `.github/ISSUE_TEMPLATE/bug_report.yml` with required diagnostics section and optional diagnostic-file upload note.
- Bumped importer, app, and extension versions to `0.4.1`.

## 0.4.0 - 2026-03-12

- Added Quick Look folder support for parquet datasets.
- Added dataset preview summary for folders containing parquet files:
  - parquet file count and valid-file count
  - total size and summed rows (footer-derived)
  - merged schema view with existing collapsible tree rendering
  - hive partition summary from `key=value` path segments.
- Added dataset scan controls in Quick Look settings:
  - `Scan all files`
  - `Max files (if not all)`
  - `Recursive scan folders`
- Added update-check UX:
  - new dedicated `Updates` tab
  - auto-check intervals (`Daily`, `Weekly`, `Monthly`; default `Daily`)
  - manual `Check for Updates...` action
  - update dialog with `Open Release Page`, `Skip this version`, and `Later`
  - up-to-date/error dialogs with app icon and current app version context.
- Added fallback behavior for non-parquet folders by returning no preview so the standard macOS folder Quick Look remains available.
- Merged management actions into the `Status` pane (removed separate `Actions` tab).
- Added app auto-install of the Spotlight importer on launch when missing.
- Updated uninstall flow:
  - explicit confirmation prompt before uninstall
  - warning that Finder will be restarted
  - full cleanup of settings/preferences/cache/container data (best effort for protected container root).
- Bumped importer, app, and extension versions to `0.4.0`.

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
