import Foundation

private func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func assertEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: String) {
    let l = lhs()
    let r = rhs()
    if l != r {
        fputs("FAIL: \(message) (left=\(l), right=\(r))\n", stderr)
        exit(1)
    }
}

private struct FakeSystemAccess: ParquetSystemAccess {
    var existingPaths: Set<String> = []
    var commandOutputs: [String: String] = [:]

    func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path)
    }

    func commandOutput(_ launchPath: String, _ arguments: [String]) -> String? {
        let key = ([launchPath] + arguments).joined(separator: " ")
        return commandOutputs[key]
    }
}

func runCoreTests() {
    // SemVer parsing/comparison.
    assertTrue(ParquetSemVer(strictTag: "v1.2.3") != nil, "strict tag should parse")
    assertTrue(ParquetSemVer(strictTag: "1.2.3") == nil, "strict tag should require v-prefix")
    assertTrue(ParquetSemVer(strictTag: "v1.2.3-beta.1") == nil, "strict tag should reject prerelease")
    assertEqual(ParquetSemVer(looseVersion: "v0.4.0")?.normalized, "0.4.0", "loose version should normalize")
    assertTrue(ParquetSemVer(looseVersion: "1.10.0")! > ParquetSemVer(looseVersion: "1.2.9")!, "numeric version comparison should be correct")

    // Trusted URLs.
    let validator = ParquetUpdateValidator()
    assertTrue(
        validator.isTrustedReleaseAPIResponseURL(URL(string: "https://api.github.com/repos/rkrug/parquet-spotlight-quicklook/releases/latest")),
        "trusted GitHub API URL should pass"
    )
    assertTrue(
        !validator.isTrustedReleaseAPIResponseURL(URL(string: "http://api.github.com/repos/rkrug/parquet-spotlight-quicklook/releases/latest")),
        "http API URL should fail"
    )
    assertTrue(
        validator.isTrustedReleasePageURL(URL(string: "https://github.com/rkrug/parquet-spotlight-quicklook/releases/tag/v0.4.0")!, expectedTag: "v0.4.0"),
        "trusted release page should pass"
    )
    assertTrue(
        !validator.isTrustedReleasePageURL(URL(string: "https://example.com/rkrug/parquet-spotlight-quicklook/releases/tag/v0.4.0")!, expectedTag: "v0.4.0"),
        "wrong release host should fail"
    )

    // Error mapping.
    let offline = ParquetUpdateErrorMapper.describeNetworkError(URLError(.notConnectedToInternet))
    assertTrue(offline.contains("offline"), "offline error should mention offline")
    let httpMsg = ParquetUpdateErrorMapper.describeHTTPError(
        statusCode: 403,
        data: #"{"message":"API rate limit exceeded"}"#.data(using: .utf8)
    )
    assertTrue(httpMsg.contains("rate limit"), "403 with payload should include API message")

    // Sanitization.
    let input = """
    /Users/rkrug/Documents/test.parquet
    user@example.org
    token=ghp_abcdefghijklmnopqrstuvwxyz1234
    password: topsecret
    """
    let sanitized = ParquetDiagnosticsSanitizer.sanitize(input)
    assertTrue(!sanitized.contains("rkrug"), "username should be redacted")
    assertTrue(!sanitized.contains("user@example.org"), "email should be redacted")
    assertTrue(!sanitized.contains("ghp_abcdefghijklmnopqrstuvwxyz1234"), "token should be redacted")
    assertTrue(!sanitized.contains("topsecret"), "password should be redacted")
    assertTrue(sanitized.contains("/Users/<user>"), "anonymized path marker expected")

    // Model-level DI tests around command execution/status evaluation.
    let userImporter = "/Users/test/Library/Spotlight/Parquet.mdimporter"
    let systemImporter = "/Library/Spotlight/Parquet.mdimporter"
    let appPath = "/Applications/Parquet Quick Look and Index.app"
    let appPath2 = "/Users/test/Applications/Parquet Quick Look and Index.app"
    let evaluator = ParquetStatusEvaluator(
        userImporterPath: userImporter,
        systemImporterPath: systemImporter,
        appCandidatePaths: [appPath, appPath2],
        quickLookAppexNames: ["ParquetQuickLook.appex", "ParquetPreview.appex"],
        homeDirectory: "/Users/test"
    )

    let systemWithImporterOnDisk = FakeSystemAccess(existingPaths: [userImporter], commandOutputs: [:])
    let snapshot1 = evaluator.evaluate(using: systemWithImporterOnDisk)
    assertTrue(snapshot1.importerInstalled, "importer should be installed when bundle exists on disk")
    assertTrue(!snapshot1.quickLookBundlePresent, "quick look should be false when appex is missing")

    let mdimportKey = "/usr/bin/mdimport -L"
    let systemWithImporterRegistered = FakeSystemAccess(
        existingPaths: [],
        commandOutputs: [mdimportKey: "...\n/Users/test/Library/Spotlight/Parquet.mdimporter\n..."]
    )
    let snapshot2 = evaluator.evaluate(using: systemWithImporterRegistered)
    assertTrue(snapshot2.importerInstalled, "importer should be installed when mdimport reports Parquet importer")

    let quickLookPath = "\(appPath)/Contents/PlugIns/ParquetQuickLook.appex"
    let systemWithQuickLook = FakeSystemAccess(existingPaths: [appPath, quickLookPath], commandOutputs: [:])
    let snapshot3 = evaluator.evaluate(using: systemWithQuickLook)
    assertTrue(snapshot3.appInstalledInApplications, "app should count as installed in /Applications")
    assertTrue(snapshot3.quickLookBundlePresent, "quick look should be true when appex exists in candidate app")

    let nonAppsEvaluator = ParquetStatusEvaluator(
        userImporterPath: userImporter,
        systemImporterPath: systemImporter,
        appCandidatePaths: ["/tmp/Parquet Quick Look and Index.app"],
        quickLookAppexNames: ["ParquetQuickLook.appex"],
        homeDirectory: "/Users/test"
    )
    let systemOutsideApplications = FakeSystemAccess(existingPaths: ["/tmp/Parquet Quick Look and Index.app"], commandOutputs: [:])
    let snapshot4 = nonAppsEvaluator.evaluate(using: systemOutsideApplications)
    assertTrue(!snapshot4.appInstalledInApplications, "app outside Applications should not count as installed")

    // Importer update on launch: only newer bundled importers replace the installed one.
    func replace(_ installed: String?, _ installedBuild: String?, _ bundled: String?, _ bundledBuild: String?) -> Bool {
        ParquetImporterUpdate.shouldReplace(installedVersion: installed, installedBuild: installedBuild, bundledVersion: bundled, bundledBuild: bundledBuild)
    }
    assertTrue(replace("0.4.3", "9", "0.5.0", "10"), "newer bundled version should replace")
    assertTrue(!replace("0.5.0", "10", "0.5.0", "10"), "same version and build should not replace")
    assertTrue(replace("0.5.0", "10", "0.5.0", "11"), "same version, newer build should replace")
    assertTrue(!replace("0.5.0", "11", "0.5.0", "10"), "same version, older build should not replace")
    assertTrue(!replace("0.6.0", "12", "0.5.0", "10"), "older bundled version should never downgrade")
    assertTrue(replace(nil, nil, "0.5.0", "10"), "unreadable installed version should be replaced")
    assertTrue(replace("garbage", "x", "0.5.0", "10"), "unparseable installed version should be replaced")
    assertTrue(!replace("0.4.3", "9", nil, nil), "unreadable bundled version should not replace")

    // Self-removal must pass the bundle path as a positional parameter, never inside the script.
    let pathWithShellSyntax = "/Users/x/Apps/$(echo a) `echo b` \"q\" \\x/Parquet Quick Look and Index.app"
    let args = ParquetSelfRemoval.shellArguments(forRemovingBundleAt: pathWithShellSyntax)
    assertEqual(args.first, "-c", "self-removal should invoke sh with -c")
    assertEqual(args[1], "(sleep 1; rm -rf -- \"$1\") >/dev/null 2>&1 &", "shell script must be a fixed string")
    assertEqual(args.last, pathWithShellSyntax, "bundle path must be passed as the positional argument")
    assertEqual(args.count, 4, "expected -c, script, argv0, path")
    assertTrue(!args[1].contains(pathWithShellSyntax), "bundle path must not be interpolated into the script")

    // Sanity bounds: declared counts, totals, and skip budgets stay finite.
    assertEqual(ParquetParserBounds.maxDepth, 100, "schema walk depth should stay modest")
    assertEqual(ParquetParserBounds.maxIndexedColumns, 4096, "importer column cap")
    assertEqual(ParquetParserBounds.maxFooterLength, 16 * 1024 * 1024, "importer footer cap")
    assertEqual(ParquetParserBounds.boundedCount(declared: 50, remaining: 8), 8, "declared count should be clamped to remaining bytes")
    assertEqual(ParquetParserBounds.boundedCount(declared: 3, remaining: 10), 3, "declared count within remaining bytes should be kept")
    assertEqual(ParquetParserBounds.boundedCount(declared: 0, remaining: 10), 0, "zero declared count should be empty")
    assertEqual(ParquetParserBounds.boundedCount(declared: -4, remaining: 10), 0, "negative declared count should be empty")
    assertEqual(ParquetParserBounds.boundedCount(declared: 4, remaining: 0), 0, "no remaining bytes should yield an empty count")
    assertEqual(ParquetParserBounds.saturatingAdd(Int64.max, Int64(1)), Int64.max, "int64 totals should saturate")
    assertEqual(ParquetParserBounds.saturatingAdd(Int64(12), Int64(30)), Int64(42), "int64 totals should add when in range")
    assertEqual(ParquetParserBounds.saturatingAdd(UInt64.max, UInt64(1)), UInt64.max, "uint64 totals should saturate")
    assertEqual(ParquetParserBounds.saturatingAdd(UInt64(2), UInt64(3)), UInt64(5), "uint64 totals should add when in range")
    assertTrue(ParquetParserBounds.maxSkips(forInputBytes: 10) < ParquetParserBounds.maxSkips(forInputBytes: 1_000), "skip budget should grow with input size")
    assertTrue(ParquetParserBounds.maxSkips(forInputBytes: 0) > 0, "empty input still has a finite skip budget")
}

// Footer parser vs Apache Arrow: Tests/fixtures/expected.txt holds Arrow's row and leaf-column
// counts. scripts/test_importer_summary.sh checks the importer's C entry point against the same file.
func runFooterFixtureTests(fixturesDir: String) {
    guard let expected = try? String(contentsOfFile: fixturesDir + "/expected.txt", encoding: .utf8) else {
        assertTrue(false, "missing \(fixturesDir)/expected.txt")
        return
    }
    var checked = 0
    for line in expected.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        assertEqual(fields.count, 5, "malformed expected.txt line: \(line)")
        let file = fields[0]
        let summary = ParquetFooter.read(at: URL(fileURLWithPath: fixturesDir + "/" + file))
        let paths = fields[4].isEmpty ? [] : fields[4].split(separator: ",").map(String.init)
        assertEqual(summary.valid, fields[1] == "1", "\(file): valid")
        assertEqual(summary.rowCount, Int64(fields[2]) ?? -1, "\(file): row count")
        assertEqual(summary.columns.count, Int(fields[3]) ?? -1, "\(file): leaf column count")
        assertEqual(summary.columns.map(\.name), paths, "\(file): leaf column paths")
        checked += 1
    }
    assertTrue(checked >= 6, "expected at least 6 fixtures, checked \(checked)")

    let flat = ParquetFooter.read(at: URL(fileURLWithPath: fixturesDir + "/flat.parquet"))
    assertEqual(
        flat.columns.map(\.logicalType),
        ["int32", "double", "string", "bool", "date32[day]", "timestamp[us]", "decimal(10,2)"],
        "flat.parquet: logical types"
    )

    // Hive partitions come from key=value directory names only.
    let parts = ParquetFooter.partitions(inDirectoryPath: "/data/ds/year=2024/region=EU%20West/plain/=x/k=/note=a=b")
    assertEqual(parts.map(\.key), ["year", "region", "note"], "partition keys")
    assertEqual(parts.map(\.value), ["2024", "EU West", "a=b"], "partition values (percent-decoded, first '=' splits)")
    assertTrue(ParquetFooter.partitions(inDirectoryPath: "/data/ds").isEmpty, "no partitions without key=value segments")
    let many = (1...100).map { "k\($0)=v" }.joined(separator: "/")
    assertEqual(ParquetFooter.partitions(inDirectoryPath: many).count, ParquetParserBounds.maxPartitionSegments, "partition count is capped")

    runDatasetTests(fixturesDir: fixturesDir)

    // Malformed footers parse to nothing instead of throwing or trapping.
    let garbage = ParquetFooter.parse(footer: Data([0x19, 0xfc, 0xff, 0xff, 0xff, 0x0f, 0x15, 0x00]))
    assertEqual(garbage.rowCount, 0, "garbage footer: no rows")
    assertTrue(garbage.columns.isEmpty, "garbage footer: no columns")
}

// Builds a small hive-partitioned dataset from the fixtures in a temporary folder.
private func runDatasetTests(fixturesDir: String) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("parquet-dataset-test-\(getpid())")
    defer { try? fm.removeItem(at: root) }
    let layout = [
        ("year=2024/region=EU", "flat.parquet"),
        ("year=2024/region=US", "flat.parquet"),
        ("year=2025/region=EU", "rowgroups.parquet"),
        ("year=2025/region=EU%20West", "truncated.parquet"),
    ]
    for (index, (dir, file)) in layout.enumerated() {
        let folder = root.appendingPathComponent(dir)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.copyItem(
            at: URL(fileURLWithPath: fixturesDir + "/" + file),
            to: folder.appendingPathComponent("part-\(index).parquet")
        )
    }
    try? Data("not parquet".utf8).write(to: root.appendingPathComponent("README.txt"))

    guard let all = ParquetDataset.summarize(at: root, maxFiles: 100, recursive: true, maxPartitionValuesPerKey: 25) else {
        assertTrue(false, "dataset summary should exist")
        return
    }
    assertEqual(all.fileCount, 4, "dataset: parquet files")
    assertEqual(all.validFileCount, 3, "dataset: valid files")
    assertEqual(all.totalRows, 3 + 3 + 1000, "dataset: total rows")
    assertTrue(!all.truncated, "dataset: not truncated")
    assertEqual(all.columns.map(\.name), ["id", "score", "name", "flag", "day", "ts", "amount", "n", "label"], "dataset: column union in first-seen order")
    assertEqual(all.partitionValuesByKey["year"] ?? [], ["2024", "2025"], "dataset: year partitions")
    assertEqual(all.partitionValuesByKey["region"] ?? [], ["EU", "US", "EU West"], "dataset: region partitions (decoded)")

    let capped = ParquetDataset.summarize(at: root, maxFiles: 2, recursive: true, maxPartitionValuesPerKey: 1)
    assertTrue(capped?.truncated ?? false, "dataset: scan truncated at maxFiles")
    assertEqual(capped?.validFileCount ?? -1, 2, "dataset: only maxFiles footers read")
    assertEqual(capped?.partitionValuesByKey["region"]?.count ?? -1, 1, "dataset: partition values capped per key")

    let flatOnly = ParquetDataset.summarize(at: root, maxFiles: 100, recursive: false, maxPartitionValuesPerKey: 25)
    assertTrue(flatOnly == nil, "dataset: non-recursive scan of a partitioned root finds no files")

    let empty = root.appendingPathComponent("empty")
    try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
    assertTrue(ParquetDataset.summarize(at: empty, maxFiles: 100, recursive: true, maxPartitionValuesPerKey: 25) == nil, "dataset: no parquet files -> nil")
}

@main
struct CoreTestsMain {
    static func main() {
        runCoreTests()
        if let fixtures = ProcessInfo.processInfo.environment["PARQUET_FIXTURES_DIR"] {
            runFooterFixtureTests(fixturesDir: fixtures)
        }
        print("PASS: core logic tests completed")
    }
}
