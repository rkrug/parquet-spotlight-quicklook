import Compression
import Foundation

// Reads the first rows of a Parquet file for the Quick Look Data tab (#25). Step 1: flat
// top-level columns are decoded; nested columns (lists, structs, maps) show a placeholder.
// Pages come from untrusted files: every size is checked against ParquetParserBounds before it
// is used, and a problem in one column ends only that column (with a note), not the table.
public enum ParquetRowReader {
    public struct Table: Equatable {
        // Top-level fields, in schema order.
        public var columns: [String] = []
        // rows[r][c]; nil is a null.
        public var rows: [[String?]] = []
        // Problems, one line per message with the columns it affects, e.g.
        // "codec ZSTD not supported yet: a, b".
        public var notes: [String] = []
        // Rows in the file (rows.count is at most the requested number).
        public var totalRows: Int64 = 0
        // Columns left out because of maxColumns.
        public var hiddenColumns = 0
    }

    public static let nestedPlaceholder = "‹nested›"
    // Cells of a column that could not be read (see notes); distinct from null.
    public static let unreadablePlaceholder = "‹not read›"

    public static func read(at url: URL, maxRows: Int, maxColumns: Int) -> Table {
        var table = Table()
        let wanted = max(0, min(maxRows, ParquetParserBounds.maxPreviewRows))
        let summary = ParquetFooter.read(at: url, keepChunksForRows: wanted)
        guard summary.valid else { return table }
        table.totalRows = summary.rowCount

        // Top-level fields and the leaf columns under each.
        var fields: [(name: String, leaves: [Int])] = []
        for (index, column) in summary.columns.enumerated() {
            let name = column.path.first ?? column.name
            if let last = fields.last, last.name == name {
                fields[fields.count - 1].leaves.append(index)
            } else {
                fields.append((name, [index]))
            }
        }
        let shown = Array(fields.prefix(max(1, min(maxColumns, ParquetParserBounds.maxPreviewColumns))))
        table.hiddenColumns = fields.count - shown.count
        table.columns = shown.map(\.name)
        guard !shown.isEmpty else { return table }

        let budget = ParquetParserBounds.maxPreviewCells / shown.count
        let rowCount = Int(min(Int64(min(wanted, budget)), max(0, summary.rowCount)))
        guard rowCount > 0 else { return table }

        guard let file = try? FileHandle(forReadingFrom: url) else { return table }
        defer { try? file.close() }
        let fileSize = summary.fileSize

        var cells: [[String?]] = []
        var problems: [(message: String, columns: [String])] = []
        func note(_ message: String, _ column: String) {
            if let i = problems.firstIndex(where: { $0.message == message }) {
                problems[i].columns.append(column)
            } else {
                problems.append((message, [column]))
            }
        }
        for field in shown {
            let leaf = summary.columns[field.leaves[0]]
            guard field.leaves.count == 1, leaf.path.count == 1, leaf.maxRepetitionLevel == 0 else {
                cells.append(Array(repeating: nestedPlaceholder, count: rowCount))
                continue
            }
            var values: [String?] = []
            var failed = false
            do {
                for group in summary.previewRowGroups where values.count < rowCount {
                    guard field.leaves[0] < group.chunks.count else { break }
                    let need = min(rowCount - values.count, Int(clamping: group.rows))
                    values += try readChunk(
                        group.chunks[field.leaves[0]], column: leaf, rows: need,
                        file: file, fileSize: fileSize
                    )
                }
            } catch let error as ReadError {
                note(error.message, field.name)
                failed = true
            } catch {
                note("could not be read", field.name)
                failed = true
            }
            values += Array(repeating: failed ? unreadablePlaceholder : nil, count: max(0, rowCount - values.count))
            cells.append(Array(values.prefix(rowCount)))
        }

        table.rows = (0..<rowCount).map { r in cells.map { $0[r] } }
        table.notes = problems.map { "\($0.message): \($0.columns.joined(separator: ", "))" }
        return table
    }

    struct ReadError: Error {
        let message: String
    }

    // MARK: - Column chunks and pages

    private enum Raw {
        case bool(Bool)
        case int32(Int32)
        case int64(Int64)
        case int96([UInt8])
        case float(Float)
        case double(Double)
        case bytes([UInt8])
    }

    private static func readChunk(
        _ chunk: ParquetFooter.ChunkLocation, column: ParquetFooter.Column, rows: Int,
        file: FileHandle, fileSize: UInt64
    ) throws -> [String?] {
        var start = chunk.dataPageOffset
        if let dict = chunk.dictionaryPageOffset, dict > 0, dict < start {
            start = dict
        }
        guard start >= 4, chunk.totalCompressedSize > 0, UInt64(start) < fileSize else {
            throw ReadError(message: "invalid column chunk location")
        }
        // Pages that do not fit the read limit are not decoded.
        let length = Int(min(chunk.totalCompressedSize, Int64(fileSize) - start, Int64(ParquetParserBounds.maxPreviewChunkBytes)))
        try file.seek(toOffset: UInt64(start))
        let bytes = [UInt8](try file.read(upToCount: length) ?? Data())

        var out: [String?] = []
        var dictionary: [Raw] = []
        var cursor = 0
        while out.count < rows, cursor < bytes.count {
            let header = try parsePageHeader(bytes, at: cursor)
            let bodyStart = cursor + header.headerLength
            guard header.compressedSize >= 0, bodyStart + header.compressedSize <= bytes.count else {
                throw ReadError(message: "page extends past the readable part of the column chunk")
            }
            guard header.uncompressedSize >= 0, header.uncompressedSize <= ParquetParserBounds.maxPreviewPageBytes else {
                throw ReadError(message: "page larger than \(ParquetParserBounds.maxPreviewPageBytes / (1024 * 1024)) MiB")
            }
            let body = bytes[bodyStart..<(bodyStart + header.compressedSize)]
            cursor = bodyStart + header.compressedSize

            switch header.type {
            case 2: // DICTIONARY_PAGE
                let page = try decompress(body, codec: chunk.codec, size: header.uncompressedSize)
                let count = min(header.numValues, ParquetParserBounds.maxPreviewDictionaryValues)
                dictionary = try decodePlain(page[...], count: count, column: column)
            case 0, 3: // DATA_PAGE, DATA_PAGE_V2
                let need = min(rows - out.count, header.numValues)
                let (levels, values, encoding) = try dataPageParts(body, header: header, codec: chunk.codec, column: column, need: need)
                let present = levels.map { $0.filter { $0 == column.maxDefinitionLevel }.count } ?? need
                let decoded = try decodeValues(values, encoding: encoding, count: present, column: column, dictionary: dictionary)
                guard decoded.count == present else { throw ReadError(message: "page has fewer values than expected") }
                var next = decoded.makeIterator()
                for i in 0..<need {
                    if let levels, levels[i] != column.maxDefinitionLevel {
                        out.append(nil)
                    } else if let value = next.next() {
                        out.append(format(value, column: column))
                    }
                }
            default: // INDEX_PAGE and unknown page types carry no values
                continue
            }
        }
        return out
    }

    private struct PageHeader {
        var type: Int64 = -1
        var uncompressedSize = 0
        var compressedSize = 0
        var headerLength = 0
        var numValues = 0
        var encoding: Int64 = 0
        var definitionEncoding: Int64 = 3
        // DATA_PAGE_V2: level sections stored uncompressed in front of the values.
        var repetitionLevelsLength = 0
        var definitionLevelsLength = 0
        var valuesCompressed = true
    }

    // PageHeader: 1 type, 2 uncompressed_page_size, 3 compressed_page_size, 5 data_page_header,
    // 7 dictionary_page_header, 8 data_page_header_v2.
    private static func parsePageHeader(_ bytes: [UInt8], at offset: Int) throws -> PageHeader {
        let end = min(bytes.count, offset + ParquetParserBounds.maxPreviewPageHeaderBytes)
        var parser = ParquetFooter.CompactParser(data: Data(bytes[offset..<end]))
        var header = PageHeader()
        do {
            var lastFieldID: Int16 = 0
            while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
                switch (fieldID, fieldType) {
                case (1, _):
                    header.type = try parser.readInt64ForType(fieldType)
                case (2, _):
                    header.uncompressedSize = Int(clamping: try parser.readInt64ForType(fieldType))
                case (3, _):
                    header.compressedSize = Int(clamping: try parser.readInt64ForType(fieldType))
                case (5, ParquetFooter.CompactType.struct.rawValue), (7, ParquetFooter.CompactType.struct.rawValue), (8, ParquetFooter.CompactType.struct.rawValue):
                    try parsePageTypeHeader(&parser, field: fieldID, into: &header)
                default:
                    try parser.skipValue(type: fieldType)
                }
            }
        } catch {
            throw ReadError(message: "unreadable page header")
        }
        header.headerLength = parser.index
        return header
    }

    // DataPageHeader: 1 num_values, 2 encoding, 3 definition_level_encoding.
    // DictionaryPageHeader: 1 num_values, 2 encoding.
    // DataPageHeaderV2: 1 num_values, 4 encoding, 5 definition_levels_byte_length,
    // 6 repetition_levels_byte_length, 7 is_compressed.
    private static func parsePageTypeHeader(_ parser: inout ParquetFooter.CompactParser, field: Int16, into header: inout PageHeader) throws {
        var lastFieldID: Int16 = 0
        while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch (field, fieldID) {
            case (_, 1):
                header.numValues = Int(clamping: max(0, try parser.readInt64ForType(fieldType)))
            case (5, 2), (7, 2), (8, 4):
                header.encoding = try parser.readInt64ForType(fieldType)
            case (5, 3):
                header.definitionEncoding = try parser.readInt64ForType(fieldType)
            case (8, 5):
                header.definitionLevelsLength = Int(clamping: max(0, try parser.readInt64ForType(fieldType)))
            case (8, 6):
                header.repetitionLevelsLength = Int(clamping: max(0, try parser.readInt64ForType(fieldType)))
            case (8, 7):
                header.valuesCompressed = try parser.readBoolForType(fieldType)
            default:
                try parser.skipValue(type: fieldType)
            }
        }
    }

    // Definition levels for the first `need` values (nil for REQUIRED columns), the value bytes,
    // and their encoding.
    private static func dataPageParts(
        _ body: ArraySlice<UInt8>, header: PageHeader, codec: Int64, column: ParquetFooter.Column, need: Int
    ) throws -> ([Int]?, ArraySlice<UInt8>, Int64) {
        let width = bitWidth(column.maxDefinitionLevel)
        if header.type == 3 {
            let levelBytes = header.repetitionLevelsLength + header.definitionLevelsLength
            guard levelBytes <= body.count else { throw ReadError(message: "invalid level lengths") }
            let defStart = body.startIndex + header.repetitionLevelsLength
            let levels = column.maxDefinitionLevel > 0
                ? try hybrid(body[defStart..<(defStart + header.definitionLevelsLength)], bitWidth: width, count: need)
                : nil
            let rest = body[(body.startIndex + levelBytes)...]
            let values = header.valuesCompressed
                ? try decompress(rest, codec: codec, size: header.uncompressedSize - levelBytes)[...]
                : rest
            return (levels, values, header.encoding)
        }

        let page = try decompress(body, codec: codec, size: header.uncompressedSize)
        var position = 0
        var levels: [Int]?
        if column.maxDefinitionLevel > 0 {
            guard header.definitionEncoding == 3 else { throw ReadError(message: "unsupported definition level encoding") }
            let length = try littleEndian32(page[...], at: position)
            guard length >= 0, position + 4 + length <= page.count else { throw ReadError(message: "invalid definition levels") }
            levels = try hybrid(page[(position + 4)..<(position + 4 + length)], bitWidth: width, count: need)
            position += 4 + length
        }
        return (levels, page[position...], header.encoding)
    }

    private static func bitWidth(_ maxLevel: Int) -> Int {
        maxLevel <= 0 ? 0 : Int.bitWidth - maxLevel.leadingZeroBitCount
    }

    // MARK: - Encodings

    private static func decodeValues(
        _ bytes: ArraySlice<UInt8>, encoding: Int64, count: Int, column: ParquetFooter.Column, dictionary: [Raw]
    ) throws -> [Raw] {
        switch encoding {
        case 0: // PLAIN
            return try decodePlain(bytes, count: count, column: column)
        case 2, 8: // PLAIN_DICTIONARY, RLE_DICTIONARY
            guard count > 0 else { return [] }
            guard let width = bytes.first, width <= 32 else { throw ReadError(message: "invalid dictionary index width") }
            let indices = try hybrid(bytes.dropFirst(), bitWidth: Int(width), count: count)
            return try indices.map { index in
                guard index >= 0, index < dictionary.count else { throw ReadError(message: "dictionary index out of range") }
                return dictionary[index]
            }
        case 3 where column.physicalType == "BOOLEAN": // RLE
            let length = try littleEndian32(bytes, at: 0)
            guard length >= 0, 4 + length <= bytes.count else { throw ReadError(message: "invalid RLE booleans") }
            let start = bytes.startIndex + 4
            return try hybrid(bytes[start..<(start + length)], bitWidth: 1, count: count).map { .bool($0 != 0) }
        default:
            throw ReadError(message: "encoding \(encodingName(encoding)) not supported yet")
        }
    }

    private static func encodingName(_ encoding: Int64) -> String {
        switch encoding {
        case 3: return "RLE"
        case 4: return "BIT_PACKED"
        case 5: return "DELTA_BINARY_PACKED"
        case 6: return "DELTA_LENGTH_BYTE_ARRAY"
        case 7: return "DELTA_BYTE_ARRAY"
        case 9: return "BYTE_STREAM_SPLIT"
        default: return "\(encoding)"
        }
    }

    private static func decodePlain(_ bytes: ArraySlice<UInt8>, count: Int, column: ParquetFooter.Column) throws -> [Raw] {
        var out: [Raw] = []
        var p = bytes.startIndex
        let end = bytes.endIndex
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, n <= end - p else { throw ReadError(message: "value data ends early") }
            defer { p += n }
            return bytes[p..<(p + n)]
        }
        func le(_ s: ArraySlice<UInt8>) -> UInt64 {
            s.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        // A value takes at least one bit (BOOLEAN) or one byte, so `count` is bounded by the data.
        let bound = column.physicalType == "BOOLEAN" ? bytes.count * 8 : bytes.count
        out.reserveCapacity(min(count, bound))
        guard count <= bound || count == 0 else { throw ReadError(message: "value data ends early") }
        for i in 0..<count {
            switch column.physicalType {
            case "BOOLEAN":
                let byte = bytes.startIndex + i / 8
                guard byte < end else { throw ReadError(message: "value data ends early") }
                out.append(.bool(bytes[byte] >> (i % 8) & 1 == 1))
            case "INT32":
                out.append(.int32(Int32(truncatingIfNeeded: le(try take(4)))))
            case "INT64":
                out.append(.int64(Int64(bitPattern: le(try take(8)))))
            case "INT96":
                out.append(.int96(Array(try take(12))))
            case "FLOAT":
                out.append(.float(Float(bitPattern: UInt32(truncatingIfNeeded: le(try take(4))))))
            case "DOUBLE":
                out.append(.double(Double(bitPattern: le(try take(8)))))
            case "BYTE_ARRAY":
                let length = Int(le(try take(4)))
                out.append(.bytes(Array(try take(length))))
            case "FIXED_LEN_BYTE_ARRAY":
                guard column.typeLength > 0 else { throw ReadError(message: "missing fixed length") }
                out.append(.bytes(Array(try take(column.typeLength))))
            default:
                throw ReadError(message: "unknown physical type")
            }
        }
        return out
    }

    // RLE / bit-packed hybrid (levels, dictionary indices, RLE booleans): the first `count` values.
    static func hybrid(_ bytes: ArraySlice<UInt8>, bitWidth: Int, count: Int) throws -> [Int] {
        guard bitWidth >= 0, bitWidth <= 32 else { throw ReadError(message: "invalid bit width") }
        var out: [Int] = []
        out.reserveCapacity(min(count, ParquetParserBounds.maxPreviewRows))
        var p = bytes.startIndex
        let end = bytes.endIndex
        while out.count < count {
            guard p < end else { throw ReadError(message: "level or index data ends early") }
            var header: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard p < end, shift <= 63 else { throw ReadError(message: "invalid run header") }
                let b = bytes[p]
                p += 1
                header |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { break }
                shift += 7
            }
            if header & 1 == 0 {
                // RLE run: one value, repeated.
                let width = (bitWidth + 7) / 8
                guard width <= end - p else { throw ReadError(message: "level or index data ends early") }
                var value = 0
                for k in 0..<width { value |= Int(bytes[p + k]) << (8 * k) }
                p += width
                let run = Int(clamping: header >> 1)
                out += Array(repeating: value, count: min(run, count - out.count))
            } else {
                // Bit-packed groups of 8 values, least significant bit first.
                let groups = Int(clamping: header >> 1)
                let available = bitWidth == 0 ? groups : min(groups, (end - p) / max(1, bitWidth))
                let remaining = count - out.count
                let values = min(min(available, (remaining + 7) / 8) * 8, remaining)
                for i in 0..<values {
                    var value = 0
                    for b in 0..<bitWidth {
                        let bit = i * bitWidth + b
                        if bytes[p + bit / 8] >> (bit % 8) & 1 == 1 { value |= 1 << b }
                    }
                    out.append(value)
                }
                p += available * bitWidth
                if available < groups && out.count < count { throw ReadError(message: "level or index data ends early") }
            }
        }
        return out
    }

    private static func littleEndian32(_ bytes: ArraySlice<UInt8>, at offset: Int) throws -> Int {
        let p = bytes.startIndex + offset
        guard offset >= 0, 4 <= bytes.endIndex - p else { throw ReadError(message: "data ends early") }
        return Int(bytes[p]) | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]) << 16 | Int(bytes[p + 3]) << 24
    }

    // MARK: - Codecs

    private static func decompress(_ input: ArraySlice<UInt8>, codec: Int64, size: Int) throws -> [UInt8] {
        guard size >= 0, size <= ParquetParserBounds.maxPreviewPageBytes else { throw ReadError(message: "invalid page size") }
        switch codec {
        case 0: // UNCOMPRESSED
            guard input.count == size else { throw ReadError(message: "page size mismatch") }
            return Array(input)
        case 1:
            return try snappy(input, size: size)
        case 2:
            return try apple(try gzipDeflateBody(input), algorithm: COMPRESSION_ZLIB, size: size)
        case 4:
            return try apple(input, algorithm: COMPRESSION_BROTLI, size: size)
        case 5:
            return try hadoopLZ4(input, size: size)
        case 7:
            return try apple(input, algorithm: COMPRESSION_LZ4_RAW, size: size)
        default:
            throw ReadError(message: "codec \(codecName(codec)) not supported yet")
        }
    }

    private static func codecName(_ codec: Int64) -> String {
        switch codec {
        case 3: return "LZO"
        case 6: return "ZSTD"
        default: return "\(codec)"
        }
    }

    // Apple's Compression framework; the output must be exactly `size` bytes.
    private static func apple(_ input: ArraySlice<UInt8>, algorithm: compression_algorithm, size: Int) throws -> [UInt8] {
        guard size > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: size)
        let written = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, size, src.baseAddress!, src.count, nil, algorithm)
            }
        }
        guard written == size else { throw ReadError(message: "could not decompress a page") }
        return out
    }

    // RFC 1952 member: skips the header and returns the raw deflate stream (COMPRESSION_ZLIB
    // decodes raw deflate).
    private static func gzipDeflateBody(_ input: ArraySlice<UInt8>) throws -> ArraySlice<UInt8> {
        let b = input.startIndex
        guard input.count >= 18, input[b] == 0x1f, input[b + 1] == 0x8b, input[b + 2] == 8 else {
            throw ReadError(message: "invalid GZIP page")
        }
        let flags = input[b + 3]
        var p = b + 10
        if flags & 0x04 != 0 { // FEXTRA
            guard p + 2 <= input.endIndex else { throw ReadError(message: "invalid GZIP page") }
            p += 2 + (Int(input[p]) | Int(input[p + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 { // FNAME, FCOMMENT: zero-terminated
            while p < input.endIndex, input[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x02 != 0 { p += 2 } // FHCRC
        guard p < input.endIndex - 8 else { throw ReadError(message: "invalid GZIP page") }
        return input[p..<(input.endIndex - 8)]
    }

    // Hadoop framing used by the legacy LZ4 codec: [uncompressed BE32][compressed BE32][block]...;
    // some writers wrote raw LZ4 blocks under this codec instead.
    private static func hadoopLZ4(_ input: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
        func be(_ p: Int) -> Int { Int(input[p]) << 24 | Int(input[p + 1]) << 16 | Int(input[p + 2]) << 8 | Int(input[p + 3]) }
        var out: [UInt8] = []
        var p = input.startIndex
        while p + 8 <= input.endIndex, out.count < size {
            let blockSize = be(p), compressed = be(p + 4)
            guard blockSize > 0, blockSize <= size - out.count, compressed > 0, compressed <= input.endIndex - p - 8 else {
                return try apple(input, algorithm: COMPRESSION_LZ4_RAW, size: size)
            }
            out += try apple(input[(p + 8)..<(p + 8 + compressed)], algorithm: COMPRESSION_LZ4_RAW, size: blockSize)
            p += 8 + compressed
        }
        guard out.count == size, p == input.endIndex else { return try apple(input, algorithm: COMPRESSION_LZ4_RAW, size: size) }
        return out
    }

    // Snappy block format: varint length, then literals and back-references.
    static func snappy(_ input: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
        var p = input.startIndex
        let end = input.endIndex
        var length = 0
        var shift = 0
        while true {
            guard p < end, shift <= 28 else { throw ReadError(message: "invalid Snappy page") }
            let b = input[p]
            p += 1
            length |= Int(b & 0x7f) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        guard length == size else { throw ReadError(message: "Snappy page size mismatch") }
        var out: [UInt8] = []
        out.reserveCapacity(size)
        func byte(_ i: Int) throws -> Int {
            guard i < end else { throw ReadError(message: "invalid Snappy page") }
            return Int(input[i])
        }
        while p < end {
            let tag = input[p]
            p += 1
            var copyLength = 0
            var offset = 0
            switch tag & 3 {
            case 0:
                var literal = Int(tag >> 2)
                if literal >= 60 {
                    let extra = literal - 59
                    literal = 0
                    for k in 0..<extra { literal |= try byte(p + k) << (8 * k) }
                    p += extra
                }
                literal += 1
                guard literal <= end - p, out.count + literal <= size else { throw ReadError(message: "invalid Snappy page") }
                out += input[p..<(p + literal)]
                p += literal
                continue
            case 1:
                copyLength = Int((tag >> 2) & 7) + 4
                offset = Int(tag >> 5) << 8 | (try byte(p))
                p += 1
            case 2:
                copyLength = Int(tag >> 2) + 1
                offset = try byte(p) | (try byte(p + 1)) << 8
                p += 2
            default:
                copyLength = Int(tag >> 2) + 1
                offset = try byte(p) | (try byte(p + 1)) << 8 | (try byte(p + 2)) << 16 | (try byte(p + 3)) << 24
                p += 4
            }
            guard offset > 0, offset <= out.count, out.count + copyLength <= size else { throw ReadError(message: "invalid Snappy page") }
            let from = out.count - offset
            for k in 0..<copyLength { out.append(out[from + k]) }
        }
        guard out.count == size else { throw ReadError(message: "Snappy page size mismatch") }
        return out
    }

    // MARK: - Formatting

    private static func format(_ raw: Raw, column: ParquetFooter.Column) -> String {
        let type = column.logicalType
        switch raw {
        case .bool(let v):
            return v ? "true" : "false"
        case .float(let v):
            return "\(v)"
        case .double(let v):
            return "\(v)"
        case .int96(let b):
            // Legacy timestamp: nanoseconds of the day, then the Julian day (both little-endian).
            let nanos = b[0..<8].reversed().reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            let julian = b[8..<12].reversed().reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            return timestamp(days: julian - 2_440_588, nanosOfDay: nanos, digits: 9)
        case .int32(let v):
            return formatInteger(Int64(v), unsignedBits: 32, type: type)
        case .int64(let v):
            return formatInteger(v, unsignedBits: 64, type: type)
        case .bytes(let b):
            if type.hasPrefix("decimal") {
                return decimal(bigEndian: b, scale: decimalScale(type))
            }
            if type == "string" && column.physicalType == "FIXED_LEN_BYTE_ARRAY" && b.count == 16 {
                let hex = b.map { String(format: "%02x", $0) }.joined()
                return [8, 4, 4, 4, 12].reduce(into: (parts: [String](), rest: Substring(hex))) {
                    $0.parts.append(String($0.rest.prefix($1)))
                    $0.rest = $0.rest.dropFirst($1)
                }.parts.joined(separator: "-")
            }
            if type == "string" {
                return truncated(String(decoding: b, as: UTF8.self))
            }
            let shown = b.prefix(32).map { String(format: "%02x", $0) }.joined()
            return "0x" + shown + (b.count > 32 ? "… (\(b.count) bytes)" : "")
        }
    }

    private static func formatInteger(_ v: Int64, unsignedBits: Int, type: String) -> String {
        switch type {
        case "date32[day]":
            return civilDate(days: v)
        case "timestamp[ms]":
            return timestamp(units: v, perSecond: 1_000, digits: 3)
        case "timestamp[us]":
            return timestamp(units: v, perSecond: 1_000_000, digits: 6)
        case "timestamp[ns]":
            return timestamp(units: v, perSecond: 1_000_000_000, digits: 9)
        case "time32[ms]":
            return timeOfDay(units: v, perSecond: 1_000, digits: 3)
        case "time64[us]":
            return timeOfDay(units: v, perSecond: 1_000_000, digits: 6)
        case "time64[ns]":
            return timeOfDay(units: v, perSecond: 1_000_000_000, digits: 9)
        default:
            if type.hasPrefix("decimal") {
                let negative = v < 0
                return decimalString(magnitude: String(v.magnitude), negative: negative, scale: decimalScale(type))
            }
            if type.hasPrefix("uint") {
                return unsignedBits == 32 ? String(UInt32(truncatingIfNeeded: v)) : String(UInt64(bitPattern: v))
            }
            return String(v)
        }
    }

    private static func truncated(_ s: String) -> String {
        s.count > ParquetParserBounds.maxPreviewCellCharacters
            ? String(s.prefix(ParquetParserBounds.maxPreviewCellCharacters)) + "…"
            : s
    }

    private static func decimalScale(_ type: String) -> Int {
        // "decimal(p,s)"; plain "decimal" (converted type without scale) has scale 0.
        guard let comma = type.firstIndex(of: ","), let close = type.firstIndex(of: ")") else { return 0 }
        return Int(type[type.index(after: comma)..<close]) ?? 0
    }

    // Big-endian two's complement of any length.
    private static func decimal(bigEndian bytes: [UInt8], scale: Int) -> String {
        guard !bytes.isEmpty else { return "0" }
        let negative = bytes[0] & 0x80 != 0
        var magnitude = bytes
        if negative { // two's complement negation
            magnitude = magnitude.map { ~$0 }
            for i in stride(from: magnitude.count - 1, through: 0, by: -1) {
                magnitude[i] &+= 1
                if magnitude[i] != 0 { break }
            }
        }
        var digits: [Character] = []
        while magnitude.contains(where: { $0 != 0 }) {
            var remainder = 0
            for i in magnitude.indices {
                let value = remainder * 256 + Int(magnitude[i])
                magnitude[i] = UInt8(value / 10)
                remainder = value % 10
            }
            digits.append(Character(String(remainder)))
        }
        return decimalString(magnitude: digits.isEmpty ? "0" : String(digits.reversed()), negative: negative, scale: scale)
    }

    private static func decimalString(magnitude: String, negative: Bool, scale: Int) -> String {
        var text = magnitude
        if scale > 0 {
            if text.count <= scale { text = String(repeating: "0", count: scale - text.count + 1) + text }
            text.insert(".", at: text.index(text.endIndex, offsetBy: -scale))
        }
        return (negative && text.contains(where: { $0 != "0" && $0 != "." }) ? "-" : "") + text
    }

    // Days since 1970-01-01 to yyyy-MM-dd (proleptic Gregorian; Howard Hinnant's civil_from_days).
    static func civilDate(days: Int64) -> String {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04lld-%02lld-%02lld", year, month, day)
    }

    private static func timestamp(units: Int64, perSecond: Int64, digits: Int) -> String {
        let perDay = perSecond * 86_400
        var days = units / perDay
        var rest = units % perDay
        if rest < 0 { rest += perDay; days -= 1 }
        return timestamp(days: days, nanosOfDay: rest * (1_000_000_000 / perSecond), digits: digits)
    }

    private static func timestamp(days: Int64, nanosOfDay: Int64, digits: Int) -> String {
        civilDate(days: days) + " " + timeOfDay(units: nanosOfDay, perSecond: 1_000_000_000, digits: digits, fractionDigits: digits)
    }

    // HH:mm:ss, plus the fraction in the unit's digits when it is not zero.
    private static func timeOfDay(units: Int64, perSecond: Int64, digits: Int, fractionDigits: Int? = nil) -> String {
        let seconds = units / perSecond
        let fraction = units % perSecond
        var text = String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
        if fraction != 0 {
            let width = fractionDigits ?? digits
            let scaled = perSecond == 1_000_000_000 ? fraction / Int64(pow(10.0, Double(9 - width))) : fraction
            text += "." + String(format: "%0\(width)lld", scaled)
        }
        return text
    }
}
