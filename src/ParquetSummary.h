#ifndef PARQUET_SUMMARY_H
#define PARQUET_SUMMARY_H

#include <stdint.h>

// Implemented in Swift (src/ImporterBridge.swift) on top of the shared footer parser.
// Returns 1 for a valid Parquet trailer, 0 otherwise. *columns receives a +1 retained
// CFArrayRef of CFString column names, or NULL; *column_types the matching "name:type"
// CFStrings (e.g. "ts:timestamp[us]"), or NULL. The caller releases both.
int32_t parquet_read_summary(const char *path,
                             uint64_t *file_size,
                             uint32_t *footer_length,
                             int64_t *row_count,
                             void **columns,
                             void **column_types);

// Hive partitions (`key=value` directories) in the file's path: a +1 retained CFArrayRef of
// "key=value" CFStrings, outermost first, or NULL; the caller releases it.
void *parquet_read_partitions(const char *path);

#endif
