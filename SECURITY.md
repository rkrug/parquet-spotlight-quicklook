# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| Latest stable release (currently 0.7.1) | Yes |
| Latest beta (currently 0.8.0-beta.1) | Yes |
| Older versions | No: update from the app (`Updates` → `Check for Updates Now`) |

Fixes are released as a new stable release or beta; there are no patch releases for older versions.

## Reporting a Vulnerability

Please report security issues privately through GitHub:
[Security → Report a vulnerability](https://github.com/rkrug/parquet-spotlight-quicklook/security/advisories/new).
Do not open a public issue for them.

Include:

- A clear description of the issue
- Affected version (shown in the app's sidebar) and macOS version
- Reproduction steps, and a sample file if the issue is triggered by one
- Potential impact

This is a personal project: you will receive an acknowledgement, usually within a week, and follow-up on how and when it is fixed.

## Security Model

What the app does, so you can judge reports and risks:

- **Files are untrusted input.** The Spotlight importer and the Quick Look extension parse Parquet footers with hard limits on sizes, counts, nesting depth and work, and the parsers are fuzz-tested in CI. Spotlight indexes metadata only, never row data. (The Quick Look `Data` tab in the beta reads the first rows of a file under the same rules.)
- **Network access is limited to updates.** The app contacts only the GitHub API for this repository's releases and downloads release assets from `github.com` over HTTPS; other hosts and URLs are rejected. Update checks can be turned off in the `Updates` tab.
- **Updates are signature-checked.** An in-app update is installed only if the downloaded ZIP has a valid Ed25519 signature for the public key built into the app, and the unpacked app has the expected bundle ID, version and a valid code signature. Otherwise nothing is installed and the release page is offered instead.
- **Builds are not notarized.** Releases are ad-hoc signed, not signed with an Apple Developer ID, so Gatekeeper warns on first launch (see the README). Download releases only from this repository's [Releases](https://github.com/rkrug/parquet-spotlight-quicklook/releases) page.
- **Third-party code.** The beta's Quick Look extension includes the Zstandard decoder from zstd 1.5.7 (BSD), generated from the checksummed release (see `third_party/zstd/README.md` on `dev`). The stable release has no third-party code.
