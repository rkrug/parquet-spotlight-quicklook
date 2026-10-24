import Foundation

// Shared sanity bounds for untrusted Parquet footer metadata.
// Keep these aligned with CompactParser in PreviewProvider.swift and
// src/ParquetBounds.h.
public enum ParquetParserBounds {
    public static let maxDepth = 100
    public static let maxIndexedColumns = 4096
    public static let maxFooterLength = 16 * 1024 * 1024

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
