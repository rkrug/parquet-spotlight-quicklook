// Calls the importer's C entry point (parquet_copy_attributes) on Tests/fixtures and checks the
// Spotlight attributes against expected.txt, the same Arrow-derived expectations the Swift core
// tests use, plus footer.parquet's writer, metadata keys and date range.
// argv[2] is a copy of flat.parquet inside hive-style `key=value` folders.
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

static CFTypeRef attr(CFDictionaryRef attrs, const char *key) {
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFTypeRef value = CFDictionaryGetValue(attrs, k);
    CFRelease(k);
    return value;
}

static int64_t attr_int(CFDictionaryRef attrs, const char *key) {
    int64_t value = -1;
    CFNumberRef n = (CFNumberRef)attr(attrs, key);
    if (n != NULL && CFGetTypeID(n) == CFNumberGetTypeID()) {
        CFNumberGetValue(n, kCFNumberSInt64Type, &value);
    }
    return value;
}

// Joins a CFArray of strings (or one CFString) with ','.
static void join(CFTypeRef values, char *out, size_t outSize) {
    out[0] = '\0';
    if (values == NULL) {
        return;
    }
    if (CFGetTypeID(values) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)values, out, (CFIndex)outSize, kCFStringEncodingUTF8);
        return;
    }
    CFIndex count = CFArrayGetCount((CFArrayRef)values);
    for (CFIndex i = 0; i < count; i++) {
        char item[512];
        if (!CFStringGetCString((CFStringRef)CFArrayGetValueAtIndex((CFArrayRef)values, i), item, sizeof(item), kCFStringEncodingUTF8)) {
            strcpy(item, "?");
        }
        if (i > 0) {
            strlcat(out, ",", outSize);
        }
        strlcat(out, item, outSize);
    }
}

static int has_string(CFTypeRef values, const char *needle) {
    if (values == NULL || CFGetTypeID(values) != CFArrayGetTypeID()) {
        return 0;
    }
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, needle, kCFStringEncodingUTF8);
    int found = CFArrayContainsValue((CFArrayRef)values, CFRangeMake(0, CFArrayGetCount((CFArrayRef)values)), s);
    CFRelease(s);
    return found;
}

// Seconds since 1970 of a CFDate attribute, or -1e18 when missing.
static double attr_unix_time(CFDictionaryRef attrs, const char *key) {
    CFDateRef d = (CFDateRef)attr(attrs, key);
    if (d == NULL || CFGetTypeID(d) != CFDateGetTypeID()) {
        return -1e18;
    }
    return CFDateGetAbsoluteTime(d) + kCFAbsoluteTimeIntervalSince1970;
}

static CFDictionaryRef copy_attributes(const char *path) {
    return (CFDictionaryRef)parquet_copy_attributes(path);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <fixtures-dir> <hive-partitioned-copy-of-flat.parquet>\n", argv[0]);
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
        CFDictionaryRef attrs = copy_attributes(path);
        int isValid = attr(attrs, "com_rkrug_parquet_is_valid") == kCFBooleanTrue;

        check(isValid == atoi(valid), file, "valid");
        check(attr(attrs, "kMDItemKind") != NULL, file, "kind always set");
        if (isValid) {
            check(attr_int(attrs, "com_rkrug_parquet_row_count") == strtoll(rows, NULL, 10), file, "row count");
            check(attr_int(attrs, "com_rkrug_parquet_column_count") == atol(count), file, "column count");
            join(attr(attrs, "com_rkrug_parquet_columns"), joined, sizeof(joined));
            check(strcmp(joined, paths) == 0, file, "column paths");
            CFTypeRef types = attr(attrs, "com_rkrug_parquet_column_types");
            check((types ? CFArrayGetCount((CFArrayRef)types) : 0) == atol(count), file, "one type per column");
            check(has_string(attr(attrs, "kMDItemKeywords"), "parquet-valid"), file, "parquet-valid keyword");
            check(attr(attrs, "com_rkrug_parquet_partitions") == NULL, file, "no partitions outside key=value folders");
        } else {
            check(has_string(attr(attrs, "kMDItemKeywords"), "parquet-invalid"), file, "parquet-invalid keyword");
        }

        if (strcmp(file, "flat.parquet") == 0) {
            join(attr(attrs, "com_rkrug_parquet_column_types"), joined, sizeof(joined));
            check(strcmp(joined, "id:int32,score:double,name:string,flag:bool,day:date32[day],ts:timestamp[us],amount:decimal(10,2)") == 0,
                  file, "column types");
            check(has_string(attr(attrs, "kMDItemKeywords"), "col-amount"), file, "col- keyword");
        }
        if (strcmp(file, "footer.parquet") == 0) {
            join(attr(attrs, "kMDItemCreator"), joined, sizeof(joined));
            check(strcmp(joined, "parquet-cpp-arrow version 24.0.0") == 0, file, "kMDItemCreator = created_by");
            CFTypeRef keys = attr(attrs, "com_rkrug_parquet_metadata_keys");
            check(has_string(keys, "owner") && has_string(keys, "ARROW:schema"), file, "metadata keys");
            check(has_string(attr(attrs, "kMDItemKeywords"), "meta-owner"), file, "meta- keyword");
            // 1999-12-31 23:59:59 UTC and 2024-11-30 UTC.
            check(attr_unix_time(attrs, "com_rkrug_parquet_date_min") == 946684799.0, file, "date min");
            check(attr_unix_time(attrs, "com_rkrug_parquet_date_max") == 1732924800.0, file, "date max");
        }
        if (strcmp(file, "rowgroups.parquet") == 0) {
            check(attr(attrs, "com_rkrug_parquet_date_min") == NULL, file, "no date range without date columns");
        }
        CFRelease(attrs);
        checked++;
    }
    fclose(expected);

    CFDictionaryRef hive = copy_attributes(argv[2]);
    join(attr(hive, "com_rkrug_parquet_partitions"), joined, sizeof(joined));
    check(strcmp(joined, "year=2024,region=EU West") == 0, "partitions", "key=value list");
    check(has_string(attr(hive, "kMDItemKeywords"), "part-region-eu_west"), "partitions", "part- keyword");
    CFRelease(hive);

    if (checked < 7) {
        fprintf(stderr, "FAIL: expected at least 7 fixtures, checked %d\n", checked);
        return 1;
    }
    if (failures > 0) {
        return 1;
    }
    printf("PASS: importer summary tests completed\n");
    return 0;
}
