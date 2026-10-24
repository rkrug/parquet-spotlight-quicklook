import Foundation

// C entry point for the Spotlight importer shell (src/MetadataImporter.c), declared in
// src/ParquetSummary.h. Parsing lives in Sources/ParquetCore/ParquetFooterParser.swift,
// shared with the Quick Look extension.
//
// Returns a +1 retained CFDictionary of Spotlight attributes for the file at `path`; the
// shell copies it into the importer's attribute dictionary. `com_rkrug_parquet_is_valid`
// is always set. Custom attribute names must match resources/schema.xml.
@_cdecl("parquet_copy_attributes")
public func parquetCopyAttributes(_ path: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let attributes = spotlightAttributes(path: String(cString: path)) as NSDictionary
    return Unmanaged.passRetained(attributes as CFDictionary).toOpaque()
}

func spotlightAttributes(path: String) -> [String: Any] {
    var attrs: [String: Any] = [
        "kMDItemTitle": (path as NSString).lastPathComponent,
        "kMDItemKind": "Apache Parquet file",
    ]
    let summary = ParquetFooter.read(at: URL(fileURLWithPath: path))
    guard summary.valid else {
        attrs["com_rkrug_parquet_is_valid"] = false
        attrs["kMDItemKeywords"] = ["parquet-invalid"]
        attrs["kMDItemDescription"] = "Invalid or unreadable Parquet footer"
        attrs["kMDItemTextContent"] = "parquet valid false"
        return attrs
    }

    // Unique column names (capped) and the matching "name:type" strings, e.g. "ts:timestamp[us]".
    var names: [String] = []
    var types: [String] = []
    var seen = Set<String>()
    for column in summary.columns where seen.insert(column.name).inserted {
        names.append(column.name)
        types.append("\(column.name):\(column.logicalType)")
        if names.count >= ParquetParserBounds.maxIndexedColumns { break }
    }
    let directory = (path as NSString).deletingLastPathComponent
    let partitions = ParquetFooter.partitions(inDirectoryPath: directory).map { "\($0.key)=\($0.value)" }
    let metadataKeys = summary.keyValueMetadata.map(\.key)

    attrs["com_rkrug_parquet_is_valid"] = true
    attrs["com_rkrug_parquet_file_size"] = NSNumber(value: Int64(clamping: summary.fileSize))
    attrs["com_rkrug_parquet_footer_length"] = NSNumber(value: Int64(summary.footerLength))
    attrs["com_rkrug_parquet_row_count"] = NSNumber(value: summary.rowCount)
    attrs["com_rkrug_parquet_column_count"] = NSNumber(value: names.count)
    if !names.isEmpty {
        attrs["com_rkrug_parquet_columns"] = names
        attrs["com_rkrug_parquet_column_types"] = types
    }
    if !partitions.isEmpty { attrs["com_rkrug_parquet_partitions"] = partitions }
    if !metadataKeys.isEmpty { attrs["com_rkrug_parquet_metadata_keys"] = metadataKeys }
    if let createdBy = summary.createdBy, !createdBy.isEmpty { attrs["kMDItemCreator"] = createdBy }
    if let range = summary.dateRange {
        attrs["com_rkrug_parquet_date_min"] = range.min
        attrs["com_rkrug_parquet_date_max"] = range.max
    }
    attrs["kMDItemDescription"] = "Parquet metadata footer: \(summary.footerLength) bytes (file size: \(summary.fileSize) bytes)"

    attrs["kMDItemKeywords"] = [
        "parquet", "parquet-valid",
        "parquet-footer-\(summary.footerLength)", "parquet-size-\(summary.fileSize)",
        "parquet-rows-\(summary.rowCount)", "parquet-cols-\(names.count)",
    ] + keywords(names, prefix: "col-") + keywords(partitions, prefix: "part-") + keywords(metadataKeys, prefix: "meta-")

    // Text content holds metadata tokens only, never row data.
    var text = "parquet valid true footer \(summary.footerLength) size \(summary.fileSize) rows \(summary.rowCount) cols \(names.count)"
    for name in names.prefix(32) { text += " col \(name)" }
    for partition in partitions { text += " partition \(partition)" }
    if let createdBy = summary.createdBy { text += " writer \(createdBy)" }
    attrs["kMDItemTextContent"] = text
    return attrs
}

// "<prefix><value>", lowercased with ' ' and '.' -> '_' and '=' -> '-'
// (columns: col-point_x, partitions: part-year-2024, metadata keys: meta-arrow:schema).
private func keywords(_ values: [String], prefix: String) -> [String] {
    values.map { value in
        prefix + value.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }
}
