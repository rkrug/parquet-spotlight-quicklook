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
        // Files the rows come from (datasets; 1 for a single file).
        public var sourceFiles = 0
        // Per column: cells hold the value as JSON (lists, structs, maps) instead of text.
        public var nestedColumns: [Bool] = []
        // Per column: why the preview could not read it (its cells are unreadablePlaceholder).
        public var columnNotes: [String?] = []
    }

    public static let nestedPlaceholder = "‹nested›"
    // Cells of a column that could not be read (see notes); distinct from null.
    public static let unreadablePlaceholder = "‹not read›"

    // pageByteLimit: data pages that decompress to more are read from their start only (tests
    // lower it to exercise that path).
    public static func read(at url: URL, maxRows: Int, maxColumns: Int, pageByteLimit: Int = ParquetParserBounds.maxPreviewPageBytes) -> Table {
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
        table.nestedColumns = shown.map { field in
            let leaf = summary.columns[field.leaves[0]]
            return field.leaves.count > 1 || leaf.path.count > 1 || leaf.maxRepetitionLevel > 0
        }
        guard !shown.isEmpty else { return table }

        let budget = ParquetParserBounds.maxPreviewCells / shown.count
        let rowCount = Int(min(Int64(min(wanted, budget)), max(0, summary.rowCount)))
        guard rowCount > 0 else { return table }

        guard let file = try? FileHandle(forReadingFrom: url) else { return table }
        defer { try? file.close() }
        let fileSize = summary.fileSize

        var cells: [[String?]] = []
        table.columnNotes = Array(repeating: nil, count: shown.count)
        var problems: [(message: String, columns: [String])] = []
        func note(_ message: String, _ column: String) {
            if let i = table.columns.firstIndex(of: column) { table.columnNotes[i] = message }
            if let i = problems.firstIndex(where: { $0.message == message }) {
                problems[i].columns.append(column)
            } else {
                problems.append((message, [column]))
            }
        }
        for (position, field) in shown.enumerated() {
            let leaf = summary.columns[field.leaves[0]]
            if table.nestedColumns[position] {
                let leaves = field.leaves.map { summary.columns[$0] }
                guard leaves.count <= ParquetParserBounds.maxPreviewColumns, leaves.allSatisfy({ !$0.pathNodes.isEmpty }) else {
                    cells.append(Array(repeating: nestedPlaceholder, count: rowCount))
                    continue
                }
                do {
                    cells.append(try readNestedField(
                        leaves: leaves, indices: field.leaves, groups: summary.previewRowGroups,
                        rows: rowCount, file: file, fileSize: fileSize, pageLimit: pageByteLimit
                    ))
                } catch let error as ReadError {
                    note(error.message, field.name)
                    cells.append(Array(repeating: unreadablePlaceholder, count: rowCount))
                } catch {
                    note("could not be read", field.name)
                    cells.append(Array(repeating: unreadablePlaceholder, count: rowCount))
                }
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
                        file: file, fileSize: fileSize, pageLimit: pageByteLimit
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
        table.sourceFiles = 1
        table.notes = problems.map { "\($0.message): \($0.columns.joined(separator: ", "))" }
        return table
    }

    // First rows of a dataset folder: its .parquet files in path order, until maxRows rows.
    // Columns are matched by name across files (missing ones are null); hive partition keys
    // from the folder names become columns too. Notes are merged across files.
    public static func readDataset(at folder: URL, maxRows: Int, maxColumns: Int, maxFiles: Int, recursive: Bool) -> Table {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        var files: [URL] = []
        if let enumerator = FileManager().enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: options) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "parquet" {
                // Same rule as ParquetDataset.summarize: not one dataset, no rows.
                guard ParquetDataset.isDatasetFile(url, under: folder) else { return Table() }
                files.append(url)
                if files.count >= max(1, maxFiles) { break }
            }
        }
        files.sort { $0.path < $1.path }

        let wanted = max(0, min(maxRows, ParquetParserBounds.maxPreviewRows))
        var table = Table()
        var notes: [String] = []
        for file in files where table.rows.count < wanted {
            let part = read(at: file, maxRows: wanted - table.rows.count, maxColumns: maxColumns)
            guard !part.columns.isEmpty else { continue }
            let partitions = ParquetDataset.partitions(of: file, under: folder).filter { !part.columns.contains($0.key) }
            let names = part.columns + partitions.map(\.key)
            for (k, name) in names.enumerated() where !table.columns.contains(name) && table.columns.count < ParquetParserBounds.maxPreviewColumns {
                table.columns.append(name)
                table.nestedColumns.append(k < part.nestedColumns.count && part.nestedColumns[k])
                table.columnNotes.append(k < part.columnNotes.count ? part.columnNotes[k] : nil)
                for r in table.rows.indices { table.rows[r].append(nil) }
            }
            let slots = names.map { table.columns.firstIndex(of: $0) }
            for row in part.rows {
                var merged = [String?](repeating: nil, count: table.columns.count)
                for (value, slot) in zip(row + partitions.map { Optional($0.value) }, slots) {
                    if let slot { merged[slot] = value }
                }
                table.rows.append(merged)
            }
            table.totalRows = ParquetParserBounds.saturatingAdd(table.totalRows, part.totalRows)
            table.hiddenColumns = max(table.hiddenColumns, part.hiddenColumns)
            table.sourceFiles += 1
            notes += part.notes.filter { !notes.contains($0) }
        }
        // Rows from later files may have added columns: keep within the cell budget.
        let budget = ParquetParserBounds.maxPreviewCells / max(1, table.columns.count)
        if table.rows.count > budget { table.rows.removeLast(table.rows.count - budget) }
        table.notes = notes
        return table
    }

    static let tooLargeMessage = "the column's pages are too large for the preview"

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

    // Calls `onDataPage` for each data page of the chunk, with the dictionary read so far, until
    // it returns false.
    private static func scanChunk(
        _ chunk: ParquetFooter.ChunkLocation, column: ParquetFooter.Column, file: FileHandle, fileSize: UInt64,
        onDataPage: (PageHeader, ArraySlice<UInt8>, [Raw]) throws -> Bool
    ) throws {
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

        var dictionary: [Raw] = []
        var cursor = 0
        while cursor < bytes.count {
            let header = try parsePageHeader(bytes, at: cursor)
            let bodyStart = cursor + header.headerLength
            guard header.compressedSize >= 0, bodyStart + header.compressedSize <= bytes.count else {
                throw ReadError(message: "page extends past the readable part of the column chunk")
            }
            guard header.uncompressedSize >= 0 else { throw ReadError(message: "invalid page size") }
            // Data pages over the limit are decoded from their start only (dataPageParts); a
            // dictionary has to be complete.
            guard header.type != 2 || header.uncompressedSize <= ParquetParserBounds.maxPreviewPageBytes else {
                throw ReadError(message: tooLargeMessage)
            }
            let body = bytes[bodyStart..<(bodyStart + header.compressedSize)]
            cursor = bodyStart + header.compressedSize

            switch header.type {
            case 2: // DICTIONARY_PAGE
                let page = try decompress(body, codec: chunk.codec, size: header.uncompressedSize)
                let count = min(header.numValues, ParquetParserBounds.maxPreviewDictionaryValues)
                dictionary = try decodePlain(page[...], count: count, column: column)
            case 0, 3: // DATA_PAGE, DATA_PAGE_V2
                if try !onDataPage(header, body, dictionary) { return }
            default: // INDEX_PAGE and unknown page types carry no values
                continue
            }
        }
    }

    // Flat column: the first `rows` values, formatted (nil for nulls).
    private static func readChunk(
        _ chunk: ParquetFooter.ChunkLocation, column: ParquetFooter.Column, rows: Int,
        file: FileHandle, fileSize: UInt64, pageLimit: Int
    ) throws -> [String?] {
        var out: [String?] = []
        guard rows > 0 else { return out }
        try scanChunk(chunk, column: column, file: file, fileSize: fileSize) { header, body, dictionary in
            let need = min(rows - out.count, header.numValues)
            let page = try dataPageParts(body, header: header, codec: chunk.codec, column: column, count: need, limit: pageLimit)
            let present = page.definitions.map { $0.filter { $0 == column.maxDefinitionLevel }.count } ?? need
            let decoded = try page.decoding {
                try decodeValues(page.values, encoding: page.encoding, count: present, column: column, dictionary: dictionary)
            }
            guard decoded.count == present else { throw ReadError(message: "page has fewer values than expected") }
            var next = decoded.makeIterator()
            for i in 0..<need {
                if let levels = page.definitions, levels[i] != column.maxDefinitionLevel {
                    out.append(nil)
                } else if let value = next.next() {
                    out.append(format(value, column: column))
                }
            }
            return out.count < rows
        }
        return out
    }

    private struct Triple {
        let rep: Int
        let def: Int
        let value: Raw?
    }

    // Leaf of a nested field: its (repetition, definition, value) triples for the first `rows`
    // rows, one array per row (a row starts at repetition level 0).
    private static func readRows(
        _ chunk: ParquetFooter.ChunkLocation, column: ParquetFooter.Column, rows: Int,
        file: FileHandle, fileSize: UInt64, pageLimit: Int
    ) throws -> [[Triple]] {
        var out: [[Triple]] = []
        guard rows > 0 else { return out }
        try scanChunk(chunk, column: column, file: file, fileSize: fileSize) { header, body, dictionary in
            // Levels are decoded only up to the start of the first row not needed (cutoff), so a
            // page with millions of values costs no more than the rows shown.
            let page = try dataPageParts(body, header: header, codec: chunk.codec, column: column, count: header.numValues,
                                         limit: pageLimit, rowsWanted: rows - out.count)
            let cutoff = page.repetitions?.count ?? min(header.numValues, rows - out.count)
            let definitions = page.definitions ?? Array(repeating: column.maxDefinitionLevel, count: cutoff)
            let repetitions = page.repetitions ?? Array(repeating: 0, count: cutoff)
            let present = definitions[..<cutoff].filter { $0 == column.maxDefinitionLevel }.count
            let decoded = try page.decoding {
                try decodeValues(page.values, encoding: page.encoding, count: present, column: column, dictionary: dictionary)
            }
            guard decoded.count == present else { throw ReadError(message: "page has fewer values than expected") }
            var next = decoded.makeIterator()
            for i in 0..<cutoff {
                let value = definitions[i] == column.maxDefinitionLevel ? next.next() : nil
                if repetitions[i] == 0 {
                    out.append([])
                } else if out.isEmpty {
                    throw ReadError(message: "column chunk starts inside a row")
                }
                // ponytail: values past the per-row cap are dropped, so a very long list ends early.
                if out[out.count - 1].count < ParquetParserBounds.maxPreviewNestedValues {
                    out[out.count - 1].append(Triple(rep: repetitions[i], def: definitions[i], value: value))
                }
            }
            return cutoff == header.numValues
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

    private struct PageParts {
        // Levels of the first `count` values; nil when the column has none of that kind.
        let repetitions: [Int]?
        let definitions: [Int]?
        let values: ArraySlice<UInt8>
        let encoding: Int64
        // Only the start of the page was decompressed.
        var truncated = false

        // On a cut page, running out of data means the rows are beyond the decompressed start.
        func decoding<T>(_ body: () throws -> T) throws -> T {
            do {
                return try body()
            } catch where truncated {
                throw ReadError(message: ParquetRowReader.tooLargeMessage)
            }
        }
    }

    // Splits a data page into repetition levels, definition levels and value bytes. Levels are
    // decoded for the first `count` values only.
    private static func dataPageParts(
        _ body: ArraySlice<UInt8>, header: PageHeader, codec: Int64, column: ParquetFooter.Column, count: Int, limit: Int,
        rowsWanted: Int? = nil
    ) throws -> PageParts {
        let repWidth = bitWidth(column.maxRepetitionLevel)
        let defWidth = bitWidth(column.maxDefinitionLevel)
        // Repetition levels up to the start of row rowsWanted + 1 (all `count` without a limit);
        // definition levels then only for those values.
        func repetitionLevels(_ bytes: ArraySlice<UInt8>) throws -> [Int] {
            guard let wanted = rowsWanted else { return try hybrid(bytes, bitWidth: repWidth, count: count) }
            var starts = 0
            var decoded = 0
            var overflow = false
            let levels = try hybrid(bytes, bitWidth: repWidth, count: count) { level in
                decoded += 1
                if decoded > ParquetParserBounds.maxPreviewPageValues {
                    overflow = true
                    return true
                }
                if level == 0 { starts += 1 }
                return starts > wanted
            }
            if overflow { throw ReadError(message: tooLargeMessage) }
            return levels
        }
        if header.type == 3 {
            let levelBytes = header.repetitionLevelsLength + header.definitionLevelsLength
            guard levelBytes <= body.count else { throw ReadError(message: "invalid level lengths") }
            let repStart = body.startIndex
            let defStart = repStart + header.repetitionLevelsLength
            let repetitions = column.maxRepetitionLevel > 0 ? try repetitionLevels(body[repStart..<defStart]) : nil
            let definitions = column.maxDefinitionLevel > 0
                ? try hybrid(body[defStart..<(defStart + header.definitionLevelsLength)], bitWidth: defWidth, count: repetitions?.count ?? count)
                : nil
            let rest = body[(body.startIndex + levelBytes)...]
            let valuesSize = header.uncompressedSize - levelBytes
            if header.valuesCompressed && valuesSize > limit && header.encoding == 9 { throw ReadError(message: tooLargeMessage) }
            let values = header.valuesCompressed
                ? try decompress(rest, codec: codec, size: valuesSize, limit: limit)[...]
                : rest
            return PageParts(repetitions: repetitions, definitions: definitions, values: values, encoding: header.encoding,
                             truncated: header.valuesCompressed && valuesSize > limit)
        }

        // DATA_PAGE (v1): everything compressed; each level section has a 4-byte length prefix.
        let truncated = header.uncompressedSize > limit
        // BYTE_STREAM_SPLIT finds its streams from the section length: a cut page would decode wrong.
        if truncated && header.encoding == 9 { throw ReadError(message: tooLargeMessage) }
        let page = try decompress(body, codec: codec, size: header.uncompressedSize, limit: limit)
        var position = 0
        func levels(_ decode: (ArraySlice<UInt8>) throws -> [Int]) throws -> [Int] {
            let length = try littleEndian32(page[...], at: position)
            guard length >= 0, position + 4 + length <= page.count else { throw ReadError(message: "invalid level data") }
            defer { position += 4 + length }
            return try decode(page[(position + 4)..<(position + 4 + length)])
        }
        guard column.maxDefinitionLevel == 0 || header.definitionEncoding == 3 else {
            throw ReadError(message: "unsupported definition level encoding")
        }
        var parts = PageParts(repetitions: nil, definitions: nil, values: [], encoding: header.encoding, truncated: truncated)
        let repetitions = column.maxRepetitionLevel > 0 ? try parts.decoding { try levels(repetitionLevels) } : nil
        let definitionCount = repetitions?.count ?? count
        let definitions = column.maxDefinitionLevel > 0
            ? try parts.decoding { try levels { try hybrid($0, bitWidth: defWidth, count: definitionCount) } }
            : nil
        parts = PageParts(repetitions: repetitions, definitions: definitions, values: page[position...], encoding: header.encoding, truncated: truncated)
        return parts
    }

    private static func bitWidth(_ maxLevel: Int) -> Int {
        maxLevel <= 0 ? 0 : Int.bitWidth - maxLevel.leadingZeroBitCount
    }

    // MARK: - Nested values

    private indirect enum Nested {
        case null
        case value(String)
        // `more`: items left out after maxPreviewNestedItems.
        case list([Nested], more: Int)
        case object([(String, Nested)])
    }

    // One nested top-level field: each row's value as compact JSON with fields in schema order
    // and leaf values as strings; nil when the field is null in that row.
    private static func readNestedField(
        leaves: [ParquetFooter.Column], indices: [Int], groups: [ParquetFooter.PreviewRowGroup],
        rows: Int, file: FileHandle, fileSize: UInt64, pageLimit: Int
    ) throws -> [String?] {
        var perLeaf: [[[Triple]]] = []
        for (leaf, index) in zip(leaves, indices) {
            var leafRows: [[Triple]] = []
            for group in groups where leafRows.count < rows {
                guard index < group.chunks.count else { break }
                let need = min(rows - leafRows.count, Int(clamping: group.rows))
                leafRows += try readRows(group.chunks[index], column: leaf, rows: need, file: file, fileSize: fileSize, pageLimit: pageLimit)
            }
            perLeaf.append(leafRows)
        }

        let tree = TreeNode(leaves[0].pathNodes[0])
        for leaf in leaves { tree.insert(leaf.pathNodes.dropFirst()) }
        let levels = leaves.map(cumulativeLevels)

        return (0..<rows).map { r in
            var merged: Nested?
            for (l, leaf) in leaves.enumerated() where r < perLeaf[l].count && !perLeaf[l][r].isEmpty {
                let value = assemble(perLeaf[l][r][...], column: leaf, at: 0, levels: levels[l])
                merged = merged.map { merge($0, value) } ?? value
            }
            let shaped = shape(merged ?? .null, tree)
            if case .null = shaped { return nil }
            return json(shaped)
        }
    }

    // Definition and repetition level reached at each path node (Dremel).
    private static func cumulativeLevels(_ column: ParquetFooter.Column) -> (def: [Int], rep: [Int]) {
        var def = 0, rep = 0
        var defs: [Int] = [], reps: [Int] = []
        for node in column.pathNodes {
            if node.repetition == 1 || node.repetition == 2 { def += 1 }
            if node.repetition == 2 { rep += 1 }
            defs.append(def)
            reps.append(rep)
        }
        return (defs, reps)
    }

    // One leaf's triples of one row, assembled from path node `i` down: repeated nodes become
    // lists (split where the repetition level returns to theirs), groups become one-field
    // objects (merged across leaves later), and a definition level below a node's makes it
    // null (or an empty list for a repeated node).
    private static func assemble(_ s: ArraySlice<Triple>, column: ParquetFooter.Column, at i: Int, levels: (def: [Int], rep: [Int])) -> Nested {
        let node = column.pathNodes[i]
        guard let first = s.first else { return .null }
        func instance(_ part: ArraySlice<Triple>) -> Nested {
            if node.isLeaf {
                return part.first?.value.map { .value(format($0, column: column)) } ?? .null
            }
            guard i + 1 < column.pathNodes.count else { return .null }
            return .object([(column.pathNodes[i + 1].name, assemble(part, column: column, at: i + 1, levels: levels))])
        }
        guard node.repetition == 2 else {
            return first.def < levels.def[i] ? .null : instance(s)
        }
        if first.def < levels.def[i] { return .list([], more: 0) }
        var items: [Nested] = []
        var more = 0
        var start = s.startIndex
        func flush(_ end: Int) {
            if items.count < ParquetParserBounds.maxPreviewNestedItems {
                items.append(instance(s[start..<end]))
            } else {
                more += 1
            }
        }
        for j in s.indices.dropFirst() where s[j].rep <= levels.rep[i] {
            flush(j)
            start = j
        }
        flush(s.endIndex)
        return .list(items, more: more)
    }

    // Leaves of one field share their ancestors: objects merge by field name, lists item by item.
    private static func merge(_ a: Nested, _ b: Nested) -> Nested {
        switch (a, b) {
        case (.object(var x), .object(let y)):
            for (key, value) in y {
                if let i = x.firstIndex(where: { $0.0 == key }) {
                    x[i].1 = merge(x[i].1, value)
                } else {
                    x.append((key, value))
                }
            }
            return .object(x)
        case let (.list(x, mx), .list(y, my)):
            let items = (0..<max(x.count, y.count)).map { i -> Nested in
                if i < x.count && i < y.count { return merge(x[i], y[i]) }
                return i < x.count ? x[i] : y[i]
            }
            return .list(items, more: max(mx, my))
        case (.null, _):
            return b
        default:
            return a
        }
    }

    // The field's schema as a tree, for shaping assembled values.
    private final class TreeNode {
        let node: ParquetFooter.PathNode
        var children: [TreeNode] = []

        init(_ node: ParquetFooter.PathNode) {
            self.node = node
        }

        func insert(_ path: ArraySlice<ParquetFooter.PathNode>) {
            guard let next = path.first else { return }
            let child = children.first { $0.node.name == next.name } ?? {
                let created = TreeNode(next)
                children.append(created)
                return created
            }()
            child.insert(path.dropFirst())
        }

        func child(named name: String) -> TreeNode? {
            children.first { $0.node.name == name }
        }
    }

    // Applies LIST and MAP annotations: a LIST group becomes the list of its elements, a MAP
    // group an object of key: value; other groups stay structs.
    private static func shape(_ value: Nested, _ tree: TreeNode) -> Nested {
        if tree.node.repetition == 2, case let .list(items, more) = value {
            return .list(items.map { shapeInstance($0, tree) }, more: more)
        }
        return shapeInstance(value, tree)
    }

    private static func shapeInstance(_ value: Nested, _ tree: TreeNode) -> Nested {
        guard case let .object(fields) = value else { return value }
        switch tree.node.annotation {
        case "LIST":
            guard let repeated = tree.children.first, let inner = fields.first?.1 else { return value }
            guard case let .list(items, more) = inner else { return inner }
            // Three-level lists wrap each element in the repeated group; in legacy two-level
            // lists the repeated node is the element itself.
            if !repeated.node.isLeaf, repeated.children.count == 1 {
                let element = repeated.children[0]
                return .list(items.map { item in
                    guard case let .object(wrapped) = item, let inner = wrapped.first?.1 else { return item }
                    return shape(inner, element)
                }, more: more)
            }
            return .list(items.map { shapeInstance($0, repeated) }, more: more)
        case "MAP":
            guard let entries = tree.children.first, entries.children.count == 2,
                  let inner = fields.first?.1, case let .list(items, more) = inner else { return value }
            let keyNode = entries.children[0], valueNode = entries.children[1]
            var pairs: [(String, Nested)] = items.map { item in
                guard case let .object(entry) = item else { return ("null", .null) }
                let key = entry.first { $0.0 == keyNode.node.name }?.1
                let text: String
                if case let .value(k)? = key { text = k } else { text = "null" }
                let mapped = entry.first { $0.0 == valueNode.node.name }.map { shape($0.1, valueNode) } ?? .null
                return (text, mapped)
            }
            if more > 0 { pairs.append(("…", .value("\(more) more"))) }
            return .object(pairs)
        default:
            return .object(fields.map { key, child in (key, tree.child(named: key).map { shape(child, $0) } ?? child) })
        }
    }

    private static func json(_ value: Nested) -> String {
        switch value {
        case .null:
            return "null"
        case .value(let text):
            return quote(text)
        case let .list(items, more):
            var parts = items.map(json)
            if more > 0 { parts.append(quote("… \(more) more")) }
            return "[" + parts.joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.map { quote($0.0) + ":" + json($0.1) }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
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
        case 5 where column.physicalType == "INT32" || column.physicalType == "INT64": // DELTA_BINARY_PACKED
            let values = try deltaBinaryPacked(bytes, limit: count).values
            return values.map { column.physicalType == "INT32" ? .int32(Int32(truncatingIfNeeded: $0)) : .int64($0) }
        case 6 where column.physicalType == "BYTE_ARRAY": // DELTA_LENGTH_BYTE_ARRAY
            return try deltaLengthByteArray(bytes, limit: count).values.map { .bytes(Array($0)) }
        case 7 where column.physicalType == "BYTE_ARRAY" || column.physicalType == "FIXED_LEN_BYTE_ARRAY": // DELTA_BYTE_ARRAY
            return try deltaByteArray(bytes, limit: count).map { .bytes($0) }
        case 9: // BYTE_STREAM_SPLIT
            return try byteStreamSplit(bytes, count: count, column: column)
        default:
            throw ReadError(message: "\(encodingName(encoding)) encoding is not supported by the preview yet")
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
        default: return "encoding \(encoding)"
        }
    }

    // DELTA_BINARY_PACKED: header <block size> <miniblocks per block> <total count> <first value>,
    // then blocks of <min delta> <bit width per miniblock> <bit-packed (delta - min delta)>.
    // Decodes the first `limit` values (all with limit == nil, as length sections need) and
    // returns where the encoded data ends (after the last miniblock holding a value).
    static func deltaBinaryPacked(_ bytes: ArraySlice<UInt8>, limit: Int?) throws -> (values: [Int64], end: Int) {
        var p = bytes.startIndex
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard p < bytes.endIndex, shift <= 63 else { throw ReadError(message: "invalid DELTA_BINARY_PACKED data") }
                let b = bytes[p]
                p += 1
                result |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }
        func zigzag() throws -> Int64 {
            let v = try varint()
            return Int64(bitPattern: (v >> 1) ^ (~(v & 1) &+ 1))
        }
        let blockSize = try varint(), miniblocks = try varint(), total = try varint()
        var last = try zigzag()
        guard miniblocks > 0, blockSize > 0, blockSize <= 1 << 20, blockSize % 128 == 0,
              blockSize % miniblocks == 0, (blockSize / miniblocks) % 32 == 0 else {
            throw ReadError(message: "invalid DELTA_BINARY_PACKED header")
        }
        let perMiniblock = Int(blockSize / miniblocks)
        // `total` comes from the data: decode at most what is asked for, or the page cap.
        guard limit != nil || total <= UInt64(ParquetParserBounds.maxPreviewPageValues) else { throw ReadError(message: tooLargeMessage) }
        let wanted = Int(min(total, UInt64(limit ?? Int(total))))
        var values: [Int64] = []
        values.reserveCapacity(min(wanted, ParquetParserBounds.maxPreviewPageValues))
        if wanted > 0 { values.append(last) }
        var remaining = Int(min(total, UInt64(Int.max))) - 1
        while values.count < wanted || (limit == nil && remaining > 0) {
            let minDelta = try zigzag()
            guard Int(miniblocks) <= bytes.endIndex - p else { throw ReadError(message: "invalid DELTA_BINARY_PACKED data") }
            let widths = Array(bytes[p..<(p + Int(miniblocks))])
            p += Int(miniblocks)
            for width in widths where remaining > 0 {
                guard width <= 64 else { throw ReadError(message: "invalid DELTA_BINARY_PACKED bit width") }
                let size = perMiniblock * Int(width) / 8
                guard size <= bytes.endIndex - p else { throw ReadError(message: "DELTA_BINARY_PACKED data ends early") }
                for i in 0..<min(perMiniblock, remaining) {
                    var delta: UInt64 = 0
                    for b in 0..<Int(width) {
                        let bit = i * Int(width) + b
                        if bytes[p + bit / 8] >> (bit % 8) & 1 == 1 { delta |= 1 << UInt64(b) }
                    }
                    last = last &+ minDelta &+ Int64(bitPattern: delta)
                    if values.count < wanted { values.append(last) }
                }
                remaining -= min(perMiniblock, remaining)
                p += size
            }
            if remaining == 0 { break }
        }
        return (values, p)
    }

    // DELTA_LENGTH_BYTE_ARRAY: all lengths (DELTA_BINARY_PACKED), then the values back to back.
    static func deltaLengthByteArray(_ bytes: ArraySlice<UInt8>, limit: Int) throws -> (values: [ArraySlice<UInt8>], end: Int) {
        let (lengths, start) = try deltaBinaryPacked(bytes, limit: nil)
        var values: [ArraySlice<UInt8>] = []
        var p = start
        for length in lengths {
            guard length >= 0, length <= Int64(bytes.endIndex - p) else { throw ReadError(message: "invalid DELTA_LENGTH_BYTE_ARRAY data") }
            if values.count < limit { values.append(bytes[p..<(p + Int(length))]) }
            p += Int(length)
        }
        return (values, p)
    }

    // DELTA_BYTE_ARRAY: prefix lengths (DELTA_BINARY_PACKED) and suffixes (DELTA_LENGTH_BYTE_ARRAY);
    // each value is the previous value's first <prefix length> bytes plus its suffix.
    static func deltaByteArray(_ bytes: ArraySlice<UInt8>, limit: Int) throws -> [[UInt8]] {
        let (prefixes, suffixStart) = try deltaBinaryPacked(bytes, limit: nil)
        let suffixes = try deltaLengthByteArray(bytes[suffixStart...], limit: limit).values
        var values: [[UInt8]] = []
        var previous: [UInt8] = []
        for (prefix, suffix) in zip(prefixes, suffixes) {
            guard prefix >= 0, prefix <= Int64(previous.count) else { throw ReadError(message: "invalid DELTA_BYTE_ARRAY prefix") }
            previous = Array(previous.prefix(Int(prefix))) + suffix
            guard previous.count <= ParquetParserBounds.maxPreviewPageBytes else { throw ReadError(message: tooLargeMessage) }
            values.append(previous)
        }
        return values
    }

    // BYTE_STREAM_SPLIT: byte k of every value is stored in stream k; streams are the section
    // split into `width` equal parts, so the whole page is needed (a cut page cannot be split).
    private static func byteStreamSplit(_ bytes: ArraySlice<UInt8>, count: Int, column: ParquetFooter.Column) throws -> [Raw] {
        let width: Int
        switch column.physicalType {
        case "FLOAT", "INT32": width = 4
        case "DOUBLE", "INT64": width = 8
        case "FIXED_LEN_BYTE_ARRAY": width = column.typeLength
        default: throw ReadError(message: "BYTE_STREAM_SPLIT encoding is not supported by the preview for this type")
        }
        guard width > 0, bytes.count % width == 0, count <= bytes.count / width else {
            throw ReadError(message: "invalid BYTE_STREAM_SPLIT data")
        }
        let stride = bytes.count / width
        return (0..<count).map { i in
            let value = (0..<width).map { k in bytes[bytes.startIndex + k * stride + i] }
            let little = value.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            switch column.physicalType {
            case "FLOAT": return .float(Float(bitPattern: UInt32(truncatingIfNeeded: little)))
            case "DOUBLE": return .double(Double(bitPattern: little))
            case "INT32": return .int32(Int32(truncatingIfNeeded: little))
            case "INT64": return .int64(Int64(bitPattern: little))
            default: return .bytes(value)
            }
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
    // `stop` (optional) sees each value before it is added; returning true ends decoding there.
    static func hybrid(_ bytes: ArraySlice<UInt8>, bitWidth: Int, count: Int, stop: ((Int) -> Bool)? = nil) throws -> [Int] {
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
                let run = min(Int(clamping: header >> 1), count - out.count)
                if let stop {
                    for _ in 0..<run {
                        if stop(value) { return out }
                        out.append(value)
                    }
                } else {
                    out += Array(repeating: value, count: run)
                }
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
                    if let stop, stop(value) { return out }
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

    // The whole page when it is at most `limit` bytes; otherwise only its first `limit` bytes,
    // which hold the levels and the first values (enough for the first rows).
    private static func decompress(_ input: ArraySlice<UInt8>, codec: Int64, size: Int, limit: Int = ParquetParserBounds.maxPreviewPageBytes) throws -> [UInt8] {
        guard size >= 0 else { throw ReadError(message: "invalid page size") }
        guard size > limit else { return try decompressAll(input, codec: codec, size: size) }
        switch codec {
        case 0:
            guard input.count == size else { throw ReadError(message: "page size mismatch") }
            return Array(input.prefix(limit))
        case 1:
            return try snappy(input, size: size, limit: limit)
        case 2:
            return try applePrefix(try gzipDeflateBody(input), algorithm: COMPRESSION_ZLIB, limit: limit)
        case 4:
            return try applePrefix(input, algorithm: COMPRESSION_BROTLI, limit: limit)
        case 5:
            return try hadoopLZ4(input, size: size, limit: limit)
        case 6:
            return try zstd(input, limit: limit, exact: false)
        case 7:
            return try lz4Block(input, limit: limit)
        default:
            throw ReadError(message: unsupportedCodec(codec))
        }
    }

    private static func decompressAll(_ input: ArraySlice<UInt8>, codec: Int64, size: Int) throws -> [UInt8] {
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
            return try hadoopLZ4(input, size: size, limit: size)
        case 6:
            return try zstd(input, limit: size, exact: true)
        case 7:
            return try apple(input, algorithm: COMPRESSION_LZ4_RAW, size: size)
        default:
            throw ReadError(message: unsupportedCodec(codec))
        }
    }

    private static func unsupportedCodec(_ codec: Int64) -> String {
        let name: String
        switch codec {
        case 3: name = "LZO"
        default: name = "codec \(codec)"
        }
        return "\(name) compression is not supported by the preview yet"
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

    // Vendored zstd decoder (third_party/zstd, parquet_zstd.h): `limit` bytes, which must all be
    // produced (the whole page when `exact`, else its start).
    private static func zstd(_ input: ArraySlice<UInt8>, limit: Int, exact: Bool) throws -> [UInt8] {
        guard limit > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: limit)
        let written = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                parquet_zstd_decompress(src.baseAddress, src.count, dst.baseAddress, limit)
            }
        }
        guard written == limit else {
            throw ReadError(message: exact || written < 0 ? "could not decompress a page" : tooLargeMessage)
        }
        return out
    }

    // Streaming decode into a `limit`-byte buffer: stops once it is full.
    private static func applePrefix(_ input: ArraySlice<UInt8>, algorithm: compression_algorithm, limit: Int) throws -> [UInt8] {
        guard limit > 0, !input.isEmpty else { return [] }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw ReadError(message: "could not decompress a page")
        }
        defer { compression_stream_destroy(stream) }
        var out = [UInt8](repeating: 0, count: limit)
        let status = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                stream.pointee.src_ptr = src.baseAddress!
                stream.pointee.src_size = src.count
                stream.pointee.dst_ptr = dst.baseAddress!
                stream.pointee.dst_size = limit
                return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            }
        }
        let written = limit - stream.pointee.dst_size
        // Not every algorithm can stop partway; then the page is simply too large to preview.
        guard status != COMPRESSION_STATUS_ERROR, written == limit else { throw ReadError(message: tooLargeMessage) }
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
    // Decodes blocks until `limit` bytes (all of them when limit == size).
    private static func hadoopLZ4(_ input: ArraySlice<UInt8>, size: Int, limit: Int) throws -> [UInt8] {
        func be(_ p: Int) -> Int { Int(input[p]) << 24 | Int(input[p + 1]) << 16 | Int(input[p + 2]) << 8 | Int(input[p + 3]) }
        func raw() throws -> [UInt8] {
            limit < size
                ? try lz4Block(input, limit: limit)
                : try apple(input, algorithm: COMPRESSION_LZ4_RAW, size: size)
        }
        var out: [UInt8] = []
        var p = input.startIndex
        while p + 8 <= input.endIndex, out.count < limit {
            let blockSize = be(p), compressed = be(p + 4)
            guard blockSize > 0, blockSize <= size - out.count, compressed > 0, compressed <= input.endIndex - p - 8 else {
                return try raw()
            }
            let block = input[(p + 8)..<(p + 8 + compressed)]
            let need = limit - out.count
            out += blockSize <= need
                ? try apple(block, algorithm: COMPRESSION_LZ4_RAW, size: blockSize)
                : try lz4Block(block, limit: need)
            p += 8 + compressed
        }
        if limit < size { return out.count == limit ? out : try raw() }
        guard out.count == size, p == input.endIndex else { return try raw() }
        return out
    }

    // LZ4 block format, for the start of a large page (Apple's streaming API cannot stop inside
    // an LZ4 block): sequences of literals and back-references, decoded until `limit` bytes.
    static func lz4Block(_ input: ArraySlice<UInt8>, limit: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limit)
        var p = input.startIndex
        let end = input.endIndex
        func length(_ base: Int) throws -> Int {
            var n = base
            guard base == 15 else { return n }
            while true {
                guard p < end else { throw ReadError(message: "invalid LZ4 page") }
                let b = Int(input[p])
                p += 1
                n += b
                guard n <= ParquetParserBounds.maxPreviewPageBytes * 64 else { throw ReadError(message: "invalid LZ4 page") }
                if b != 255 { return n }
            }
        }
        while p < end, out.count < limit {
            let token = Int(input[p])
            p += 1
            let literals = try length(token >> 4)
            guard literals <= end - p else { throw ReadError(message: "invalid LZ4 page") }
            out += input[p..<(p + min(literals, limit - out.count))]
            p += literals
            if p >= end || out.count >= limit { break } // the last sequence has literals only
            guard end - p >= 2 else { throw ReadError(message: "invalid LZ4 page") }
            let offset = Int(input[p]) | Int(input[p + 1]) << 8
            p += 2
            let match = try length(token & 15) + 4
            guard offset > 0, offset <= out.count else { throw ReadError(message: "invalid LZ4 page") }
            let from = out.count - offset
            for k in 0..<min(match, limit - out.count) { out.append(out[from + k]) }
        }
        guard out.count >= limit else { throw ReadError(message: "invalid LZ4 page") }
        return out
    }

    // Snappy block format: varint length, then literals and back-references. Stops after
    // `limit` bytes (the whole block by default).
    static func snappy(_ input: ArraySlice<UInt8>, size: Int, limit: Int? = nil) throws -> [UInt8] {
        let target = min(size, limit ?? size)
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
        out.reserveCapacity(target)
        func byte(_ i: Int) throws -> Int {
            guard i < end else { throw ReadError(message: "invalid Snappy page") }
            return Int(input[i])
        }
        while p < end, out.count < target {
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
        guard out.count >= target else { throw ReadError(message: "Snappy page size mismatch") }
        return out.count == target ? out : Array(out.prefix(target))
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
