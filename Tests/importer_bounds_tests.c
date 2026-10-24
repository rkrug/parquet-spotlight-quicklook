#include "../src/ParquetBounds.h"

#include <stdio.h>
#include <stdlib.h>

static void fail(const char *message) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
}

int main(void) {
    if (PARQUET_MAX_FOOTER_LEN != (16u * 1024u * 1024u)) {
        fail("footer length cap should be 16 MiB");
    }
    if (PARQUET_MAX_COLUMNS != 4096) {
        fail("column cap should be 4096");
    }

    if (parquet_footer_length_acceptable(0, 128) != 0) {
        fail("empty footer length should be rejected");
    }
    if (parquet_footer_length_acceptable(PARQUET_MAX_FOOTER_LEN + 1, (off_t)PARQUET_MAX_FOOTER_LEN + 64) != 0) {
        fail("declared footer above the cap should be rejected");
    }
    if (parquet_footer_length_acceptable(32, 32) != 0) {
        fail("footer that cannot fit with the trailer should be rejected");
    }
    if (parquet_footer_length_acceptable(32, 40) != 1) {
        fail("footer that fits with the trailer should be accepted");
    }
    if (parquet_footer_length_acceptable(PARQUET_MAX_FOOTER_LEN, (off_t)PARQUET_MAX_FOOTER_LEN + 8) != 1) {
        fail("footer at the cap should be accepted when the file is large enough");
    }

    printf("PASS: importer bounds tests completed\n");
    return 0;
}
