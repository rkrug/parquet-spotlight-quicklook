#ifndef PARQUET_SUMMARY_H
#define PARQUET_SUMMARY_H

#include <stdint.h>

// Implemented in Swift (src/ImporterBridge.swift) on top of the shared footer parser.
// Returns 1 for a valid Parquet trailer, 0 otherwise. *columns receives a +1 retained
// CFArrayRef of CFString column names, or NULL; the caller releases it.
int32_t parquet_read_summary(const char *path,
                             uint64_t *file_size,
                             uint32_t *footer_length,
                             int64_t *row_count,
                             void **columns);

#endif
