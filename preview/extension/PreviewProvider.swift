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
                recursiveScan: decoded.recursiveScan
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

          <table>
            <thead><tr><th>#</th><th>Column</th><th>Type</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </body>
        </html>
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
        </body>
        </html>
        """
    }
}
