import AppKit
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let versionSuffix: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { " (v\($0))" } ?? ""

    typealias ColumnInfo = ParquetFooter.Column
    typealias Metadata = ParquetFooter.Summary

    typealias DatasetMetadata = ParquetDataset.Summary

    private struct ScanLimits {
        static let maxPartitionValuesPerKey = 25
    }

    private struct PreviewSettings {
        var expandDepth = 1
        var showAllColumns = true
        var maxColumns = 500
        var showPhysicalType = false
        var hideListElement = true
        var scanAllFiles = false
        var maxScanFiles = 500
        var recursiveScan = true
        var showDataTab = true
        var previewRows = 100
    }

    private struct PreviewSettingsData: Codable {
        let expandDepth: Int
        let showAllColumns: Bool
        let maxColumns: Int
        let showPhysicalType: Bool
        let hideListElement: Bool
        let scanAllFiles: Bool
        let maxScanFiles: Int
        let recursiveScan: Bool
        // Optional: missing in settings written by versions before the Data tab.
        let showDataTab: Bool?
        let previewRows: Int?
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

    private struct ExportField: Codable {
        let name: String
        let type: String
        let children: [ExportField]
    }

    private struct ExportFlatField: Codable {
        let path: String
        let type: String
        let physicalType: String
    }

    private enum SchemaExportFormat: String {
        case arrowJSONV1 = "parquet-quicklook-arrow-schema-v1"
    }

    private struct SchemaExportScheme: Codable {
        let id: String
        let version: Int
        let title: String
        let description: String
    }

    private struct SchemaExportPayload: Codable {
        let format: String
        let sourcePath: String
        let rowCount: Int64
        let columnCount: Int
        let fields: [ExportField]
        let flatFields: [ExportFlatField]
        let pythonSnippet: String
        let rSnippet: String
    }

    private struct SchemaExportEnvelope: Codable {
        let scheme: SchemaExportScheme
        let payload: SchemaExportPayload
    }

    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let path = request.fileURL.path
        let isDirectory = (try? request.fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let settings = loadSettings()
        let html: String

        if isDirectory {
            guard let dataset = readDatasetMetadata(at: request.fileURL, settings: settings) else {
                completionHandler(nil, noPreviewError())
                return
            }
            html = renderDatasetHTML(path: path, dataset: dataset, settings: settings)
        } else {
            let metadata = readMetadata(at: request.fileURL)
            html = renderHTML(path: path, metadata: metadata)
        }

        let size = CGSize(width: 1100, height: 720)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: size) { _ in
            return Data(html.utf8)
        }
        reply.title = request.fileURL.lastPathComponent
        completionHandler(reply, nil)
    }

    private func noPreviewError() -> NSError {
        NSError(domain: "QLPreviewErrorDomain", code: 3, userInfo: nil)
    }

    private func readMetadata(at url: URL) -> Metadata {
        ParquetFooter.read(at: url)
    }

    private func readDatasetMetadata(at folderURL: URL, settings: PreviewSettings) -> DatasetMetadata? {
        ParquetDataset.summarize(
            at: folderURL,
            maxFiles: settings.scanAllFiles ? Int.max : settings.maxScanFiles,
            recursive: settings.recursiveScan,
            maxPartitionValuesPerKey: ScanLimits.maxPartitionValuesPerKey
        )
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

    private func loadSettings() -> PreviewSettings {
        let settingsFile = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ParquetPreview/settings.json")
        if let data = try? Data(contentsOf: settingsFile),
           let decoded = try? JSONDecoder().decode(PreviewSettingsData.self, from: data) {
            return PreviewSettings(
                expandDepth: max(0, min(decoded.expandDepth, 10)),
                showAllColumns: decoded.showAllColumns,
                maxColumns: max(1, decoded.maxColumns),
                showPhysicalType: decoded.showPhysicalType,
                hideListElement: decoded.hideListElement,
                scanAllFiles: decoded.scanAllFiles,
                maxScanFiles: max(1, decoded.maxScanFiles),
                recursiveScan: decoded.recursiveScan,
                showDataTab: decoded.showDataTab ?? true,
                previewRows: max(1, min(decoded.previewRows ?? 100, ParquetParserBounds.maxPreviewRows))
            )
        }

        let defaults = UserDefaults(suiteName: "com.rkrug.parquetindexer.previewhost.preview") ?? .standard
        var s = PreviewSettings()
        if defaults.object(forKey: "expandDepth") != nil {
            s.expandDepth = max(0, min(defaults.integer(forKey: "expandDepth"), 10))
            s.showAllColumns = defaults.bool(forKey: "showAllColumns")
            let maxCols = defaults.integer(forKey: "maxColumns")
            s.maxColumns = maxCols > 0 ? maxCols : 500
            s.showPhysicalType = defaults.bool(forKey: "showPhysicalType")
            s.hideListElement = defaults.bool(forKey: "hideListElement")
            s.scanAllFiles = defaults.bool(forKey: "scanAllFiles")
            let maxScan = defaults.integer(forKey: "maxScanFiles")
            s.maxScanFiles = maxScan > 0 ? maxScan : 500
            if defaults.object(forKey: "recursiveScan") == nil {
                s.recursiveScan = true
            } else {
                s.recursiveScan = defaults.bool(forKey: "recursiveScan")
            }
            if defaults.object(forKey: "showDataTab") != nil {
                s.showDataTab = defaults.bool(forKey: "showDataTab")
            }
            let rows = defaults.integer(forKey: "previewRows")
            if rows > 0 { s.previewRows = min(rows, ParquetParserBounds.maxPreviewRows) }
        }
        return s
    }

    private func buildDisplayRows(columns: ArraySlice<ColumnInfo>, settings: PreviewSettings) -> [DisplayRow] {
        let root = ColumnTreeNode()

        for col in columns {
            var parts = col.name.split(separator: ".").map(String.init)
            if parts.isEmpty { continue }
            if parts.count > ParquetParserBounds.maxDepth {
                let tail = parts[(ParquetParserBounds.maxDepth - 1)...].joined(separator: ".")
                parts = Array(parts[..<(ParquetParserBounds.maxDepth - 1)]) + [tail]
            }

            var node = root
            var idx = 0
            while idx < parts.count {
                let part = parts[idx]
                if settings.hideListElement && (part == "list" || part == "element") {
                    idx += 1
                    continue
                }

                let child = node.child(named: part)
                let hasNext = (idx + 1) < parts.count
                if !hasNext {
                    let renderedType = settings.showPhysicalType
                        ? "\(col.logicalType) (\(col.physicalType))"
                        : col.logicalType
                    child.type = renderedType
                    node = child
                    idx += 1
                    continue
                }

                if (idx + 2) < parts.count && parts[idx + 1] == "list" && parts[idx + 2] == "element" {
                    child.groupType = "list"
                    if (idx + 3) >= parts.count {
                        let renderedType = settings.showPhysicalType
                            ? "\(col.logicalType) (\(col.physicalType))"
                            : col.logicalType
                        child.type = "list<\(renderedType)>"
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

    private func schemaExportScheme(for format: SchemaExportFormat) -> SchemaExportScheme {
        switch format {
        case .arrowJSONV1:
            return SchemaExportScheme(
                id: format.rawValue,
                version: 1,
                title: "Parquet Quick Look Arrow-Friendly Schema JSON",
                description: "Nested and flat schema export with Arrow-friendly logical types plus R/Python snippet stubs."
            )
        }
    }

    private func buildSchemaExportPayload(format: SchemaExportFormat, path: String, columns: [ColumnInfo], rowCount: Int64) -> SchemaExportPayload {
        let fields = buildExportFields(columns: columns)
        let flat = columns.map {
            ExportFlatField(path: $0.name, type: $0.logicalType, physicalType: $0.physicalType)
        }
        return SchemaExportPayload(
            format: format.rawValue,
            sourcePath: path,
            rowCount: rowCount,
            columnCount: columns.count,
            fields: fields,
            flatFields: flat,
            pythonSnippet: pythonSchemaSnippet(columns: columns),
            rSnippet: rSchemaSnippet(columns: columns)
        )
    }

    private func schemaExportBase64(path: String, columns: [ColumnInfo], rowCount: Int64, format: SchemaExportFormat = .arrowJSONV1) -> String {
        let envelope = SchemaExportEnvelope(
            scheme: schemaExportScheme(for: format),
            payload: buildSchemaExportPayload(format: format, path: path, columns: columns, rowCount: rowCount)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(envelope)) ?? Data("{}".utf8)
        return data.base64EncodedString()
    }

    private func buildExportFields(columns: [ColumnInfo]) -> [ExportField] {
        let root = ColumnTreeNode()
        for col in columns {
            let parts = col.name.split(separator: ".").map(String.init)
            guard !parts.isEmpty else { continue }
            var node = root
            for (idx, p) in parts.enumerated() {
                node = node.child(named: p)
                if idx == parts.count - 1 {
                    node.type = col.logicalType
                } else if node.groupType == nil {
                    node.groupType = "struct"
                }
            }
        }

        func walk(node: ColumnTreeNode) -> [ExportField] {
            var out: [ExportField] = []
            for name in node.order {
                guard let child = node.children[name] else { continue }
                let children = walk(node: child)
                let t = children.isEmpty ? (child.type ?? "unknown") : (child.groupType ?? "struct")
                out.append(ExportField(name: name, type: t, children: children))
            }
            return out
        }

        return walk(node: root)
    }

    private func pythonTypeExpr(_ logical: String) -> String {
        let t = logical.lowercased()
        if t.hasPrefix("string") { return "pa.string()" }
        if t == "bool" || t == "boolean" { return "pa.bool_()" }
        if t == "int8" { return "pa.int8()" }
        if t == "int16" { return "pa.int16()" }
        if t == "int32" { return "pa.int32()" }
        if t == "int64" { return "pa.int64()" }
        if t == "uint8" { return "pa.uint8()" }
        if t == "uint16" { return "pa.uint16()" }
        if t == "uint32" { return "pa.uint32()" }
        if t == "uint64" { return "pa.uint64()" }
        if t == "float" { return "pa.float32()" }
        if t == "double" { return "pa.float64()" }
        if t == "date32[day]" { return "pa.date32()" }
        if t == "timestamp[ms]" { return "pa.timestamp('ms')" }
        if t == "timestamp[us]" { return "pa.timestamp('us')" }
        if t == "timestamp[ns]" { return "pa.timestamp('ns')" }
        if t == "time32[ms]" { return "pa.time32('ms')" }
        if t == "time64[us]" { return "pa.time64('us')" }
        if t == "time64[ns]" { return "pa.time64('ns')" }
        return "pa.string()  # fallback from \(logical)"
    }

    private func rTypeExpr(_ logical: String) -> String {
        let t = logical.lowercased()
        if t.hasPrefix("string") { return "arrow::utf8()" }
        if t == "bool" || t == "boolean" { return "arrow::boolean()" }
        if t == "int8" { return "arrow::int8()" }
        if t == "int16" { return "arrow::int16()" }
        if t == "int32" { return "arrow::int32()" }
        if t == "int64" { return "arrow::int64()" }
        if t == "uint8" { return "arrow::uint8()" }
        if t == "uint16" { return "arrow::uint16()" }
        if t == "uint32" { return "arrow::uint32()" }
        if t == "uint64" { return "arrow::uint64()" }
        if t == "float" { return "arrow::float32()" }
        if t == "double" { return "arrow::float64()" }
        if t == "date32[day]" { return "arrow::date32()" }
        if t == "timestamp[ms]" { return "arrow::timestamp(\"ms\")" }
        if t == "timestamp[us]" { return "arrow::timestamp(\"us\")" }
        if t == "timestamp[ns]" { return "arrow::timestamp(\"ns\")" }
        if t == "time32[ms]" { return "arrow::time32(\"ms\")" }
        if t == "time64[us]" { return "arrow::time64(\"us\")" }
        if t == "time64[ns]" { return "arrow::time64(\"ns\")" }
        return "arrow::utf8()  # fallback from \(logical)"
    }

    private func pythonSchemaSnippet(columns: [ColumnInfo]) -> String {
        var lines: [String] = [
            "import pyarrow as pa",
            "",
            "schema = pa.schema(["
        ]
        for col in columns {
            lines.append("    pa.field(\"\(col.name)\", \(pythonTypeExpr(col.logicalType))),")
        }
        lines.append("])")
        return lines.joined(separator: "\n")
    }

    private func rSchemaSnippet(columns: [ColumnInfo]) -> String {
        var lines: [String] = [
            "schema <- arrow::schema(",
        ]
        for (idx, col) in columns.enumerated() {
            let comma = idx == columns.count - 1 ? "" : ","
            lines.append("  arrow::field(\"\(col.name)\", \(rTypeExpr(col.logicalType)))\(comma)")
        }
        lines.append(")")
        return lines.joined(separator: "\n")
    }

    private func renderHTML(path: String, metadata: Metadata) -> String {
        let settings = loadSettings()
        let exportSchemaB64 = schemaExportBase64(path: path, columns: metadata.columns, rowCount: metadata.rowCount)
        let showCount = settings.showAllColumns
            ? metadata.columns.count
            : min(metadata.columns.count, max(1, settings.maxColumns))
        let hidden = max(0, metadata.columns.count - showCount)
        let displayRows = buildDisplayRows(columns: metadata.columns.prefix(showCount), settings: settings)

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
            if hidden > 0 {
                rows += "<tr><td colspan=\"3\" class=\"muted\">+ \(hidden) more columns not shown (change in Parquet Manager settings)</td></tr>"
            }
        }

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\" />
          <style>
            body{font-family:-apple-system,system-ui,sans-serif;margin:18px;color:#1f2937;font-size:12px}
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
            .toolbar{margin:12px 0 10px}
            .export-pane{display:none;margin:10px 0;border:1px solid #d1d5db;border-radius:8px;padding:10px;background:#f8fafc}
            .export-pane textarea{width:100%;height:220px;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,monospace;font-size:11px;border:1px solid #cbd5e1;border-radius:6px;padding:8px;resize:vertical}
            .export-actions{margin-top:8px;display:flex;gap:8px}
            .sub-btn{border:1px solid #cbd5e1;background:#fff;color:#111827;border-radius:6px;padding:5px 8px;font-size:11px;cursor:pointer}
            .sub-btn:hover{background:#f3f4f6}
            h2{font-size:15px;margin:22px 0 8px}
            details{margin:10px 0}
            summary{cursor:pointer;font-weight:600;padding:4px 0}
            table.facts th{width:140px;background:transparent}
            code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;word-break:break-all}
          </style>
          <script>
            function schemaBytes(){
              const b64 = "\(exportSchemaB64)";
              const bytes = atob(b64);
              const arr = new Uint8Array(bytes.length);
              for(let i=0;i<bytes.length;i++){ arr[i] = bytes.charCodeAt(i); }
              return arr;
            }
            function schemaJson(){
              try {
                const arr = schemaBytes();
                return new TextDecoder("utf-8").decode(arr);
              } catch (e) {
                return "";
              }
            }
            function showSchemaPane(){
              const pane = document.getElementById("export-pane");
              const area = document.getElementById("export-json");
              const btn = document.getElementById("json-btn");
              if(!pane || !area){ return; }
              if(pane.style.display === "block"){
                pane.style.display = "none";
                if(btn){ btn.textContent = "Show JSON"; }
                return;
              }
              area.value = schemaJson();
              pane.style.display = "block";
              if(btn){ btn.textContent = "Hide JSON"; }
            }
            function copySchema(){
              const area = document.getElementById("export-json");
              if(!area){ return; }
              area.focus();
              area.select();
              document.execCommand("copy");
            }
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
            function expandToDepth(depth){
              if(depth <= 0){ return; }
              for(let d=0; d<depth; d++){
                const current=Array.from(document.querySelectorAll('button.toggle[data-expanded=\"false\"]'));
                if(current.length===0){ break; }
                current.forEach(function(btn){
                  const id=parseInt(btn.id.replace('btn-',''),10);
                  const row=document.getElementById('row-'+id);
                  if(!row){ return; }
                  const parent=row.getAttribute('data-parent');
                  if(parent){
                    const prow=document.getElementById('row-'+parent);
                    if(prow && prow.classList.contains('hidden')){ return; }
                  }
                  toggleNode(id);
                });
              }
            }
            window.addEventListener('DOMContentLoaded', function(){ expandToDepth(\(settings.expandDepth)); });
          </script>
        </head>
        <body>
          <h1>Parquet Quick Look\(esc(PreviewProvider.versionSuffix))</h1>
          <div class=\"muted\">\(esc(path))</div>
          <div class=\"toolbar\">
            <button id=\"json-btn\" class=\"sub-btn\" onclick=\"showSchemaPane();return false;\">Show JSON</button>
            <span class=\"muted\" style=\"margin-left:10px\">Settings: open Parquet Quick Look and Index, then ⌘,</span>
          </div>
          <div id=\"export-pane\" class=\"export-pane\">
            <div class=\"muted\" style=\"margin-bottom:6px\">If download is blocked by Quick Look, copy the schema JSON from here.</div>
            <textarea id=\"export-json\" spellcheck=\"false\"></textarea>
            <div class=\"export-actions\">
              <button class=\"sub-btn\" onclick=\"copySchema();return false;\">Copy JSON</button>
            </div>
          </div>

          <div class=\"meta\">
            <div class=\"card\"><div class=\"label\">Valid</div><div class=\"val\">\(metadata.valid ? "Yes" : "No")</div></div>
            <div class=\"card\"><div class=\"label\">File Size</div><div class=\"val\">\(esc(formatBytes(metadata.fileSize)))</div></div>
            <div class=\"card\"><div class=\"label\">Footer</div><div class=\"val\">\(esc(formatBytes(UInt64(metadata.footerLength))))</div></div>
            <div class=\"card\"><div class=\"label\">Rows</div><div class=\"val\">\(esc(formatInt(metadata.rowCount)))</div></div>
            <div class=\"card\"><div class=\"label\">Columns</div><div class=\"val\">\(esc(formatInt(Int64(metadata.columns.count))))</div></div>
          </div>

          \(settings.showDataTab && metadata.valid ? tabBarHTML() : "")
          <div id=\"tab-schema\">
          <table>
            <thead><tr><th>#</th><th>Column</th><th>Type</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
          \(footerDetailsHTML(metadata))
          </div>
          \(settings.showDataTab && metadata.valid ? dataTabHTML(
              ParquetRowReader.read(at: URL(fileURLWithPath: path), maxRows: settings.previewRows, maxColumns: ParquetParserBounds.maxPreviewColumns),
              totalRows: metadata.rowCount,
              settings: settings
          ) : "")
        </body>
        </html>
        """
    }

    // Writer, storage per column, row groups and key/value metadata; all from the footer.
    private func footerDetailsHTML(_ m: Metadata) -> String {
        guard m.valid else { return "" }
        func bytes(_ v: Int64) -> String { esc(formatBytes(UInt64(max(0, v)))) }
        // UTC date, plus the time when it is not midnight.
        func day(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let s = f.string(from: d)
            return esc(s.hasSuffix(" 00:00:00") ? String(s.dropLast(9)) : s)
        }

        let compressed = m.columns.reduce(Int64(0)) { ParquetParserBounds.saturatingAdd($0, $1.compressedSize) }
        let uncompressed = m.columns.reduce(Int64(0)) { ParquetParserBounds.saturatingAdd($0, $1.uncompressedSize) }
        var facts = "<tr><th>Writer</th><td>\(esc(m.createdBy ?? "—"))</td></tr>"
        facts += "<tr><th>Row groups</th><td>\(esc(formatInt(Int64(m.rowGroupCount))))</td></tr>"
        if uncompressed > 0 {
            let ratio = String(format: "%.1f×", Double(uncompressed) / Double(max(1, compressed)))
            facts += "<tr><th>Data size</th><td>\(bytes(compressed)) compressed, \(bytes(uncompressed)) uncompressed (\(ratio))</td></tr>"
        }
        if let range = m.dateRange {
            facts += "<tr><th>Date range</th><td>\(day(range.min)) – \(day(range.max)) <span class=\"muted\">(column statistics, UTC)</span></td></tr>"
        }
        var html = "<h2>Footer details</h2><table class=\"facts\">\(facts)</table>"

        if m.columns.contains(where: { !$0.codecs.isEmpty }) {
            var rows = ""
            for c in m.columns {
                let range = c.minDate.flatMap { lo in c.maxDate.map { "\(day(lo)) – \(day($0))" } } ?? ""
                rows += "<tr><td>\(esc(c.name))</td><td>\(esc(c.codecs.joined(separator: ", ")))</td><td>\(bytes(c.compressedSize))</td><td>\(bytes(c.uncompressedSize))</td><td>\(range)</td></tr>"
            }
            html += "<details><summary>Storage per column</summary><table><thead><tr><th>Column</th><th>Codec</th><th>Compressed</th><th>Uncompressed</th><th>Date range</th></tr></thead><tbody>\(rows)</tbody></table></details>"
        }

        if !m.rowGroups.isEmpty {
            var rows = ""
            for (i, g) in m.rowGroups.enumerated() {
                rows += "<tr><td>\(i + 1)</td><td>\(esc(formatInt(g.rows)))</td><td>\(bytes(g.compressedSize))</td><td>\(bytes(g.totalByteSize))</td></tr>"
            }
            let more = m.rowGroupCount - m.rowGroups.count
            if more > 0 {
                rows += "<tr><td colspan=\"4\" class=\"muted\">+ \(more) more row groups</td></tr>"
            }
            html += "<details><summary>Row groups (\(m.rowGroupCount))</summary><table><thead><tr><th>#</th><th>Rows</th><th>Compressed</th><th>Uncompressed</th></tr></thead><tbody>\(rows)</tbody></table></details>"
        }

        if !m.keyValueMetadata.isEmpty {
            var rows = ""
            for kv in m.keyValueMetadata {
                let value: String
                if kv.key == "ARROW:schema" {
                    value = "<span class=\"muted\">Arrow schema, \(kv.valueLength) bytes (see Show JSON)</span>"
                } else if let v = kv.value {
                    let short = v.count > 300 ? String(v.prefix(300)) + "…" : v
                    value = "<code>\(esc(short))</code>" + (kv.valueLength > 300 ? " <span class=\"muted\">(\(kv.valueLength) bytes)</span>" : "")
                } else {
                    value = "<span class=\"muted\">no value</span>"
                }
                rows += "<tr><td>\(esc(kv.key))</td><td>\(value)</td></tr>"
            }
            html += "<details><summary>Key/value metadata (\(m.keyValueMetadata.count))</summary><table><thead><tr><th>Key</th><th>Value</th></tr></thead><tbody>\(rows)</tbody></table></details>"
        }
        return html
    }

    // Schema | Data tab buttons plus the styles of both tabs (file and dataset pages).
    private func tabBarHTML() -> String {
        """
          <style>
            .tabs{display:flex;gap:4px;margin:6px 0 10px;border-bottom:1px solid #d1d5db}
            .tab{border:1px solid transparent;border-bottom:none;background:transparent;color:#4b5563;padding:6px 14px;font-size:12px;cursor:pointer;border-radius:6px 6px 0 0}
            .tab.active{border-color:#d1d5db;background:#fff;color:#111827;font-weight:600;margin-bottom:-1px}
            .data-scroll{max-height:260px;overflow:auto;border:1px solid #e5e7eb;border-radius:6px}
            table.data{width:auto;min-width:100%}
            table.data th{position:sticky;top:0;z-index:1;white-space:nowrap}
            table.data td{height:23px;padding:0 8px;line-height:23px;white-space:nowrap;max-width:280px;overflow:hidden;text-overflow:ellipsis;vertical-align:middle;cursor:default}
            table.data td.rn{color:#9ca3af;text-align:right}
            table.data td.null{color:#9ca3af;font-style:italic}
            table.data td.sel{background:#e0ecff}
            table.data td.nested{color:#1d4ed8;cursor:pointer}
            .cell-detail{margin-top:8px;padding:8px;border:1px solid #e5e7eb;border-radius:6px;background:#f8fafc;white-space:pre-wrap;word-break:break-all;max-height:320px;overflow:auto}
            .cell-detail details{margin:0}
            .cell-detail summary{cursor:pointer}
            .cell-detail .tree{margin-left:18px}
            .cell-detail .key{color:#6b7280}
            .cell-detail .nul{color:#9ca3af;font-style:italic}
            .notes{color:#92400e;margin:4px 0}
          </style>
          <div class=\"tabs\">
            <button id=\"tab-btn-schema\" class=\"tab active\" onclick=\"showTab('schema');return false;\">Schema</button>
            <button id=\"tab-btn-data\" class=\"tab\" onclick=\"showTab('data');return false;\">Data</button>
          </div>
        """
    }

    // Data tab (#25): the first rows as embedded JSON, drawn by JavaScript only for the visible
    // part of the scroll area, so thousands of rows stay smooth. Quick Look cannot call back into
    // the extension, so the rows are fixed when the preview is generated.
    // totalRows: rows in the file or dataset, for the "First n of m rows" line.
    private func dataTabHTML(_ table: ParquetRowReader.Table, totalRows: Int64, settings: PreviewSettings) -> String {
        let payload: [String: Any] = [
            "columns": table.columns,
            "rows": table.rows.map { row in row.map { cell -> Any in cell ?? NSNull() } },
            "nested": table.nestedColumns,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .map { String(decoding: $0, as: UTF8.self) }?
            .replacingOccurrences(of: "</", with: "<\\/") ?? "{\"columns\":[],\"rows\":[]}"

        var info = "First \(formatInt(Int64(table.rows.count))) of \(formatInt(totalRows)) rows"
        if table.sourceFiles > 1 {
            info += " (from \(table.sourceFiles) files)"
        }
        if table.rows.count < min(settings.previewRows, Int(clamping: totalRows)) && table.notes.isEmpty {
            info += " (cut to fit \(formatInt(Int64(ParquetParserBounds.maxPreviewCells))) cells)"
        }
        if table.hiddenColumns > 0 {
            info += ", first \(table.columns.count) columns (\(table.hiddenColumns) more not shown)"
        }
        info += ". Change the number of rows in Parquet Quick Look and Index (⌘,)."
        let notes = table.notes.map { "<div class=\"notes\">\(esc($0))</div>" }.joined()
        let header = (["#"] + table.columns).map { "<th>\(esc($0))</th>" }.joined()

        return """
          <div id=\"tab-data\" style=\"display:none\">
            <div class=\"muted\" style=\"margin-bottom:6px\">\(esc(info))</div>
            \(notes)
            <div id=\"data-scroll\" class=\"data-scroll\">
              <table class=\"data\"><thead><tr>\(header)</tr></thead><tbody id=\"data-body\"></tbody></table>
            </div>
            <div id=\"cell-detail\" class=\"cell-detail muted\">Click a cell to see its full value.</div>
          </div>
          <script>
            (function(){
              const D = \(json);
              const H = 24;
              const box = document.getElementById('data-scroll');
              const body = document.getElementById('data-body');
              const n = D.columns.length;
              const nested = D.nested || [];
              const parsed = new Map();
              let selected = null;
              function esc(s){ return String(s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
              // Nested cells hold JSON (lists, structs, maps; leaf values as strings).
              function value(r, c){
                const v = D.rows[r][c];
                if (!nested[c] || v === null) { return v; }
                const key = r * n + c;
                if (!parsed.has(key)) { try { parsed.set(key, JSON.parse(v)); } catch (e) { parsed.set(key, v); } }
                return parsed.get(key);
              }
              function brief(v){
                if (v === null) { return 'null'; }
                if (Array.isArray(v)) { return '[' + v.map(brief).join(', ') + ']'; }
                if (typeof v === 'object') { return '{' + Object.keys(v).map(function(k){ return k + ': ' + brief(v[k]); }).join(', ') + '}'; }
                return String(v);
              }
              function tree(v, key, depth){
                const label = key === null ? '' : '<span class="key">' + esc(key) + ':</span> ';
                if (v === null) { return '<div>' + label + '<span class="nul">null</span></div>'; }
                if (typeof v !== 'object') { return '<div>' + label + esc(v) + '</div>'; }
                const isList = Array.isArray(v);
                const keys = isList ? v.map(function(_, i){ return String(i); }) : Object.keys(v);
                const count = isList ? keys.length + ' items' : keys.length + ' fields';
                if (keys.length === 0) { return '<div>' + label + (isList ? '[]' : '{}') + '</div>'; }
                return '<details' + (depth < 1 ? ' open' : '') + '><summary>' + label + '<span class="key">' + (isList ? '[' : '{') + count + (isList ? ']' : '}') + '</span></summary><div class="tree">'
                  + keys.map(function(k){ return tree(v[k], k, depth + 1); }).join('') + '</div></details>';
              }
              function render(){
                const first = Math.max(0, Math.floor(box.scrollTop / H) - 10);
                const last = Math.min(D.rows.length, first + Math.ceil(box.clientHeight / H) + 30);
                let html = '<tr><td colspan="' + (n + 1) + '" style="height:' + (first * H) + 'px;padding:0;border:0"></td></tr>';
                for (let r = first; r < last; r++) {
                  html += '<tr><td class="rn">' + (r + 1) + '</td>';
                  const row = D.rows[r];
                  for (let c = 0; c < n; c++) {
                    const v = row[c];
                    const sel = selected && selected[0] === r && selected[1] === c ? ' sel' : '';
                    const shown = nested[c] && v !== null ? brief(value(r, c)) : v;
                    html += v === null
                      ? '<td class="null' + sel + '" data-r="' + r + '" data-c="' + c + '">null</td>'
                      : '<td class="' + (nested[c] ? 'nested' : '') + sel + '" data-r="' + r + '" data-c="' + c + '">' + esc(shown.length > 300 ? shown.slice(0, 300) + '…' : shown) + '</td>';
                  }
                  html += '</tr>';
                }
                html += '<tr><td colspan="' + (n + 1) + '" style="height:' + ((D.rows.length - last) * H) + 'px;padding:0;border:0"></td></tr>';
                body.innerHTML = html;
              }
              box.addEventListener('scroll', render);
              body.addEventListener('click', function(e){
                const td = e.target.closest('td[data-r]');
                if (!td) { return; }
                const r = +td.dataset.r, c = +td.dataset.c, v = value(r, c);
                selected = [r, c];
                const detail = document.getElementById('cell-detail');
                detail.classList.remove('muted');
                if (nested[c] && v !== null && typeof v === 'object') {
                  detail.innerHTML = '<div class="key">' + esc(D.columns[c]) + ' · row ' + (r + 1) + '</div>' + tree(v, null, 0);
                } else {
                  detail.textContent = D.columns[c] + ' · row ' + (r + 1) + ': ' + (v === null ? 'null' : v);
                }
                render();
              });
              window.showTab = function(name){
                ['schema', 'data'].forEach(function(t){
                  document.getElementById('tab-' + t).style.display = t === name ? '' : 'none';
                  document.getElementById('tab-btn-' + t).classList.toggle('active', t === name);
                });
                if (name === 'data') { render(); }
              };
            })();
          </script>
        """
    }

    private func renderDatasetHTML(path: String, dataset: DatasetMetadata, settings: PreviewSettings) -> String {
        let exportSchemaB64 = schemaExportBase64(path: path, columns: dataset.columns, rowCount: dataset.totalRows)
        let showCount = settings.showAllColumns
            ? dataset.columns.count
            : min(dataset.columns.count, max(1, settings.maxColumns))
        let hidden = max(0, dataset.columns.count - showCount)
        let displayRows = buildDisplayRows(columns: dataset.columns.prefix(showCount), settings: settings)

        let partitionKeys = dataset.partitionValuesByKey.keys.sorted()
        var partitionRows = ""
        if partitionKeys.isEmpty {
            partitionRows = "<tr><td colspan=\"2\" class=\"muted\">No hive partition segments (key=value) detected.</td></tr>"
        } else {
            for key in partitionKeys {
                let values = (dataset.partitionValuesByKey[key] ?? []).sorted()
                let joined = values.joined(separator: ", ")
                partitionRows += "<tr><td class=\"group\">\(esc(key))</td><td>\(esc(joined))</td></tr>"
            }
        }

        var schemaRows = ""
        if showCount == 0 {
            schemaRows += "<tr><td colspan=\"3\" class=\"muted\">No columns parsed from parquet footer metadata.</td></tr>"
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
                schemaRows += "<tr id=\"row-\(r.id)\" class=\"\(hiddenClass)\"\(parentAttr)><td>\(idx + 1)</td><td class=\"\(nameClass)\" style=\"padding-left:\(indentPx + 8)px\">\(toggle)\(esc(r.name))</td><td>\(typeText)</td></tr>"
            }
            if hidden > 0 {
                schemaRows += "<tr><td colspan=\"3\" class=\"muted\">+ \(hidden) more columns not shown (change in Parquet Manager settings)</td></tr>"
            }
        }

        let notes = dataset.truncated
            ? "<div class=\"muted\" style=\"margin:8px 0 0\">Scan truncated after \(settings.maxScanFiles) parquet files.</div>"
            : ""

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\" />
          <style>
            body{font-family:-apple-system,system-ui,sans-serif;margin:18px;color:#1f2937;font-size:12px}
            h1{font-size:20px;margin:0 0 10px}
            h2{font-size:14px;margin:18px 0 8px}
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
            .toolbar{margin:12px 0 10px}
            .export-pane{display:none;margin:10px 0;border:1px solid #d1d5db;border-radius:8px;padding:10px;background:#f8fafc}
            .export-pane textarea{width:100%;height:220px;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,monospace;font-size:11px;border:1px solid #cbd5e1;border-radius:6px;padding:8px;resize:vertical}
            .export-actions{margin-top:8px;display:flex;gap:8px}
            .sub-btn{border:1px solid #cbd5e1;background:#fff;color:#111827;border-radius:6px;padding:5px 8px;font-size:11px;cursor:pointer}
            .sub-btn:hover{background:#f3f4f6}
          </style>
          <script>
            function schemaBytes(){
              const b64 = "\(exportSchemaB64)";
              const bytes = atob(b64);
              const arr = new Uint8Array(bytes.length);
              for(let i=0;i<bytes.length;i++){ arr[i] = bytes.charCodeAt(i); }
              return arr;
            }
            function schemaJson(){
              try {
                const arr = schemaBytes();
                return new TextDecoder("utf-8").decode(arr);
              } catch (e) {
                return "";
              }
            }
            function showSchemaPane(){
              const pane = document.getElementById("export-pane");
              const area = document.getElementById("export-json");
              const btn = document.getElementById("json-btn");
              if(!pane || !area){ return; }
              if(pane.style.display === "block"){
                pane.style.display = "none";
                if(btn){ btn.textContent = "Show JSON"; }
                return;
              }
              area.value = schemaJson();
              pane.style.display = "block";
              if(btn){ btn.textContent = "Hide JSON"; }
            }
            function copySchema(){
              const area = document.getElementById("export-json");
              if(!area){ return; }
              area.focus();
              area.select();
              document.execCommand("copy");
            }
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
              if(expanded){ collapseRec(id); return; }
              btn.dataset.expanded='true';
              btn.textContent='▾';
              childRows(id).forEach(function(row){ row.classList.remove('hidden'); });
            }
            function expandToDepth(depth){
              if(depth <= 0){ return; }
              for(let d=0; d<depth; d++){
                const current=Array.from(document.querySelectorAll('button.toggle[data-expanded=\"false\"]'));
                if(current.length===0){ break; }
                current.forEach(function(btn){
                  const id=parseInt(btn.id.replace('btn-',''),10);
                  const row=document.getElementById('row-'+id);
                  if(!row){ return; }
                  const parent=row.getAttribute('data-parent');
                  if(parent){
                    const prow=document.getElementById('row-'+parent);
                    if(prow && prow.classList.contains('hidden')){ return; }
                  }
                  toggleNode(id);
                });
              }
            }
            window.addEventListener('DOMContentLoaded', function(){ expandToDepth(\(settings.expandDepth)); });
          </script>
        </head>
        <body>
          <h1>Parquet Dataset Quick Look\(esc(PreviewProvider.versionSuffix))</h1>
          <div class=\"muted\">\(esc(path))</div>
          <div class=\"toolbar\">
            <button id=\"json-btn\" class=\"sub-btn\" onclick=\"showSchemaPane();return false;\">Show JSON</button>
            <span class=\"muted\" style=\"margin-left:10px\">Settings: open Parquet Quick Look and Index, then ⌘,</span>
          </div>
          <div id=\"export-pane\" class=\"export-pane\">
            <div class=\"muted\" style=\"margin-bottom:6px\">If download is blocked by Quick Look, copy the schema JSON from here.</div>
            <textarea id=\"export-json\" spellcheck=\"false\"></textarea>
            <div class=\"export-actions\">
              <button class=\"sub-btn\" onclick=\"copySchema();return false;\">Copy JSON</button>
            </div>
          </div>

          <div class=\"meta\">
            <div class=\"card\"><div class=\"label\">Parquet Files</div><div class=\"val\">\(esc(formatInt(Int64(dataset.fileCount))))</div></div>
            <div class=\"card\"><div class=\"label\">Valid Files</div><div class=\"val\">\(esc(formatInt(Int64(dataset.validFileCount))))</div></div>
            <div class=\"card\"><div class=\"label\">Total Size</div><div class=\"val\">\(esc(formatBytes(dataset.totalSize)))</div></div>
            <div class=\"card\"><div class=\"label\">Rows (sum)</div><div class=\"val\">\(esc(formatInt(dataset.totalRows)))</div></div>
            <div class=\"card\"><div class=\"label\">Columns (merged)</div><div class=\"val\">\(esc(formatInt(Int64(dataset.columns.count))))</div></div>
          </div>
          \(notes)
          \(settings.showDataTab ? tabBarHTML() : "")
          <div id=\"tab-schema\">

          <h2>Hive Partitions</h2>
          <table>
            <thead><tr><th>Key</th><th>Values</th></tr></thead>
            <tbody>\(partitionRows)</tbody>
          </table>

          <h2>Merged Schema</h2>
          <table>
            <thead><tr><th>#</th><th>Column</th><th>Type</th></tr></thead>
            <tbody>\(schemaRows)</tbody>
          </table>
          </div>
          \(settings.showDataTab ? dataTabHTML(
              ParquetRowReader.readDataset(
                  at: URL(fileURLWithPath: path),
                  maxRows: settings.previewRows,
                  maxColumns: ParquetParserBounds.maxPreviewColumns,
                  maxFiles: settings.scanAllFiles ? Int.max : settings.maxScanFiles,
                  recursive: settings.recursiveScan
              ),
              totalRows: dataset.totalRows,
              settings: settings
          ) : "")
        </body>
        </html>
        """
    }
}
