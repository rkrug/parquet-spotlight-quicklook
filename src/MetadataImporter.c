#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>
#include <Metadata/MDImporter.h>

#include <limits.h>

// Footer parsing is shared Swift code (Sources/ParquetCore/ParquetFooterParser.swift);
// this file is only the CFPlugIn shell that copies the Swift-built attributes into Spotlight's.
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

static void copy_attribute(const void *key, const void *value, void *context) {
    CFDictionarySetValue((CFMutableDictionaryRef)context, key, value);
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

    CFDictionaryRef parsed = (CFDictionaryRef)parquet_copy_attributes(path);
    if (parsed == NULL) {
        return false;
    }
    CFDictionaryApplyFunction(parsed, copy_attribute, attributes);
    Boolean valid = CFDictionaryGetValue(parsed, CFSTR("com_rkrug_parquet_is_valid")) == kCFBooleanTrue;
    CFRelease(parsed);
    return valid;
}
