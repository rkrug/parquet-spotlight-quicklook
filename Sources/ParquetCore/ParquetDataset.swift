import Foundation

// Summary of a folder of Parquet files (a dataset, optionally hive-partitioned). Shared by
// Quick Look's folder preview and the Spotlight importer for `.pqds` dataset packages.
public enum ParquetDataset {
    public struct Summary {
        // Parquet files seen; stops at maxFiles + 1 when the scan is truncated.
        public var fileCount: Int = 0
        public var validFileCount: Int = 0
        public var totalSize: UInt64 = 0
        public var totalRows: Int64 = 0
        // Union of leaf columns in first-seen order; differing types become `mixed<a | b>`.
        public var columns: [ParquetFooter.Column] = []
        public var partitionValuesByKey: [String: Set<String>] = [:]
        public var truncated = false

        public init() {}
    }

    // Returns nil when the folder cannot be read or holds no `.parquet` files.
    public static func summarize(
        at folderURL: URL,
        maxFiles: Int,
        recursive: Bool,
        maxPartitionValuesPerKey: Int
    ) -> Summary? {
        let fm = Foundation.FileManager()
        let keys: [Foundation.URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        var options: Foundation.FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive {
            options.insert(.skipsSubdirectoryDescendants)
        }
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return nil
        }

        var dataset = Summary()
        var typeMap: [String: Set<String>] = [:]
        var firstPhysical: [String: String] = [:]
        var columnOrder: [String] = []
        let maxFilesToScan = max(1, maxFiles)

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext != "parquet" {
                continue
            }

            dataset.fileCount += 1
            if dataset.fileCount > maxFilesToScan {
                dataset.truncated = true
                break
            }

            if let size = try? fileURL.resourceValues(forKeys: Set<Foundation.URLResourceKey>([.fileSizeKey])).fileSize, size > 0 {
                dataset.totalSize = ParquetParserBounds.saturatingAdd(dataset.totalSize, UInt64(size))
            }

            for partition in partitions(of: fileURL, under: folderURL) {
                var values = dataset.partitionValuesByKey[partition.key] ?? Set<String>()
                if values.count < maxPartitionValuesPerKey {
                    values.insert(partition.value)
                }
                dataset.partitionValuesByKey[partition.key] = values
            }

            let fileMetadata = ParquetFooter.read(at: fileURL)
            if !fileMetadata.valid {
                continue
            }
            dataset.validFileCount += 1
            dataset.totalRows = ParquetParserBounds.saturatingAdd(dataset.totalRows, max(0, fileMetadata.rowCount))

            for col in fileMetadata.columns {
                if typeMap[col.name] == nil {
                    columnOrder.append(col.name)
                }
                var types = typeMap[col.name] ?? Set<String>()
                types.insert(col.logicalType)
                typeMap[col.name] = types
                if firstPhysical[col.name] == nil {
                    firstPhysical[col.name] = col.physicalType
                }
            }
        }

        if dataset.fileCount == 0 {
            return nil
        }

        dataset.columns = columnOrder.map { name in
            let logicals = (typeMap[name] ?? []).sorted()
            let logicalType = logicals.count <= 1
                ? (logicals.first ?? "unknown")
                : "mixed<\(logicals.joined(separator: " | "))>"
            return ParquetFooter.Column(
                name: name,
                logicalType: logicalType,
                physicalType: firstPhysical[name] ?? "UNKNOWN"
            )
        }

        return dataset
    }

    // Partitions between the dataset root and the file; folders above the root are ignored.
    static func partitions(of fileURL: URL, under baseFolder: URL) -> [(key: String, value: String)] {
        let basePath = baseFolder.standardizedFileURL.path
        let parentPath = fileURL.deletingLastPathComponent().standardizedFileURL.path
        guard parentPath.hasPrefix(basePath) else {
            return []
        }
        return ParquetFooter.partitions(inDirectoryPath: String(parentPath.dropFirst(basePath.count)))
    }
}
