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
}

@main
struct CoreTestsMain {
    static func main() {
        runCoreTests()
        print("PASS: core logic tests completed")
    }
}
