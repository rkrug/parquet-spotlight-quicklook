#ifndef PARQUET_BOUNDS_H
#define PARQUET_BOUNDS_H

#include <stdint.h>
#include <sys/types.h>

// Upper bounds for footer metadata read from untrusted files.
#define PARQUET_MAX_FOOTER_LEN (16u * 1024u * 1024u)
#define PARQUET_MAX_COLUMNS 4096

// Reject empty footers, declared lengths above the cap, and lengths that
// cannot fit with the 8-byte trailer.
static inline int parquet_footer_length_acceptable(uint32_t meta_len, off_t file_size) {
    if (meta_len == 0 || meta_len > PARQUET_MAX_FOOTER_LEN) {
        return 0;
    }
    if ((off_t)meta_len + 8 > file_size) {
        return 0;
    }
    return 1;
}

#endif
