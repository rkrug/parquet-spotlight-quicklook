// Wrapper around the vendored single-file zstd decoder (one translation unit).
#include "zstddeclib.c"
#include "parquet_zstd.h"

long parquet_zstd_decompress(const void *src, size_t src_size, void *dst, size_t dst_capacity) {
    ZSTD_DStream *stream = ZSTD_createDStream();
    if (stream == NULL) {
        return -1;
    }
    ZSTD_inBuffer in = { src, src_size, 0 };
    ZSTD_outBuffer out = { dst, dst_capacity, 0 };
    long result = 0;
    while (out.pos < out.size) {
        size_t in_before = in.pos, out_before = out.pos;
        size_t hint = ZSTD_decompressStream(stream, &out, &in);
        if (ZSTD_isError(hint)) {
            result = -1;
            break;
        }
        // Frame complete and all input used, or no progress (input ends inside a frame).
        if ((hint == 0 && in.pos == in.size) || (in.pos == in_before && out.pos == out_before)) {
            break;
        }
    }
    if (result == 0) {
        result = (long)out.pos;
    }
    ZSTD_freeDStream(stream);
    return result;
}
