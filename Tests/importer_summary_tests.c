// Calls the importer's C entry point (parquet_read_summary) on Tests/fixtures and checks it
// against expected.txt, the same Arrow-derived expectations the Swift core tests use.
#include "../src/ParquetSummary.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void check(int ok, const char *file, const char *what) {
    if (!ok) {
        fprintf(stderr, "FAIL: %s: %s\n", file, what);
        failures++;
    }
}

static void join_columns(CFArrayRef columns, char *out, size_t outSize) {
    out[0] = '\0';
    if (columns == NULL) {
        return;
    }
    CFIndex count = CFArrayGetCount(columns);
    for (CFIndex i = 0; i < count; i++) {
        char name[512];
        CFStringRef s = (CFStringRef)CFArrayGetValueAtIndex(columns, i);
        if (!CFStringGetCString(s, name, sizeof(name), kCFStringEncodingUTF8)) {
            strcpy(name, "?");
        }
        if (i > 0) {
            strlcat(out, ",", outSize);
        }
        strlcat(out, name, outSize);
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <fixtures-dir>\n", argv[0]);
        return 2;
    }

    char expectedPath[1024];
    snprintf(expectedPath, sizeof(expectedPath), "%s/expected.txt", argv[1]);
    FILE *expected = fopen(expectedPath, "r");
    if (expected == NULL) {
        fprintf(stderr, "FAIL: cannot open %s\n", expectedPath);
        return 1;
    }

    static char line[65536];
    static char joined[65536];
    int checked = 0;
    while (fgets(line, sizeof(line), expected) != NULL) {
        if (line[0] == '#' || line[0] == '\n') {
            continue;
        }
        line[strcspn(line, "\n")] = '\0';

        char *cursor = line;
        char *file = strsep(&cursor, "|");
        char *valid = strsep(&cursor, "|");
        char *rows = strsep(&cursor, "|");
        char *count = strsep(&cursor, "|");
        char *paths = cursor;
        if (file == NULL || valid == NULL || rows == NULL || count == NULL || paths == NULL) {
            fprintf(stderr, "FAIL: malformed expected.txt line\n");
            return 1;
        }

        char path[1024];
        snprintf(path, sizeof(path), "%s/%s", argv[1], file);
        uint64_t fileSize = 0;
        uint32_t footerLength = 0;
        int64_t rowCount = -1;
        void *columnsRef = NULL;
        int32_t isValid = parquet_read_summary(path, &fileSize, &footerLength, &rowCount, &columnsRef);
        CFArrayRef columns = (CFArrayRef)columnsRef;

        check(isValid == atoi(valid), file, "valid");
        check(rowCount == strtoll(rows, NULL, 10), file, "row count");
        check((columns ? CFArrayGetCount(columns) : 0) == atol(count), file, "column count");
        join_columns(columns, joined, sizeof(joined));
        check(strcmp(joined, paths) == 0, file, "column paths");

        if (columns != NULL) {
            CFRelease(columns);
        }
        checked++;
    }
    fclose(expected);

    if (checked < 6) {
        fprintf(stderr, "FAIL: expected at least 6 fixtures, checked %d\n", checked);
        return 1;
    }
    if (failures > 0) {
        return 1;
    }
    printf("PASS: importer summary tests completed\n");
    return 0;
}
