import Foundation

// Parquet footer parser shared by the Quick Look extension and the Spotlight importer
// (via src/ImporterBridge.swift). Footers come from untrusted files: keep every read
// bounded (see ParquetParserBounds).
public enum ParquetFooter {
    public struct Column: Equatable {
        public let name: String
        public let logicalType: String
        public let physicalType: String
        // Column-chunk metadata summed over all row groups (codec names in first-seen order).
        public var codecs: [String] = []
        public var compressedSize: Int64 = 0
        public var uncompressedSize: Int64 = 0
        // Range of date/timestamp columns from the chunk statistics, read as UTC.
        public var minDate: Date?
        public var maxDate: Date?

        public init(name: String, logicalType: String, physicalType: String) {
            self.name = name
            self.logicalType = logicalType
            self.physicalType = physicalType
        }
    }

    public struct RowGroup: Equatable {
        public var rows: Int64 = 0
        public var totalByteSize: Int64 = 0
        public var compressedSize: Int64 = 0
    }

    public struct KeyValue: Equatable {
        public let key: String
        // Cut to maxMetadataValueBytes; valueLength is the full length in bytes.
        public let value: String?
        public let valueLength: Int
    }

    public struct Summary {
        // A readable `<len>PAR1` trailer whose footer fits in the file.
        public var valid = false
        public var fileSize: UInt64 = 0
        public var footerLength: UInt32 = 0
        public var rowCount: Int64 = 0
        public var columns: [Column] = []
        public var createdBy: String?
        public var keyValueMetadata: [KeyValue] = []
        public var rowGroupCount = 0
        // The first maxListedRowGroups row groups.
        public var rowGroups: [RowGroup] = []

        public init() {}

        // Overall range across all date/timestamp columns.
        public var dateRange: (min: Date, max: Date)? {
            let mins = columns.compactMap(\.minDate)
            let maxs = columns.compactMap(\.maxDate)
            guard let lo = mins.min(), let hi = maxs.max() else { return nil }
            return (lo, hi)
        }
    }

    public static func read(at url: URL) -> Summary {
        var out = Summary()

        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return out
        }
        defer { try? fh.close() }

        let fileSize = (try? fh.seekToEnd()) ?? 0
        guard fileSize >= 12 else {
            return out
        }
        out.fileSize = fileSize

        do {
            try fh.seek(toOffset: fileSize - 8)
            let trailer = try fh.read(upToCount: 8) ?? Data()
            guard trailer.count == 8 else { return out }
            guard trailer.suffix(4) == Data("PAR1".utf8) else { return out }

            let footerLen = trailer.prefix(4).withUnsafeBytes { raw -> UInt32 in
                let b = raw.bindMemory(to: UInt8.self)
                return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            }
            out.footerLength = footerLen

            let footerOffset = Int64(fileSize) - 8 - Int64(footerLen)
            guard footerOffset >= 0 else { return out }
            // Oversize footers stay valid but are not read or parsed.
            guard Int(footerLen) <= ParquetParserBounds.maxFooterLength else {
                out.valid = true
                return out
            }

            try fh.seek(toOffset: UInt64(footerOffset))
            let footer = try fh.read(upToCount: Int(footerLen)) ?? Data()
            guard footer.count == Int(footerLen) else { return out }

            var parsed = parse(footer: footer)
            parsed.fileSize = out.fileSize
            parsed.footerLength = out.footerLength
            parsed.valid = true
            return parsed
        } catch {
            return out
        }
    }

    // Malformed footers yield an empty summary (no rows, no columns); `valid` is left to read(at:).
    public static func parse(footer: Data) -> Summary {
        do {
            var parser = CompactParser(data: footer)
            return try parseFileMetadata(parser: &parser)
        } catch {
            return Summary()
        }
    }

    // Hive-style partitions (`key=value` directory names) in a directory path, outermost first.
    // Values are percent-decoded, as writers such as Arrow encode them.
    public static func partitions(inDirectoryPath path: String) -> [(key: String, value: String)] {
        var out: [(key: String, value: String)] = []
        for segment in path.split(separator: "/") {
            guard let eq = segment.firstIndex(of: "=") else {
                continue
            }
            let key = String(segment[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = String(segment[segment.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = raw.removingPercentEncoding ?? raw
            guard !key.isEmpty, !value.isEmpty else {
                continue
            }
            out.append((key, value))
            if out.count >= ParquetParserBounds.maxPartitionSegments {
                break
            }
        }
        return out
    }

    private struct SchemaElement {
        let name: String
        let type: Int32?
        let convertedType: Int32?
        let logicalType: String?
        let numChildren: Int
    }

    private enum CompactType: UInt8 {
        case stop = 0x00
        case booleanTrue = 0x01
        case booleanFalse = 0x02
        case byte = 0x03
        case i16 = 0x04
        case i32 = 0x05
        case i64 = 0x06
        case double = 0x07
        case binary = 0x08
        case list = 0x09
        case set = 0x0a
        case map = 0x0b
        case `struct` = 0x0c
    }

    private enum ParserError: Error {
        case outOfBounds
        case invalidData
    }

    private struct CompactParser {
        // Valid footers nest only a handful of levels deep.
        static let maxDepth = ParquetParserBounds.maxDepth

        private let bytes: [UInt8]
        private(set) var index: Int = 0

        // Total skip work is capped at a small multiple of the input size.
        private let maxSkips: Int
        private var skips = 0

        init(data: Data) {
            self.bytes = [UInt8](data)
            self.maxSkips = ParquetParserBounds.maxSkips(forInputBytes: self.bytes.count)
        }

        var remaining: Int { bytes.count - index }

        // Every encoded element occupies at least one byte, so a declared count can never
        // legitimately exceed the bytes left to parse.
        func boundedCount(_ declared: Int) -> Int {
            ParquetParserBounds.boundedCount(declared: declared, remaining: remaining)
        }

        mutating func readByte() throws -> UInt8 {
            guard index < bytes.count else { throw ParserError.outOfBounds }
            let b = bytes[index]
            index += 1
            return b
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= bytes.count - index else { throw ParserError.outOfBounds }
            index += count
        }

        mutating func readVarint() throws -> UInt64 {
            var shift: UInt64 = 0
            var result: UInt64 = 0
            while true {
                let b = try readByte()
                result |= UInt64(b & 0x7f) << shift
                if (b & 0x80) == 0 {
                    return result
                }
                shift += 7
                if shift > 63 {
                    throw ParserError.invalidData
                }
            }
        }

        mutating func readZigZag() throws -> Int64 {
            let v = try readVarint()
            let decoded = Int64(bitPattern: (v >> 1) ^ (~(v & 1) &+ 1))
            return decoded
        }

        mutating func readFieldHeader(lastFieldID: inout Int16) throws -> (fieldID: Int16, type: UInt8)? {
            let header = try readByte()
            if header == CompactType.stop.rawValue {
                return nil
            }

            let type = header & 0x0f
            let delta = Int16(header >> 4)
            let fieldID: Int16
            if delta == 0 {
                let decoded = try readZigZag()
                guard decoded >= Int64(Int16.min), decoded <= Int64(Int16.max) else {
                    throw ParserError.invalidData
                }
                fieldID = Int16(decoded)
            } else {
                let (sum, overflow) = lastFieldID.addingReportingOverflow(delta)
                guard !overflow else { throw ParserError.invalidData }
                fieldID = sum
            }
            lastFieldID = fieldID
            return (fieldID, type)
        }

        mutating func readBinaryData() throws -> Data {
            let length = try readVarint()
            guard length <= UInt64(Int.max) else { throw ParserError.invalidData }
            let len = Int(length)
            guard len <= bytes.count - index else { throw ParserError.outOfBounds }
            let d = Data(bytes[index..<(index + len)])
            index += len
            return d
        }

        mutating func readListHeader() throws -> (elementType: UInt8, size: Int) {
            let header = try readByte()
            let elementType = header & 0x0f
            var size = Int(header >> 4)
            if size == 15 {
                let v = try readVarint()
                guard v <= UInt64(Int.max) else { throw ParserError.invalidData }
                size = Int(v)
            }
            return (elementType, size)
        }

        mutating func skipValue(type: UInt8, depth: Int = 0) throws {
            guard depth < CompactParser.maxDepth else { throw ParserError.invalidData }
            skips += 1
            guard skips <= maxSkips else { throw ParserError.invalidData }
            switch type {
            case CompactType.booleanTrue.rawValue, CompactType.booleanFalse.rawValue:
                return
            case CompactType.byte.rawValue:
                _ = try readByte()
            case CompactType.i16.rawValue, CompactType.i32.rawValue, CompactType.i64.rawValue:
                _ = try readVarint()
            case CompactType.double.rawValue:
                try skip(8)
            case CompactType.binary.rawValue:
                _ = try readBinaryData()
            case CompactType.list.rawValue, CompactType.set.rawValue:
                let (elementType, size) = try readListHeader()
                for _ in 0..<boundedCount(size) {
                    try skipValue(type: elementType, depth: depth + 1)
                }
            case CompactType.map.rawValue:
                let size = try readVarint()
                if size == 0 {
                    return
                }
                let kv = try readByte()
                let keyType = kv >> 4
                let valueType = kv & 0x0f
                guard size <= UInt64(Int.max) else { throw ParserError.invalidData }
                for _ in 0..<boundedCount(Int(size)) {
                    try skipValue(type: keyType, depth: depth + 1)
                    try skipValue(type: valueType, depth: depth + 1)
                }
            case CompactType.struct.rawValue:
                var lastFieldID: Int16 = 0
                while let (_, nestedType) = try readFieldHeader(lastFieldID: &lastFieldID) {
                    try skipValue(type: nestedType, depth: depth + 1)
                }
            default:
                throw ParserError.invalidData
            }
        }

        mutating func readInt64ForType(_ type: UInt8) throws -> Int64 {
            switch type {
            case CompactType.booleanTrue.rawValue:
                return 1
            case CompactType.booleanFalse.rawValue:
                return 0
            case CompactType.byte.rawValue:
                return Int64(Int8(bitPattern: try readByte()))
            case CompactType.i16.rawValue, CompactType.i32.rawValue, CompactType.i64.rawValue:
                return try readZigZag()
            default:
                throw ParserError.invalidData
            }
        }

        mutating func readBoolForType(_ type: UInt8) throws -> Bool {
            switch type {
            case CompactType.booleanTrue.rawValue:
                return true
            case CompactType.booleanFalse.rawValue:
                return false
            default:
                return (try readInt64ForType(type)) != 0
            }
        }
    }

    // FileMetaData: 2 schema, 3 num_rows, 4 row_groups, 5 key_value_metadata, 6 created_by.
    private static func parseFileMetadata(parser: inout CompactParser) throws -> Summary {
        var lastFieldID: Int16 = 0
        var out = Summary()
        var fileRowCount: Int64 = 0
        var rowGroupSum: Int64 = 0
        var haveFileRowCount = false

        while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 2:
                out.columns = leafColumns(from: try parseSchemaList(parser: &parser, fieldType: fieldType))
            case 3:
                fileRowCount = try parser.readInt64ForType(fieldType)
                if fileRowCount < 0 { fileRowCount = 0 }
                haveFileRowCount = true
            case 4:
                // Writers put the schema first; chunk details need it to map chunks to columns.
                rowGroupSum = try parseRowGroups(parser: &parser, fieldType: fieldType, into: &out)
            case 5:
                out.keyValueMetadata = try parseKeyValueList(parser: &parser, fieldType: fieldType)
            case 6 where fieldType == CompactType.binary.rawValue:
                out.createdBy = String(decoding: try parser.readBinaryData().prefix(ParquetParserBounds.maxMetadataValueBytes), as: UTF8.self)
            default:
                try parser.skipValue(type: fieldType)
            }
        }

        out.rowCount = haveFileRowCount ? fileRowCount : max(0, rowGroupSum)
        return out
    }

    private static func parseKeyValueList(parser: inout CompactParser, fieldType: UInt8) throws -> [KeyValue] {
        guard fieldType == CompactType.list.rawValue else {
            try parser.skipValue(type: fieldType)
            return []
        }
        let (elementType, declaredSize) = try parser.readListHeader()
        var out: [KeyValue] = []
        for _ in 0..<parser.boundedCount(declaredSize) {
            guard elementType == CompactType.struct.rawValue, out.count < ParquetParserBounds.maxMetadataEntries else {
                try parser.skipValue(type: elementType)
                continue
            }
            var lastFieldID: Int16 = 0
            var key: String?
            var value: String?
            var valueLength = 0
            while let (fieldID, nestedType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
                switch (fieldID, nestedType) {
                case (1, CompactType.binary.rawValue):
                    key = String(decoding: try parser.readBinaryData().prefix(ParquetParserBounds.maxMetadataValueBytes), as: UTF8.self)
                case (2, CompactType.binary.rawValue):
                    let data = try parser.readBinaryData()
                    valueLength = data.count
                    value = String(decoding: data.prefix(ParquetParserBounds.maxMetadataValueBytes), as: UTF8.self)
                default:
                    try parser.skipValue(type: nestedType)
                }
            }
            if let key {
                out.append(KeyValue(key: key, value: value, valueLength: valueLength))
            }
        }
        return out
    }

    private static func parseSchemaList(parser: inout CompactParser, fieldType: UInt8) throws -> [SchemaElement] {
        guard fieldType == CompactType.list.rawValue else {
            try parser.skipValue(type: fieldType)
            return []
        }

        let (elementType, declaredSize) = try parser.readListHeader()
        let size = parser.boundedCount(declaredSize)
        guard elementType == CompactType.struct.rawValue else {
            for _ in 0..<size {
                try parser.skipValue(type: elementType)
            }
            return []
        }

        var out: [SchemaElement] = []
        out.reserveCapacity(min(size, 4096))
        for _ in 0..<size {
            out.append(try parseSchemaElement(parser: &parser))
        }
        return out
    }

    private static func parseSchemaElement(parser: inout CompactParser) throws -> SchemaElement {
        var lastFieldID: Int16 = 0
        var name = ""
        var type: Int32?
        var convertedType: Int32?
        var logicalType: String?
        var numChildren = 0

        while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 1:
                let v = try parser.readInt64ForType(fieldType)
                if v >= Int64(Int32.min), v <= Int64(Int32.max) {
                    type = Int32(v)
                }
            case 6:
                let v = try parser.readInt64ForType(fieldType)
                if v >= Int64(Int32.min), v <= Int64(Int32.max) {
                    convertedType = Int32(v)
                }
            case 10:
                logicalType = try parseLogicalType(parser: &parser, fieldType: fieldType)
            case 4:
                guard fieldType == CompactType.binary.rawValue else {
                    try parser.skipValue(type: fieldType)
                    continue
                }
                let data = try parser.readBinaryData()
                if let s = String(data: data, encoding: .utf8) {
                    name = s
                }
            case 5:
                let v = try parser.readInt64ForType(fieldType)
                if v > 0 {
                    numChildren = Int(min(v, Int64(Int.max)))
                } else {
                    numChildren = 0
                }
            default:
                try parser.skipValue(type: fieldType)
            }
        }

        return SchemaElement(
            name: name,
            type: type,
            convertedType: convertedType,
            logicalType: logicalType,
            numChildren: numChildren
        )
    }

    private static func parseLogicalType(parser: inout CompactParser, fieldType: UInt8) throws -> String? {
        guard fieldType == CompactType.struct.rawValue else {
            try parser.skipValue(type: fieldType)
            return nil
        }

        var lastFieldID: Int16 = 0
        var label: String?

        while let (fieldID, nestedType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 1:
                label = "STRING"
                try parser.skipValue(type: nestedType)
            case 2:
                label = "MAP"
                try parser.skipValue(type: nestedType)
            case 3:
                label = "LIST"
                try parser.skipValue(type: nestedType)
            case 4:
                label = "ENUM"
                try parser.skipValue(type: nestedType)
            case 5:
                let d = try parseDecimalLogicalType(parser: &parser, fieldType: nestedType)
                label = d ?? "DECIMAL"
            case 6:
                label = "DATE"
                try parser.skipValue(type: nestedType)
            case 7:
                let t = try parseTimeLikeLogicalType(parser: &parser, fieldType: nestedType, name: "TIME")
                label = t ?? "TIME"
            case 8:
                let t = try parseTimeLikeLogicalType(parser: &parser, fieldType: nestedType, name: "TIMESTAMP")
                label = t ?? "TIMESTAMP"
            case 10:
                let i = try parseIntLogicalType(parser: &parser, fieldType: nestedType)
                label = i ?? "INT"
            case 11:
                label = "UNKNOWN"
                try parser.skipValue(type: nestedType)
            case 12:
                label = "JSON"
                try parser.skipValue(type: nestedType)
            case 13:
                label = "BSON"
                try parser.skipValue(type: nestedType)
            case 14:
                label = "UUID"
                try parser.skipValue(type: nestedType)
            default:
                try parser.skipValue(type: nestedType)
            }
        }

        return label
    }

    private static func parseDecimalLogicalType(parser: inout CompactParser, fieldType: UInt8) throws -> String? {
        guard fieldType == CompactType.struct.rawValue else {
            try parser.skipValue(type: fieldType)
            return nil
        }

        var lastFieldID: Int16 = 0
        var scale: Int64?
        var precision: Int64?

        while let (fieldID, nestedType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 1:
                scale = try parser.readInt64ForType(nestedType)
            case 2:
                precision = try parser.readInt64ForType(nestedType)
            default:
                try parser.skipValue(type: nestedType)
            }
        }

        if let p = precision, let s = scale {
            return "DECIMAL(\(p),\(s))"
        }
        return "DECIMAL"
    }

    private static func parseIntLogicalType(parser: inout CompactParser, fieldType: UInt8) throws -> String? {
        guard fieldType == CompactType.struct.rawValue else {
            try parser.skipValue(type: fieldType)
            return nil
        }

        var lastFieldID: Int16 = 0
        var bitWidth: Int64?
        var isSigned: Bool?

        while let (fieldID, nestedType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 1:
                bitWidth = try parser.readInt64ForType(nestedType)
            case 2:
                isSigned = try parser.readBoolForType(nestedType)
            default:
                try parser.skipValue(type: nestedType)
            }
        }

        guard let bw = bitWidth else { return "INT" }
        if let signed = isSigned {
            return signed ? "INT\(bw)" : "UINT\(bw)"
        }
        return "INT\(bw)"
    }

    private static func parseTimeLikeLogicalType(parser: inout CompactParser, fieldType: UInt8, name: String) throws -> String? {
        guard fieldType == CompactType.struct.rawValue else {
            try parser.skipValue(type: fieldType)
            return nil
        }

        var lastFieldID: Int16 = 0
        var unit = "UNKNOWN"
        var adjusted = false

        while let (fieldID, nestedType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 1:
                adjusted = try parser.readBoolForType(nestedType)
            case 2:
                unit = try parseTimeUnit(parser: &parser, fieldType: nestedType)
            default:
                try parser.skipValue(type: nestedType)
            }
        }

        return "\(name)_\(unit)\(adjusted ? "_UTC" : "")"
    }

    private static func parseTimeUnit(parser: inout CompactParser, fieldType: UInt8) throws -> String {
        guard fieldType == CompactType.struct.rawValue else {
            try parser.skipValue(type: fieldType)
            return "UNKNOWN"
        }

        var lastFieldID: Int16 = 0
        var unit = "UNKNOWN"

        while let (fieldID, nestedType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 1:
                unit = "MILLIS"
                try parser.skipValue(type: nestedType)
            case 2:
                unit = "MICROS"
                try parser.skipValue(type: nestedType)
            case 3:
                unit = "NANOS"
                try parser.skipValue(type: nestedType)
            default:
                try parser.skipValue(type: nestedType)
            }
        }

        return unit
    }

    private static func parseRowGroups(parser: inout CompactParser, fieldType: UInt8, into out: inout Summary) throws -> Int64 {
        guard fieldType == CompactType.list.rawValue else {
            try parser.skipValue(type: fieldType)
            return 0
        }

        let (elementType, declaredSize) = try parser.readListHeader()
        let size = parser.boundedCount(declaredSize)
        guard elementType == CompactType.struct.rawValue else {
            for _ in 0..<size {
                try parser.skipValue(type: elementType)
            }
            return 0
        }

        var total: Int64 = 0
        for _ in 0..<size {
            let group = try parseRowGroup(parser: &parser, columns: &out.columns)
            total = ParquetParserBounds.saturatingAdd(total, group.rows)
            out.rowGroupCount += 1
            if out.rowGroups.count < ParquetParserBounds.maxListedRowGroups {
                out.rowGroups.append(group)
            }
        }
        return max(0, total)
    }

    // RowGroup: 1 columns, 2 total_byte_size, 3 num_rows, 6 total_compressed_size (optional).
    private static func parseRowGroup(parser: inout CompactParser, columns: inout [Column]) throws -> RowGroup {
        var lastFieldID: Int16 = 0
        var group = RowGroup()
        var chunkCompressed: Int64 = 0
        var haveCompressed = false

        while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 1 where fieldType == CompactType.list.rawValue:
                let (elementType, declaredSize) = try parser.readListHeader()
                for index in 0..<parser.boundedCount(declaredSize) {
                    guard elementType == CompactType.struct.rawValue else {
                        try parser.skipValue(type: elementType)
                        continue
                    }
                    // Chunks follow the schema's leaf-column order.
                    let chunk = try parseColumnChunk(parser: &parser)
                    chunkCompressed = ParquetParserBounds.saturatingAdd(chunkCompressed, chunk.compressed)
                    if index < columns.count {
                        apply(chunk, to: &columns[index])
                    }
                }
            case 2:
                group.totalByteSize = max(0, try parser.readInt64ForType(fieldType))
            case 3:
                group.rows = max(0, try parser.readInt64ForType(fieldType))
            case 6:
                group.compressedSize = max(0, try parser.readInt64ForType(fieldType))
                haveCompressed = true
            default:
                try parser.skipValue(type: fieldType)
            }
        }

        if !haveCompressed { group.compressedSize = chunkCompressed }
        return group
    }

    private struct ColumnChunkInfo {
        var codec: Int64?
        var compressed: Int64 = 0
        var uncompressed: Int64 = 0
        // Raw statistics; only values up to 8 bytes are kept (enough for dates and timestamps).
        var minValue: Data?
        var maxValue: Data?
        var legacyMin: Data?
        var legacyMax: Data?
    }

    // ColumnChunk: 3 meta_data. ColumnMetaData: 4 codec, 6 total_uncompressed_size,
    // 7 total_compressed_size, 12 statistics.
    private static func parseColumnChunk(parser: inout CompactParser) throws -> ColumnChunkInfo {
        var info = ColumnChunkInfo()
        var lastFieldID: Int16 = 0
        while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            guard fieldID == 3, fieldType == CompactType.struct.rawValue else {
                try parser.skipValue(type: fieldType)
                continue
            }
            var metaFieldID: Int16 = 0
            while let (metaID, metaType) = try parser.readFieldHeader(lastFieldID: &metaFieldID) {
                switch metaID {
                case 4:
                    info.codec = try parser.readInt64ForType(metaType)
                case 6:
                    info.uncompressed = max(0, try parser.readInt64ForType(metaType))
                case 7:
                    info.compressed = max(0, try parser.readInt64ForType(metaType))
                case 12 where metaType == CompactType.struct.rawValue:
                    try parseStatistics(parser: &parser, into: &info)
                default:
                    try parser.skipValue(type: metaType)
                }
            }
        }
        return info
    }

    // Statistics: 1 max / 2 min (legacy), 5 max_value / 6 min_value.
    private static func parseStatistics(parser: inout CompactParser, into info: inout ColumnChunkInfo) throws {
        var lastFieldID: Int16 = 0
        while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            guard [1, 2, 5, 6].contains(fieldID), fieldType == CompactType.binary.rawValue else {
                try parser.skipValue(type: fieldType)
                continue
            }
            let data = try parser.readBinaryData()
            guard data.count <= 8 else { continue }
            switch fieldID {
            case 1: info.legacyMax = data
            case 2: info.legacyMin = data
            case 5: info.maxValue = data
            default: info.minValue = data
            }
        }
    }

    private static func apply(_ chunk: ColumnChunkInfo, to column: inout Column) {
        if let codec = chunk.codec {
            let name = codecName(codec)
            if !column.codecs.contains(name) { column.codecs.append(name) }
        }
        column.compressedSize = ParquetParserBounds.saturatingAdd(column.compressedSize, chunk.compressed)
        column.uncompressedSize = ParquetParserBounds.saturatingAdd(column.uncompressedSize, chunk.uncompressed)

        // Legacy min/max sort signed integers correctly, which is all dates and timestamps need.
        if let lo = date(fromStatistic: chunk.minValue ?? chunk.legacyMin, column: column) {
            column.minDate = column.minDate.map { min($0, lo) } ?? lo
        }
        if let hi = date(fromStatistic: chunk.maxValue ?? chunk.legacyMax, column: column) {
            column.maxDate = column.maxDate.map { max($0, hi) } ?? hi
        }
    }

    // date32 is INT32 days, timestamps are INT64 in the column's unit; both little-endian.
    // ponytail: timestamps without isAdjustedToUTC are read as UTC too.
    private static func date(fromStatistic data: Data?, column: Column) -> Date? {
        guard let data else { return nil }
        let bytes = [UInt8](data)
        func littleEndian(_ count: Int) -> Int64? {
            guard bytes.count == count else { return nil }
            var value: UInt64 = 0
            for (i, b) in bytes.enumerated() { value |= UInt64(b) << (8 * UInt64(i)) }
            return count == 4 ? Int64(Int32(truncatingIfNeeded: value)) : Int64(bitPattern: value)
        }

        let seconds: Double
        switch (column.physicalType, column.logicalType) {
        case ("INT32", "date32[day]"):
            guard let days = littleEndian(4) else { return nil }
            seconds = Double(days) * 86_400
        case ("INT64", "timestamp[ms]"):
            guard let v = littleEndian(8) else { return nil }
            seconds = Double(v) / 1_000
        case ("INT64", "timestamp[us]"):
            guard let v = littleEndian(8) else { return nil }
            seconds = Double(v) / 1_000_000
        case ("INT64", "timestamp[ns]"):
            guard let v = littleEndian(8) else { return nil }
            seconds = Double(v) / 1_000_000_000
        default:
            return nil
        }
        // Years 1...9999; anything else is a corrupt or sentinel value.
        guard seconds >= -62_135_596_800, seconds <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func codecName(_ codec: Int64) -> String {
        switch codec {
        case 0: return "UNCOMPRESSED"
        case 1: return "SNAPPY"
        case 2: return "GZIP"
        case 3: return "LZO"
        case 4: return "BROTLI"
        case 5: return "LZ4"
        case 6: return "ZSTD"
        case 7: return "LZ4_RAW"
        default: return "CODEC_\(codec)"
        }
    }

    private static func leafColumns(from schema: [SchemaElement]) -> [Column] {
        guard !schema.isEmpty else { return [] }

        var result: [Column] = []
        var index = 0

        func walk(path: [String], depth: Int) {
            guard index < schema.count, depth < CompactParser.maxDepth else { return }
            let node = schema[index]
            index += 1

            let hasName = !node.name.isEmpty
            let nextPath = hasName ? (path + [node.name]) : path

            if node.numChildren > 0 {
                // A node cannot have more children than there are elements left to consume.
                let children = min(node.numChildren, schema.count - index)
                for _ in 0..<children {
                    walk(path: nextPath, depth: depth + 1)
                }
            } else if hasName {
                result.append(Column(
                    name: nextPath.joined(separator: "."),
                    logicalType: parquetLogicalTypeLabel(
                        physical: node.type,
                        converted: node.convertedType,
                        logical: node.logicalType
                    ),
                    physicalType: parquetPhysicalTypeLabel(physical: node.type)
                ))
            }
        }

        // Schema root is the first element.
        let root = schema[0]
        index = 1
        if root.numChildren > 0 {
            for _ in 0..<min(root.numChildren, schema.count - index) {
                walk(path: [], depth: 0)
            }
        } else {
            while index < schema.count {
                walk(path: [], depth: 0)
            }
        }

        return result
    }

    private static func convertedTypeName(_ t: Int32?) -> String? {
        guard let t else { return nil }
        switch t {
        case 0: return "UTF8"
        case 1: return "MAP"
        case 2: return "MAP_KEY_VALUE"
        case 3: return "LIST"
        case 5: return "ENUM"
        case 6: return "DECIMAL"
        case 7: return "DATE"
        case 8: return "TIME_MILLIS"
        case 9: return "TIME_MICROS"
        case 10: return "TIMESTAMP_MILLIS"
        case 11: return "TIMESTAMP_MICROS"
        case 12: return "UINT_8"
        case 13: return "UINT_16"
        case 14: return "UINT_32"
        case 15: return "UINT_64"
        case 16: return "INT_8"
        case 17: return "INT_16"
        case 18: return "INT_32"
        case 19: return "INT_64"
        case 20: return "JSON"
        case 21: return "BSON"
        case 22: return "INTERVAL"
        default: return nil
        }
    }

    private static func parquetLogicalTypeLabel(physical: Int32?, converted: Int32?, logical: String?) -> String {
        if let logical {
            if logical == "STRING" || logical == "UUID" || logical == "JSON" || logical == "BSON" {
                return "string"
            }
            if logical == "DATE" {
                return "date32[day]"
            }
            if logical.hasPrefix("TIMESTAMP_MILLIS") {
                return "timestamp[ms]"
            }
            if logical.hasPrefix("TIMESTAMP_MICROS") {
                return "timestamp[us]"
            }
            if logical.hasPrefix("TIMESTAMP_NANOS") {
                return "timestamp[ns]"
            }
            if logical.hasPrefix("TIME_MILLIS") {
                return "time32[ms]"
            }
            if logical.hasPrefix("TIME_MICROS") {
                return "time64[us]"
            }
            if logical.hasPrefix("TIME_NANOS") {
                return "time64[ns]"
            }
            if logical.hasPrefix("INT") || logical.hasPrefix("UINT") || logical.hasPrefix("DECIMAL") {
                return logical.lowercased()
            }
        }

        if let converted = convertedTypeName(converted) {
            switch converted {
            case "UTF8": return "string"
            case "DATE": return "date32[day]"
            case "TIMESTAMP_MILLIS": return "timestamp[ms]"
            case "TIMESTAMP_MICROS": return "timestamp[us]"
            case "TIME_MILLIS": return "time32[ms]"
            case "TIME_MICROS": return "time64[us]"
            case "INT_8": return "int8"
            case "INT_16": return "int16"
            case "INT_32": return "int32"
            case "INT_64": return "int64"
            case "UINT_8": return "uint8"
            case "UINT_16": return "uint16"
            case "UINT_32": return "uint32"
            case "UINT_64": return "uint64"
            case "DECIMAL": return "decimal"
            case "JSON", "BSON": return "string"
            default: break
            }
        }

        switch physical {
        case 0: return "bool"
        case 1: return "int32"
        case 2: return "int64"
        case 3: return "int96"
        case 4: return "float"
        case 5: return "double"
        case 6: return "binary"
        case 7: return "binary"
        default: return "unknown"
        }
    }

    private static func parquetPhysicalTypeLabel(physical: Int32?) -> String {
        switch physical {
        case 0: return "BOOLEAN"
        case 1: return "INT32"
        case 2: return "INT64"
        case 3: return "INT96"
        case 4: return "FLOAT"
        case 5: return "DOUBLE"
        case 6: return "BYTE_ARRAY"
        case 7: return "FIXED_LEN_BYTE_ARRAY"
        default: return "UNKNOWN"
        }
    }
}
