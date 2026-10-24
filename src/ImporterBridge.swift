import Foundation

// C entry point for the Spotlight importer shell (src/MetadataImporter.c), declared in
// src/ParquetSummary.h. Parsing lives in Sources/ParquetCore/ParquetFooterParser.swift,
// shared with the Quick Look extension.
//
// Returns 1 for a valid Parquet trailer, 0 otherwise. *columns receives a +1 retained
// CFArray of unique column names (capped at maxIndexedColumns), or NULL when there are none.
@_cdecl("parquet_read_summary")
public func parquetReadSummary(
    _ path: UnsafePointer<CChar>,
    _ fileSize: UnsafeMutablePointer<UInt64>,
    _ footerLength: UnsafeMutablePointer<UInt32>,
    _ rowCount: UnsafeMutablePointer<Int64>,
    _ columns: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) -> Int32 {
    let summary = ParquetFooter.read(at: URL(fileURLWithPath: String(cString: path)))
    fileSize.pointee = summary.fileSize
    footerLength.pointee = summary.footerLength
    rowCount.pointee = summary.rowCount

    var names: [String] = []
    var seen = Set<String>()
    for column in summary.columns where seen.insert(column.name).inserted {
        names.append(column.name)
        if names.count >= ParquetParserBounds.maxIndexedColumns {
            break
        }
    }
    columns.pointee = names.isEmpty ? nil : Unmanaged.passRetained(names as CFArray).toOpaque()

    return summary.valid ? 1 : 0
}

// Hive partitions in the file's directory path as a +1 retained CFArray of "key=value"
// strings (outermost first), or NULL when there are none. Only the path is used.
@_cdecl("parquet_read_partitions")
public func parquetReadPartitions(_ path: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    let directory = (String(cString: path) as NSString).deletingLastPathComponent
    let partitions = ParquetFooter.partitions(inDirectoryPath: directory).map { "\($0.key)=\($0.value)" }
    return partitions.isEmpty ? nil : Unmanaged.passRetained(partitions as CFArray).toOpaque()
}
