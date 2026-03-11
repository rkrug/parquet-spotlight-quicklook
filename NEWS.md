# News

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
