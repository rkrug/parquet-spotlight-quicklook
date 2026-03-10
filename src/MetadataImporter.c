#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>
#include <Metadata/MDImporter.h>

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <limits.h>
#include <ctype.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct MetadataImporterPluginType {
    MDImporterInterfaceStruct *conduitInterface;
    CFUUIDRef factoryID;
    UInt32 refCount;
} MetadataImporterPluginType;

static HRESULT MetadataImporterQueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv);
static ULONG MetadataImporterPluginAddRef(void *thisInstance);
static ULONG MetadataImporterPluginRelease(void *thisInstance);
Boolean GetMetadataForFile(void *thisInterface, CFMutableDictionaryRef attributes, CFStringRef contentTypeUTI, CFStringRef pathToFile);

void *MetadataImporterPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID);
static MetadataImporterPluginType *AllocMetadataImporterPluginType(CFAllocatorRef allocator);
static void DeallocMetadataImporterPluginType(void *thisInstance);

static MDImporterInterfaceStruct kMetadataImporterInterfaceFtbl = {
    NULL,
    MetadataImporterQueryInterface,
    MetadataImporterPluginAddRef,
    MetadataImporterPluginRelease,
    GetMetadataForFile
};

static CFUUIDRef kPluginFactoryUUID = NULL;
static CFStringRef kParquetFileSizeKey = CFSTR("com_rkrug_parquet_file_size");
static CFStringRef kParquetFooterLengthKey = CFSTR("com_rkrug_parquet_footer_length");
static CFStringRef kParquetIsValidKey = CFSTR("com_rkrug_parquet_is_valid");
static CFStringRef kParquetRowCountKey = CFSTR("com_rkrug_parquet_row_count");
static CFStringRef kParquetColumnCountKey = CFSTR("com_rkrug_parquet_column_count");
static CFStringRef kParquetColumnsKey = CFSTR("com_rkrug_parquet_columns");

static int read_parquet_footer(const char *path, uint64_t *file_size, uint32_t *footer_len) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }

    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return -1;
    }

    if (st.st_size < 12) {
        close(fd);
        return -1;
    }

    unsigned char trailer[8];
    if (pread(fd, trailer, sizeof(trailer), st.st_size - (off_t)sizeof(trailer)) != (ssize_t)sizeof(trailer)) {
        close(fd);
        return -1;
    }

    close(fd);

    if (memcmp(trailer + 4, "PAR1", 4) != 0) {
        return -1;
    }

    uint32_t len =
        (uint32_t)trailer[0] |
        ((uint32_t)trailer[1] << 8) |
        ((uint32_t)trailer[2] << 16) |
        ((uint32_t)trailer[3] << 24);

    *file_size = (uint64_t)st.st_size;
    *footer_len = len;
    return 0;
}

static void set_int64_attribute(CFMutableDictionaryRef attributes, CFStringRef key, int64_t value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
    if (number != NULL) {
        CFDictionarySetValue(attributes, key, number);
        CFRelease(number);
    }
}

static void add_metadata_keywords(CFMutableDictionaryRef attributes,
                                  uint64_t fileSize,
                                  uint32_t footerLen,
                                  int64_t rowCount,
                                  int64_t columnCount,
                                  CFArrayRef extraKeywords) {
    CFMutableArrayRef keywords = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (keywords == NULL) {
        return;
    }

    CFStringRef values[6];
    values[0] = CFSTR("parquet");
    values[1] = CFSTR("parquet-valid");
    values[2] = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("parquet-footer-%u"), footerLen);
    values[3] = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("parquet-size-%llu"), fileSize);
    values[4] = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("parquet-rows-%lld"), rowCount);
    values[5] = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("parquet-cols-%lld"), columnCount);

    for (int i = 0; i < 6; i++) {
        if (values[i] != NULL) {
            CFArrayAppendValue(keywords, values[i]);
        }
    }

    if (extraKeywords != NULL) {
        CFIndex count = CFArrayGetCount(extraKeywords);
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef value = CFArrayGetValueAtIndex(extraKeywords, i);
            if (value != NULL) {
                CFArrayAppendValue(keywords, value);
            }
        }
    }

    CFDictionarySetValue(attributes, kMDItemKeywords, keywords);
    CFRelease(keywords);

    for (int i = 2; i < 6; i++) {
        if (values[i] != NULL) {
            CFRelease(values[i]);
        }
    }
}

static int is_identifier_like(const unsigned char *s, uint32_t len) {
    if (len == 0 || len > 128) {
        return 0;
    }

    int has_alpha = 0;
    for (uint32_t i = 0; i < len; i++) {
        unsigned char c = s[i];
        if (isalpha(c)) {
            has_alpha = 1;
        }
        if (!(isalnum(c) || c == '_' || c == '-' || c == '.' || c == ' ')) {
            return 0;
        }
    }

    return has_alpha;
}

static int is_column_candidate(const char *s) {
    size_t len = strlen(s);
    if (len < 2 || len > 40) {
        return 0;
    }
    if (!(isalpha((unsigned char)s[0]) || s[0] == '_')) {
        return 0;
    }

    int has_lower = 0;
    int letters = 0;
    int digits = 0;
    int repeats = 1;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (islower(c)) {
            has_lower = 1;
        }
        if (isalpha(c)) {
            letters++;
        } else if (isdigit(c)) {
            digits++;
        }
        if (!(isalnum(c) || c == '_' || c == '-' || c == '.')) {
            return 0;
        }
        if (i > 0 && s[i] == s[i - 1]) {
            repeats++;
            if (repeats >= 4) {
                return 0;
            }
        } else {
            repeats = 1;
        }
    }

    if (!has_lower) {
        return 0;
    }
    if (letters < 2) {
        return 0;
    }
    if (digits > (int)(len / 3)) {
        return 0;
    }
    if (strstr(s, "AAA") != NULL) {
        return 0;
    }

    static const char *denylist[] = {
        "schema", "parquet", "created_by", "key_value_metadata", "column_orders",
        "columnorder", "thrift", "binary", "int32", "int64", "boolean", "list", "map",
        "attributes", "columns", "frame", "data", "class", "version", "utf-8", "arrow",
        "parquet-cpp-arrow"
    };
    for (size_t i = 0; i < sizeof(denylist) / sizeof(denylist[0]); i++) {
        if (strcasecmp(s, denylist[i]) == 0) {
            return 0;
        }
    }

    return 1;
}

static uint32_t be32_to_host(const unsigned char *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

static void append_unique_cfstring(CFMutableArrayRef array, CFStringRef value) {
    if (array == NULL || value == NULL) {
        return;
    }
    if (!CFArrayContainsValue(array, CFRangeMake(0, CFArrayGetCount(array)), value)) {
        CFArrayAppendValue(array, value);
    }
}

static CFArrayRef extract_parquet_column_names(const unsigned char *footer, size_t footerLen) {
    CFMutableArrayRef columns = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (columns == NULL || footer == NULL || footerLen < 8) {
        return columns;
    }

    // Best-effort parser for Thrift Binary field marker: string field id=4 -> 0x0b 0x00 0x04.
    for (size_t i = 0; i + 7 < footerLen; i++) {
        if (footer[i] != 0x0b || footer[i + 1] != 0x00 || footer[i + 2] != 0x04) {
            continue;
        }

        uint32_t slen = be32_to_host(footer + i + 3);
        size_t start = i + 7;
        if (slen == 0 || slen > 128 || start + slen > footerLen) {
            continue;
        }
        if (!is_identifier_like(footer + start, slen)) {
            continue;
        }

        CFStringRef name = CFStringCreateWithBytes(kCFAllocatorDefault, footer + start, slen, kCFStringEncodingUTF8, false);
        if (name == NULL) {
            continue;
        }
        if (!CFStringCompare(name, CFSTR("schema"), kCFCompareCaseInsensitive)) {
            CFRelease(name);
            continue;
        }
        append_unique_cfstring(columns, name);
        CFRelease(name);
    }

    // Fallback heuristic: scan footer for identifier-like ASCII strings.
    if (CFArrayGetCount(columns) == 0) {
        size_t i = 0;
        while (i < footerLen) {
            if (!(isalpha(footer[i]) || footer[i] == '_')) {
                i++;
                continue;
            }

            size_t start = i;
            while (i < footerLen && (isalnum(footer[i]) || footer[i] == '_' || footer[i] == '-' || footer[i] == '.')) {
                i++;
            }
            size_t len = i - start;
            if (len < 2 || len > 40) {
                continue;
            }

            char candidate[65];
            memcpy(candidate, footer + start, len);
            candidate[len] = '\0';
            if (!is_column_candidate(candidate)) {
                continue;
            }

            CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, candidate, kCFStringEncodingUTF8);
            if (name != NULL) {
                append_unique_cfstring(columns, name);
                CFRelease(name);
            }

            if (CFArrayGetCount(columns) >= 128) {
                break;
            }
        }
    }

    return columns;
}

static int read_parquet_footer_bytes(const char *path, unsigned char **outBytes, size_t *outLen) {
    *outBytes = NULL;
    *outLen = 0;

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 12) {
        close(fd);
        return -1;
    }

    unsigned char trailer[8];
    if (pread(fd, trailer, sizeof(trailer), st.st_size - (off_t)sizeof(trailer)) != (ssize_t)sizeof(trailer)) {
        close(fd);
        return -1;
    }
    if (memcmp(trailer + 4, "PAR1", 4) != 0) {
        close(fd);
        return -1;
    }

    uint32_t metaLenLE =
        (uint32_t)trailer[0] |
        ((uint32_t)trailer[1] << 8) |
        ((uint32_t)trailer[2] << 16) |
        ((uint32_t)trailer[3] << 24);
    if (metaLenLE == 0 || (off_t)metaLenLE + 8 > st.st_size) {
        close(fd);
        return -1;
    }

    unsigned char *buf = (unsigned char *)malloc(metaLenLE);
    if (buf == NULL) {
        close(fd);
        return -1;
    }

    off_t metaOffset = st.st_size - 8 - (off_t)metaLenLE;
    if (pread(fd, buf, metaLenLE, metaOffset) != (ssize_t)metaLenLE) {
        free(buf);
        close(fd);
        return -1;
    }

    close(fd);
    *outBytes = buf;
    *outLen = metaLenLE;
    return 0;
}

static CFArrayRef build_column_keywords(CFArrayRef columns) {
    if (columns == NULL) {
        return NULL;
    }

    CFMutableArrayRef colKeywords = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (colKeywords == NULL) {
        return NULL;
    }

    CFIndex count = CFArrayGetCount(columns);
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef col = (CFStringRef)CFArrayGetValueAtIndex(columns, i);
        if (col == NULL) {
            continue;
        }
        CFMutableStringRef normalized = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, col);
        if (normalized == NULL) {
            continue;
        }

        CFStringLowercase(normalized, NULL);
        CFStringFindAndReplace(normalized, CFSTR(" "), CFSTR("_"), CFRangeMake(0, CFStringGetLength(normalized)), 0);
        CFStringFindAndReplace(normalized, CFSTR("."), CFSTR("_"), CFRangeMake(0, CFStringGetLength(normalized)), 0);

        CFStringRef token = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("col-%@"), normalized);
        CFRelease(normalized);
        if (token != NULL) {
            CFArrayAppendValue(colKeywords, token);
            CFRelease(token);
        }
    }

    return colKeywords;
}

static int64_t extract_parquet_row_count(const unsigned char *footer, size_t footerLen) {
    if (footer == NULL || footerLen < 11) {
        return -1;
    }

    int64_t best = -1;
    for (size_t i = 0; i + 10 < footerLen; i++) {
        if (footer[i] != 0x0a || footer[i + 1] != 0x00 || footer[i + 2] != 0x03) {
            continue;
        }

        uint64_t v = 0;
        for (int j = 0; j < 8; j++) {
            v = (v << 8) | (uint64_t)footer[i + 3 + j];
        }
        if (v > (uint64_t)INT64_MAX) {
            continue;
        }

        int64_t candidate = (int64_t)v;
        if (candidate >= 0 && candidate > best) {
            best = candidate;
        }
    }

    return best;
}

void *MetadataImporterPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    if (!CFEqual(typeID, kMDImporterTypeID)) {
        return NULL;
    }

    return AllocMetadataImporterPluginType(allocator);
}

static MetadataImporterPluginType *AllocMetadataImporterPluginType(CFAllocatorRef allocator) {
    MetadataImporterPluginType *plugin = (MetadataImporterPluginType *)CFAllocatorAllocate(allocator, sizeof(MetadataImporterPluginType), 0);
    if (plugin == NULL) {
        return NULL;
    }

    plugin->conduitInterface = &kMetadataImporterInterfaceFtbl;
    plugin->refCount = 1;

    if (kPluginFactoryUUID == NULL) {
        kPluginFactoryUUID = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR("0E198062-E6D8-4AC2-BBCE-FB860A43A116"));
    }

    plugin->factoryID = CFRetain(kPluginFactoryUUID);
    CFPlugInAddInstanceForFactory(plugin->factoryID);

    return plugin;
}

static void DeallocMetadataImporterPluginType(void *thisInstance) {
    MetadataImporterPluginType *plugin = (MetadataImporterPluginType *)thisInstance;
    CFPlugInRemoveInstanceForFactory(plugin->factoryID);
    CFRelease(plugin->factoryID);
    CFAllocatorDeallocate(kCFAllocatorDefault, plugin);
}

static HRESULT MetadataImporterQueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv) {
    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);

    if (CFEqual(interfaceID, kMDImporterInterfaceID)) {
        MetadataImporterPluginAddRef(thisInstance);
        *ppv = thisInstance;
        CFRelease(interfaceID);
        return S_OK;
    }

    *ppv = NULL;
    CFRelease(interfaceID);
    return E_NOINTERFACE;
}

static ULONG MetadataImporterPluginAddRef(void *thisInstance) {
    MetadataImporterPluginType *plugin = (MetadataImporterPluginType *)thisInstance;
    return ++plugin->refCount;
}

static ULONG MetadataImporterPluginRelease(void *thisInstance) {
    MetadataImporterPluginType *plugin = (MetadataImporterPluginType *)thisInstance;
    UInt32 newCount = --plugin->refCount;

    if (newCount == 0) {
        DeallocMetadataImporterPluginType(thisInstance);
    }

    return newCount;
}

Boolean GetMetadataForFile(__unused void *thisInterface,
                           CFMutableDictionaryRef attributes,
                           __unused CFStringRef contentTypeUTI,
                           CFStringRef pathToFile) {
    if (attributes == NULL || pathToFile == NULL) {
        return false;
    }

    char path[PATH_MAX];
    if (!CFStringGetCString(pathToFile, path, sizeof(path), kCFStringEncodingUTF8)) {
        return false;
    }

    CFURLRef fileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, pathToFile, kCFURLPOSIXPathStyle, false);
    if (fileURL != NULL) {
        CFStringRef name = CFURLCopyLastPathComponent(fileURL);
        if (name != NULL) {
            CFDictionarySetValue(attributes, kMDItemTitle, name);
            CFRelease(name);
        }
        CFRelease(fileURL);
    }

    CFDictionarySetValue(attributes, kMDItemKind, CFSTR("Apache Parquet file"));

    // Keep text content limited to metadata tokens only.
    CFDictionarySetValue(attributes, kMDItemTextContent, CFSTR("parquet"));

    uint64_t fileSize = 0;
    uint32_t footerLen = 0;
    if (read_parquet_footer(path, &fileSize, &footerLen) == 0) {
        unsigned char *footerBytes = NULL;
        size_t footerBytesLen = 0;
        CFArrayRef columns = NULL;
        CFArrayRef columnKeywords = NULL;
        int64_t rowCount = 0;
        int64_t columnCount = 0;

        if (read_parquet_footer_bytes(path, &footerBytes, &footerBytesLen) == 0) {
            columns = extract_parquet_column_names(footerBytes, footerBytesLen);
            int64_t parsedRowCount = extract_parquet_row_count(footerBytes, footerBytesLen);
            if (parsedRowCount >= 0) {
                rowCount = parsedRowCount;
            }
            free(footerBytes);
            footerBytes = NULL;
        }

        if (columns != NULL && CFArrayGetCount(columns) > 0) {
            columnCount = (int64_t)CFArrayGetCount(columns);
            CFDictionarySetValue(attributes, kParquetColumnsKey, columns);
            columnKeywords = build_column_keywords(columns);
        }

        set_int64_attribute(attributes, kParquetFileSizeKey, (int64_t)fileSize);
        set_int64_attribute(attributes, kParquetFooterLengthKey, (int64_t)footerLen);
        set_int64_attribute(attributes, kParquetRowCountKey, rowCount);
        set_int64_attribute(attributes, kParquetColumnCountKey, columnCount);
        CFDictionarySetValue(attributes, kParquetIsValidKey, kCFBooleanTrue);

        CFStringRef description = CFStringCreateWithFormat(
            kCFAllocatorDefault,
            NULL,
            CFSTR("Parquet metadata footer: %u bytes (file size: %llu bytes)"),
            footerLen,
            fileSize);

        if (description != NULL) {
            CFDictionarySetValue(attributes, kMDItemDescription, description);
            CFRelease(description);
        }

        add_metadata_keywords(attributes, fileSize, footerLen, rowCount, columnCount, columnKeywords);

        CFStringRef tokenized = CFStringCreateWithFormat(
            kCFAllocatorDefault,
            NULL,
            CFSTR("parquet valid true footer %u size %llu rows %lld cols %lld"),
            footerLen,
            fileSize,
            rowCount,
            columnCount);
        if (tokenized != NULL) {
            if (columns != NULL && CFArrayGetCount(columns) > 0) {
                CFMutableStringRef enriched = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, tokenized);
                if (enriched != NULL) {
                    CFIndex colCount = CFArrayGetCount(columns);
                    CFIndex maxCols = colCount > 32 ? 32 : colCount;
                    for (CFIndex i = 0; i < maxCols; i++) {
                        CFStringRef col = (CFStringRef)CFArrayGetValueAtIndex(columns, i);
                        if (col != NULL) {
                            CFStringAppend(enriched, CFSTR(" col "));
                            CFStringAppend(enriched, col);
                        }
                    }
                    CFDictionarySetValue(attributes, kMDItemTextContent, enriched);
                    CFRelease(enriched);
                } else {
                    CFDictionarySetValue(attributes, kMDItemTextContent, tokenized);
                }
            } else {
                CFDictionarySetValue(attributes, kMDItemTextContent, tokenized);
            }
            CFRelease(tokenized);
        }

        if (columnKeywords != NULL) {
            CFRelease(columnKeywords);
        }
        if (columns != NULL) {
            CFRelease(columns);
        }
        return true;
    }

    CFDictionarySetValue(attributes, kParquetIsValidKey, kCFBooleanFalse);
    CFArrayRef invalidKeywords = CFArrayCreate(kCFAllocatorDefault, (const void **)&(CFStringRef){CFSTR("parquet-invalid")}, 1, &kCFTypeArrayCallBacks);
    if (invalidKeywords != NULL) {
        CFDictionarySetValue(attributes, kMDItemKeywords, invalidKeywords);
        CFRelease(invalidKeywords);
    }
    CFDictionarySetValue(attributes, kMDItemDescription, CFSTR("Invalid or unreadable Parquet footer"));
    CFDictionarySetValue(attributes, kMDItemTextContent, CFSTR("parquet valid false"));
    return false;
}
