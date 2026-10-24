#ifndef PARQUET_SUMMARY_H
#define PARQUET_SUMMARY_H

// Implemented in Swift (src/ImporterBridge.swift) on top of the shared footer parser.
// Returns a +1 retained CFDictionaryRef of Spotlight attributes for the file (never NULL);
// `com_rkrug_parquet_is_valid` tells whether the Parquet trailer was valid. The caller releases it.
void *parquet_copy_attributes(const char *path);

#endif
