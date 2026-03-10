# Contributing

## Development Setup

Prerequisites:

- macOS
- Xcode Command Line Tools (`xcrun`, `clang`, `codesign`)

Build:

```bash
./scripts/build.sh
```

Install locally:

```bash
./scripts/install.sh
```

## Verify Changes

Use a sample parquet file:

```bash
mdimport -t -d2 /path/to/file.parquet
mdls -name com_rkrug_parquet_is_valid \
     -name com_rkrug_parquet_footer_length \
     -name com_rkrug_parquet_file_size \
     /path/to/file.parquet
```

## Code Style

- Keep implementation minimal and metadata-only.
- Avoid parsing row data.
- Prefer small, focused changes.
- Keep documentation up to date with behavior changes.

