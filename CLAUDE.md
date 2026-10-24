# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS-only (min 13.0, universal arm64 + x86_64) Spotlight importer + Quick Look preview for `.parquet` files. Pure shell + clang + swiftc, no Xcode project, no package manager. Only Parquet **footer metadata** is read; row data is never parsed.

## Commands

```bash
./scripts/build.sh          # builds into build/ and ad-hoc codesigns
./scripts/install.sh        # installs to ~/Library/Spotlight and ~/Applications
./scripts/uninstall.sh [--dry-run]
./scripts/test_scripts.sh   # script smoke tests (this is what CI runs); also calls test_core.sh
./scripts/test_core.sh      # compiles Sources/ParquetCore + Tests/core_tests.swift into one binary and runs it (incl. Tests/fixtures)
./scripts/test_importer_summary.sh   # importer's C entry point against the same fixtures
Rscript Tests/fixtures/make_fixtures.R   # regenerate fixtures + expected.txt (needs R arrow)
./scripts/test_install.sh [file.parquet]   # post-install self-test
./scripts/release.sh vX.Y.Z [--notes f] [--skip-gh]   # DMG/zip/sha256 + GitHub release; requires clean, synced `main`
```

There is no way to run a single core test; `Tests/core_tests.swift` is one executable. Manual checks: `mdimport -t -d2 file.parquet` (needs the importer installed; `mdimport -g` is gone), `mdls -name com_rkrug_parquet_is_valid file.parquet`, `qlmanage -p file.parquet`.

## Architecture

Three artifacts, all produced by `scripts/build.sh`:

- **`build/Parquet.mdimporter`** — `src/MetadataImporter.c` (thin C CFPlugIn shell) calling `parquet_read_summary` from `src/ImporterBridge.swift`, linked as a bundle against `/usr/lib/swift`; plus `plist/Info.plist` + `resources/schema.xml`. Declares UTI `com.rkrug.parquet` and the custom `com_rkrug_parquet_*` attributes; keep `schema.xml` and the attribute writes in the C file in sync, and README's "Exposed Properties" lists them.
- **`Parquet Quick Look and Index.app`** — GUI manager (`preview/app/AppMain.swift`): install/repair/uninstall, settings, update checks, diagnostics. Embeds the importer payload and the appex.
- **`ParquetQuickLook.appex`** — modern Quick Look preview extension (`preview/extension/PreviewProvider.swift`, plus `NSExtensionMain.m` entry). Renders schema tree, dataset-folder summaries, and Arrow schema JSON export.

`Sources/ParquetCore/` holds pure logic (footer parser, parser bounds, update URL/tag trust checks, version comparison, error mapping, diagnostics redaction, status logic). `build.sh` compiles all of it into the app, but only `ParserBounds.swift` + `ParquetFooterParser.swift` into the extension and the importer; `test_core.sh` tests it, so keep it free of UI/AppKit dependencies.

There is one Parquet footer parser (`ParquetFooterParser.swift`, Thrift compact protocol) for both Quick Look and Spotlight. Footers are untrusted input: keep reads bounded via `ParquetParserBounds`.

`build.sh` sets the deployment target (`MIN_MACOS`) and builds each Swift binary once per architecture, merging with `lipo`. Without an explicit `-target`, swiftc silently targets the build host's macOS version and architecture. Check with `vtool -show-build` / `lipo -archs` after changing the build.

## Versioning/release

Version strings live in `plist/Info.plist`, `preview/app/Info.plist`, `preview/extension/Info.plist`, and are updated alongside `CHANGELOG.md` and `NEWS.md`. Tagged releases are built by `.github/workflows/release.yml`. Releases are ad-hoc signed only (not notarized). Branch workflow: development on `dev`, release from `main`.
