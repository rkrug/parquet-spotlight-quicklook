# zstd decompressor (vendored)

`zstddeclib.c` is the single-file Zstandard **decoder** from zstd 1.5.7
(https://github.com/facebook/zstd, release `v1.5.7`, BSD license, see `LICENSE`).
It is used only by the Quick Look Data tab to read ZSTD-compressed Parquet pages
(`Sources/ParquetCore/ParquetRowReader.swift`); the Spotlight importer does not include it.

Generated from the release tarball `zstd-1.5.7.tar.gz`
(SHA-256 `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`, as published with the release):

```sh
cd zstd-1.5.7/build/single_file_libs
sh ./combine.sh -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

`parquet_zstd.c` / `parquet_zstd.h` are this project's wrapper: one function that decodes up to
a given number of bytes, so large pages can be read from their start.
