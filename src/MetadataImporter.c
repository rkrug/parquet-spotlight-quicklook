#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>
#include <Metadata/MDImporter.h>

#include <limits.h>
#include <stdint.h>

// Footer parsing is shared Swift code (Sources/ParquetCore/ParquetFooterParser.swift);
// this file is only the CFPlugIn shell that maps a summary to Spotlight attributes.
#include "ParquetSummary.h"

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
static CFStringRef kParquetPartitionsKey = CFSTR("com_rkrug_parquet_partitions");

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

// Appends "<prefix><value>" keywords, lowercased with ' ' and '.' -> '_' and '=' -> '-'
// (columns: col-point_x, partitions: part-year-2024).
static void append_keywords(CFMutableArrayRef keywords, CFArrayRef values, CFStringRef prefix) {
    if (keywords == NULL || values == NULL) {
        return;
    }

    CFIndex count = CFArrayGetCount(values);
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef value = (CFStringRef)CFArrayGetValueAtIndex(values, i);
        if (value == NULL) {
            continue;
        }
        CFMutableStringRef normalized = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, value);
        if (normalized == NULL) {
            continue;
        }

        CFStringLowercase(normalized, NULL);
        CFStringFindAndReplace(normalized, CFSTR(" "), CFSTR("_"), CFRangeMake(0, CFStringGetLength(normalized)), 0);
        CFStringFindAndReplace(normalized, CFSTR("."), CFSTR("_"), CFRangeMake(0, CFStringGetLength(normalized)), 0);
        CFStringFindAndReplace(normalized, CFSTR("="), CFSTR("-"), CFRangeMake(0, CFStringGetLength(normalized)), 0);

        CFStringRef token = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%@%@"), prefix, normalized);
        CFRelease(normalized);
        if (token != NULL) {
            CFArrayAppendValue(keywords, token);
            CFRelease(token);
        }
    }
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
    int64_t rowCount = 0;
    void *columnsRef = NULL;
    if (parquet_read_summary(path, &fileSize, &footerLen, &rowCount, &columnsRef) == 1) {
        CFArrayRef columns = (CFArrayRef)columnsRef;
        CFArrayRef partitions = (CFArrayRef)parquet_read_partitions(path);
        CFMutableArrayRef extraKeywords = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        int64_t columnCount = 0;

        if (columns != NULL && CFArrayGetCount(columns) > 0) {
            columnCount = (int64_t)CFArrayGetCount(columns);
            CFDictionarySetValue(attributes, kParquetColumnsKey, columns);
            append_keywords(extraKeywords, columns, CFSTR("col-"));
        }
        if (partitions != NULL) {
            CFDictionarySetValue(attributes, kParquetPartitionsKey, partitions);
            append_keywords(extraKeywords, partitions, CFSTR("part-"));
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

        add_metadata_keywords(attributes, fileSize, footerLen, rowCount, columnCount, extraKeywords);

        CFStringRef tokenized = CFStringCreateWithFormat(
            kCFAllocatorDefault,
            NULL,
            CFSTR("parquet valid true footer %u size %llu rows %lld cols %lld"),
            footerLen,
            fileSize,
            rowCount,
            columnCount);
        if (tokenized != NULL) {
            CFMutableStringRef enriched = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, tokenized);
            if (enriched != NULL) {
                CFIndex colCount = columns != NULL ? CFArrayGetCount(columns) : 0;
                CFIndex maxCols = colCount > 32 ? 32 : colCount;
                for (CFIndex i = 0; i < maxCols; i++) {
                    CFStringAppend(enriched, CFSTR(" col "));
                    CFStringAppend(enriched, (CFStringRef)CFArrayGetValueAtIndex(columns, i));
                }
                CFIndex partCount = partitions != NULL ? CFArrayGetCount(partitions) : 0;
                for (CFIndex i = 0; i < partCount; i++) {
                    CFStringAppend(enriched, CFSTR(" partition "));
                    CFStringAppend(enriched, (CFStringRef)CFArrayGetValueAtIndex(partitions, i));
                }
                CFDictionarySetValue(attributes, kMDItemTextContent, enriched);
                CFRelease(enriched);
            } else {
                CFDictionarySetValue(attributes, kMDItemTextContent, tokenized);
            }
            CFRelease(tokenized);
        }

        if (extraKeywords != NULL) {
            CFRelease(extraKeywords);
        }
        if (partitions != NULL) {
            CFRelease(partitions);
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
