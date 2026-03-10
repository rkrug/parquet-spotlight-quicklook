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

    private struct SchemaElement {
        let name: String
        let type: Int32?
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
        var numChildren = 0

        while let (fieldID, fieldType) = try parser.readFieldHeader(lastFieldID: &lastFieldID) {
            switch fieldID {
            case 1:
                let v = try parser.readInt64ForType(fieldType)
                if v >= Int64(Int32.min), v <= Int64(Int32.max) {
                    type = Int32(v)
                }
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

        return SchemaElement(name: name, type: type, numChildren: numChildren)
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
                    type: physicalTypeName(node.type)
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

    private func physicalTypeName(_ t: Int32?) -> String {
        guard let t else { return "UNKNOWN" }
        switch t {
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

    private func esc(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    private func renderHTML(path: String, metadata: Metadata) -> String {
        let showCount = min(metadata.columns.count, 120)
        let hidden = max(0, metadata.columns.count - showCount)

        var rows = ""
        if showCount == 0 {
            rows += "<tr><td colspan=\"3\" class=\"muted\">No columns parsed from footer metadata.</td></tr>"
        } else {
            for (idx, c) in metadata.columns.prefix(showCount).enumerated() {
                let n = c.name.count > 56 ? String(c.name.prefix(53)) + "..." : c.name
                rows += "<tr><td>\(idx + 1)</td><td>\(esc(n))</td><td>\(esc(c.type))</td></tr>"
            }
            if hidden > 0 {
                rows += "<tr><td colspan=\"3\" class=\"muted\">+ \(hidden) more columns not shown</td></tr>"
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
          </style>
        </head>
        <body>
          <h1>Parquet Preview</h1>
          <div class=\"muted\">\(esc(path))</div>

          <div class=\"meta\">
            <div class=\"card\"><div class=\"label\">Valid</div><div class=\"val\">\(metadata.valid ? "Yes" : "No")</div></div>
            <div class=\"card\"><div class=\"label\">File Size</div><div class=\"val\">\(metadata.fileSize) B</div></div>
            <div class=\"card\"><div class=\"label\">Footer</div><div class=\"val\">\(metadata.footerLength) B</div></div>
            <div class=\"card\"><div class=\"label\">Rows</div><div class=\"val\">\(metadata.rowCount)</div></div>
            <div class=\"card\"><div class=\"label\">Columns</div><div class=\"val\">\(metadata.columns.count)</div></div>
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
