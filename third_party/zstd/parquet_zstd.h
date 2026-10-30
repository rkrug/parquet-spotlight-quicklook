#ifndef PARQUET_ZSTD_H
#define PARQUET_ZSTD_H

#include <stddef.h>

// Decodes Zstandard frames from src into dst until dst is full or the input ends. Returns the
// bytes written, or -1 for invalid data. Used by ParquetRowReader (Swift) via this header.
long parquet_zstd_decompress(const void *src, size_t src_size, void *dst, size_t dst_capacity);

#endif
