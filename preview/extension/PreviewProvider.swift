import AppKit
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    struct ColumnInfo {
        let name: String
        let type: String
    }

    struct Metadata {
        var valid = false
        var fileSize: UInt64 = 0
        var footerLength: UInt32 = 0
        var rowCount: Int64 = 0
        var columns: [ColumnInfo] = []
    }

    private final class ColumnTreeNode {
        var children: [String: ColumnTreeNode] = [:]
        var order: [String] = []
        var type: String?
        var groupType: String?

        func child(named name: String) -> ColumnTreeNode {
            if let existing = children[name] {
                return existing
            }
            let node = ColumnTreeNode()
            children[name] = node
            order.append(name)
            return node
        }
    }

    private struct DisplayRow {
        let id: Int
        let parentID: Int?
        let name: String
        let type: String
        let indent: Int
        let isGroup: Bool
    }

    private struct SchemaElement {
        let name: String
        let type: Int32?
        let convertedType: Int32?
        let logicalType: String?
        let numChildren: Int
    }

    private struct ParsedFooter {
        let rowCount: Int64
        let columns: [ColumnInfo]
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
        private let bytes: [UInt8]
        private(set) var index: Int = 0

        init(data: Data) {
            self.bytes = [UInt8](data)
        }

        mutating func readByte() throws -> UInt8 {
            guard index < bytes.count else { throw ParserError.outOfBounds }
            let b = bytes[index]
            index += 1
            return b
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, index + count <= bytes.count else { throw ParserError.outOfBounds }
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
                fieldID = lastFieldID + delta
            }
            lastFieldID = fieldID
            return (fieldID, type)
        }

        mutating func readBinaryData() throws -> Data {
            let length = try readVarint()
            guard length <= UInt64(Int.max) else { throw ParserError.invalidData }
            let len = Int(length)
            guard index + len <= bytes.count else { throw ParserError.outOfBounds }
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

        mutating func skipValue(type: UInt8) throws {
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
                for _ in 0..<size {
                    try skipValue(type: elementType)
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
                for _ in 0..<Int(size) {
                    try skipValue(type: keyType)
                    try skipValue(type: valueType)
                }
            case CompactType.struct.rawValue:
                var lastFieldID: Int16 = 0
                while let (_, nestedType) = try readFieldHeader(lastFieldID: &lastFieldID) {
                    try skipValue(type: nestedType)
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

    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let path = request.fileURL.path
        let metadata = readMetadata(at: request.fileURL)
        let html = renderHTML(path: path, metadata: metadata)

        let size = CGSize(width: 1100, height: 720)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: size) { _ in
            return Data(html.utf8)
        }
        reply.title = request.fileURL.lastPathComponent
        completionHandler(reply, nil)
    }

    private func readMetadata(at url: URL) -> Metadata {
        var out = Metadata()

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

            try fh.seek(toOffset: UInt64(footerOffset))
            let footer = try fh.read(upToCount: Int(footerLen)) ?? Data()
            guard footer.count == Int(footerLen) else { return out }

            let parsed = parseFooterMetadata(footer)
            out.rowCount = parsed.rowCount
            out.columns = parsed.columns
            out.valid = true
            return out
        } catch {
            return out
        }
    }

    private func parseFooterMetadata(_ footer: Data) -> ParsedFooter {
        do {
            var parser = CompactParser(data: footer)
            return try parseFileMetadata(parser: &parser)
        } catch {
            return ParsedFooter(rowCount: 0, columns: [])
        }
    }

    private func parseFileMetadata(parser: inout CompactParser) throws -> ParsedFooter {
        var lastFieldID: Int16 = 0
        var schema: [SchemaElement] = []
        var fileRowCount: Int64 = 0
        var rowGroupSum: Int64 = 0
        var haveFileRowCount = false

        while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 2:
                schema = try parseSchemaList(parser: &parser, fieldType: fieldType)
            case 3:
                fileRowCount = try parser.readInt64ForType(fieldType)
                if fileRowCount < 0 { fileRowCount = 0 }
                haveFileRowCount = true
            case 4:
                rowGroupSum = try parseRowGroups(parser: &parser, fieldType: fieldType)
            default:
                try parser.skipValue(type: fieldType)
            }
        }

        let rowCount = haveFileRowCount ? fileRowCount : max(0, rowGroupSum)
        let columns = leafColumns(from: schema)
        return ParsedFooter(rowCount: rowCount, columns: columns)
    }

    private func parseSchemaList(parser: inout CompactParser, fieldType: UInt8) throws -> [SchemaElement] {
        guard fieldType == CompactType.list.rawValue else {
            try parser.skipValue(type: fieldType)
            return []
        }

        let (elementType, size) = try parser.readListHeader()
        guard elementType == CompactType.struct.rawValue else {
            for _ in 0..<size {
                try parser.skipValue(type: elementType)
            }
            return []
        }

        var out: [SchemaElement] = []
        out.reserveCapacity(size)
        for _ in 0..<size {
            out.append(try parseSchemaElement(parser: &parser))
        }
        return out
    }

    private func parseSchemaElement(parser: inout CompactParser) throws -> SchemaElement {
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

    private func parseLogicalType(parser: inout CompactParser, fieldType: UInt8) throws -> String? {
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

    private func parseDecimalLogicalType(parser: inout CompactParser, fieldType: UInt8) throws -> String? {
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

    private func parseIntLogicalType(parser: inout CompactParser, fieldType: UInt8) throws -> String? {
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

    private func parseTimeLikeLogicalType(parser: inout CompactParser, fieldType: UInt8, name: String) throws -> String? {
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

    private func parseTimeUnit(parser: inout CompactParser, fieldType: UInt8) throws -> String {
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

    private func parseRowGroups(parser: inout CompactParser, fieldType: UInt8) throws -> Int64 {
        guard fieldType == CompactType.list.rawValue else {
            try parser.skipValue(type: fieldType)
            return 0
        }

        let (elementType, size) = try parser.readListHeader()
        guard elementType == CompactType.struct.rawValue else {
            for _ in 0..<size {
                try parser.skipValue(type: elementType)
            }
            return 0
        }

        var total: Int64 = 0
        for _ in 0..<size {
            total += try parseRowGroup(parser: &parser)
        }
        return max(0, total)
    }

    private func parseRowGroup(parser: inout CompactParser) throws -> Int64 {
        var lastFieldID: Int16 = 0
        var rows: Int64 = 0

        while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            if fieldID == 3 {
                rows = max(0, try parser.readInt64ForType(fieldType))
            } else {
                try parser.skipValue(type: fieldType)
            }
        }

        return rows
    }

    private func leafColumns(from schema: [SchemaElement]) -> [ColumnInfo] {
        guard !schema.isEmpty else { return [] }

        var result: [ColumnInfo] = []
        var index = 0

        func walk(path: [String]) {
            guard index < schema.count else { return }
            let node = schema[index]
            index += 1

            let hasName = !node.name.isEmpty
            let nextPath = hasName ? (path + [node.name]) : path

            if node.numChildren > 0 {
                for _ in 0..<node.numChildren {
                    walk(path: nextPath)
                }
            } else if hasName {
                result.append(ColumnInfo(
                    name: nextPath.joined(separator: "."),
                    type: parquetTypeLabel(
                        physical: node.type,
                        converted: node.convertedType,
                        logical: node.logicalType
                    )
                ))
            }
        }

        // Schema root is the first element.
        let root = schema[0]
        index = 1
        if root.numChildren > 0 {
            for _ in 0..<root.numChildren {
                walk(path: [])
            }
        } else {
            while index < schema.count {
                walk(path: [])
            }
        }

        return result
    }

    private func convertedTypeName(_ t: Int32?) -> String? {
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

    private func parquetTypeLabel(physical: Int32?, converted: Int32?, logical: String?) -> String {
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

    private func formatBytes(_ value: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.includesUnit = true
        f.includesCount = true
        f.isAdaptive = true
        return f.string(fromByteCount: Int64(bitPattern: value))
    }

    private func formatInt(_ value: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func buildDisplayRows(columns: ArraySlice<ColumnInfo>) -> [DisplayRow] {
        let root = ColumnTreeNode()

        for col in columns {
            let parts = col.name.split(separator: ".").map(String.init)
            if parts.isEmpty { continue }

            var node = root
            var idx = 0
            while idx < parts.count {
                let part = parts[idx]
                if part == "list" || part == "element" {
                    idx += 1
                    continue
                }

                let child = node.child(named: part)
                let hasNext = (idx + 1) < parts.count
                if !hasNext {
                    child.type = col.type
                    node = child
                    idx += 1
                    continue
                }

                if (idx + 2) < parts.count && parts[idx + 1] == "list" && parts[idx + 2] == "element" {
                    child.groupType = "list"
                    if (idx + 3) >= parts.count {
                        child.type = "list<\(col.type)>"
                    }
                    node = child
                    idx += 3
                } else {
                    if child.groupType == nil {
                        child.groupType = "struct"
                    }
                    node = child
                    idx += 1
                }
            }
        }

        var rows: [DisplayRow] = []
        var nextID = 1

        func walk(node: ColumnTreeNode, depth: Int, parentID: Int?) {
            for name in node.order {
                guard let child = node.children[name] else { continue }
                let isLeaf = child.children.isEmpty
                let rowID = nextID
                nextID += 1
                if isLeaf {
                    rows.append(DisplayRow(
                        id: rowID,
                        parentID: parentID,
                        name: name,
                        type: child.type ?? "unknown",
                        indent: depth,
                        isGroup: false
                    ))
                } else {
                    let gtype = child.groupType ?? "struct"
                    rows.append(DisplayRow(
                        id: rowID,
                        parentID: parentID,
                        name: name,
                        type: gtype,
                        indent: depth,
                        isGroup: true
                    ))
                    walk(node: child, depth: depth + 1, parentID: rowID)
                }
            }
        }

        walk(node: root, depth: 0, parentID: nil)
        return rows
    }

    private func esc(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    private func renderHTML(path: String, metadata: Metadata) -> String {
        let showCount = metadata.columns.count
        let displayRows = buildDisplayRows(columns: metadata.columns.prefix(showCount))

        var rows = ""
        if showCount == 0 {
            rows += "<tr><td colspan=\"3\" class=\"muted\">No columns parsed from footer metadata.</td></tr>"
        } else {
            for (idx, r) in displayRows.enumerated() {
                let indentPx = r.indent * 18
                let nameClass = r.isGroup ? "group" : "field"
                let typeText = esc(r.type)
                let hiddenClass = (r.parentID == nil) ? "" : " hidden"
                let parentAttr = (r.parentID == nil) ? "" : " data-parent=\"\(r.parentID!)\""
                let toggle = r.isGroup
                    ? "<button id=\"btn-\(r.id)\" class=\"toggle\" data-expanded=\"false\" onclick=\"toggleNode(\(r.id));return false;\">▸</button>"
                    : "<span class=\"spacer\"></span>"
                rows += "<tr id=\"row-\(r.id)\" class=\"\(hiddenClass)\"\(parentAttr)><td>\(idx + 1)</td><td class=\"\(nameClass)\" style=\"padding-left:\(indentPx + 8)px\">\(toggle)\(esc(r.name))</td><td>\(typeText)</td></tr>"
            }
        }

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\" />
          <style>
            body{font-family:-apple-system,system-ui,sans-serif;margin:18px;color:#1f2937}
            h1{font-size:20px;margin:0 0 10px}
            .muted{color:#6b7280;font-size:12px}
            .meta{display:grid;grid-template-columns:repeat(5,minmax(120px,1fr));gap:10px;margin:14px 0}
            .card{background:#f5f7fa;border:1px solid #dfe5ec;border-radius:8px;padding:10px}
            .label{font-size:11px;color:#6b7280;text-transform:uppercase;letter-spacing:.05em}
            .val{font-size:16px;font-weight:600;margin-top:4px}
            table{width:100%;border-collapse:collapse;font-size:12px}
            th,td{padding:7px 8px;border-bottom:1px solid #e5e7eb;text-align:left;vertical-align:top}
            th{background:#f8fafc;font-weight:600}
            td.group{font-weight:600;color:#374151}
            td.field{color:#1f2937}
            tr.hidden{display:none}
            .toggle{width:16px;height:16px;border:none;border-radius:3px;background:transparent;color:#475569;font-size:13px;line-height:14px;cursor:pointer;margin-right:6px;padding:0;vertical-align:middle}
            .toggle:hover{background:#e5e7eb;color:#111827}
            .spacer{display:inline-block;width:18px;margin-right:6px}
          </style>
          <script>
            function childRows(id){
              return Array.from(document.querySelectorAll('tr[data-parent="' + id + '"]'));
            }
            function collapseRec(id){
              const btn=document.getElementById('btn-'+id);
              if(btn){btn.dataset.expanded='false';btn.textContent='▸';}
              childRows(id).forEach(function(row){
                row.classList.add('hidden');
                const cid=parseInt(row.id.replace('row-',''),10);
                collapseRec(cid);
              });
            }
            function toggleNode(id){
              const btn=document.getElementById('btn-'+id);
              if(!btn){return;}
              const expanded=(btn.dataset.expanded==='true');
              if(expanded){
                collapseRec(id);
                return;
              }
              btn.dataset.expanded='true';
              btn.textContent='▾';
              childRows(id).forEach(function(row){ row.classList.remove('hidden'); });
            }
          </script>
        </head>
        <body>
          <h1>Parquet Preview</h1>
          <div class=\"muted\">\(esc(path))</div>

          <div class=\"meta\">
            <div class=\"card\"><div class=\"label\">Valid</div><div class=\"val\">\(metadata.valid ? "Yes" : "No")</div></div>
            <div class=\"card\"><div class=\"label\">File Size</div><div class=\"val\">\(esc(formatBytes(metadata.fileSize)))</div></div>
            <div class=\"card\"><div class=\"label\">Footer</div><div class=\"val\">\(esc(formatBytes(UInt64(metadata.footerLength))))</div></div>
            <div class=\"card\"><div class=\"label\">Rows</div><div class=\"val\">\(esc(formatInt(metadata.rowCount)))</div></div>
            <div class=\"card\"><div class=\"label\">Columns</div><div class=\"val\">\(esc(formatInt(Int64(metadata.columns.count))))</div></div>
          </div>

          <table>
            <thead><tr><th>#</th><th>Column</th><th>Type</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </body>
        </html>
        """
    }
}
