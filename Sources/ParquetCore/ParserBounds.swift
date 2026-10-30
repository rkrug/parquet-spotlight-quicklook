import Foundation

// Shared sanity bounds for untrusted Parquet footer metadata.
// Used by ParquetFooterParser.swift (shared by the Quick Look extension and
// the Spotlight importer).
public enum ParquetParserBounds {
    public static let maxDepth = 100
    public static let maxIndexedColumns = 4096
    public static let maxPartitionSegments = 32
    public static let maxFooterLength = 16 * 1024 * 1024
    // Footer details kept for display; totals still cover every row group.
    public static let maxListedRowGroups = 200
    public static let maxMetadataEntries = 256
    public static let maxMetadataValueBytes = 4096
    // Row preview (ParquetRowReader): rows and columns shown, total cells (rows are cut to fit),
    // bytes read per column chunk, decompressed page size, page header size, dictionary entries,
    // and characters per cell.
    public static let maxPreviewRows = 10_000
    public static let maxPreviewColumns = 200
    public static let maxPreviewCells = 200_000
    public static let maxPreviewChunkBytes = 64 * 1024 * 1024
    public static let maxPreviewPageBytes = 32 * 1024 * 1024
    public static let maxPreviewPageHeaderBytes = 1024 * 1024
    public static let maxPreviewDictionaryValues = 1_000_000
    public static let maxPreviewCellCharacters = 500
    // Nested columns: levels decoded per page (only up to the rows shown), triples kept per row and leaf, and list items
    // shown per list (the rest is summarised as "… n more").
    public static let maxPreviewPageValues = 2_000_000
    public static let maxPreviewNestedValues = 10_000
    public static let maxPreviewNestedItems = 100

    // Every encoded element occupies at least one byte, so a declared count
    // can never legitimately exceed the bytes left to parse.
    public static func boundedCount(declared: Int, remaining: Int) -> Int {
        guard declared > 0, remaining > 0 else { return 0 }
        return min(declared, remaining)
    }

    // Total skip work is capped at a small multiple of the input size.
    public static func maxSkips(forInputBytes count: Int) -> Int {
        8 * max(0, count) + 100_000
    }

    public static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    public static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
