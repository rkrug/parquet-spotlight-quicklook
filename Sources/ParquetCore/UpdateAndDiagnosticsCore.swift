import Foundation

public struct ParquetSemVer: Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static let zero = ParquetSemVer(major: 0, minor: 0, patch: 0)

    public init?(looseVersion value: String) {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("v") || raw.hasPrefix("V") {
            raw.removeFirst()
        }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard
            let major = Int(parts[0]),
            let minor = Int(parts[1]),
            let patch = Int(parts[2])
        else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(strictTag value: String) {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("v") else { return nil }
        guard !raw.contains("-"), !raw.contains("+") else { return nil }
        self.init(looseVersion: String(raw.dropFirst()))
    }

    public var normalized: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: ParquetSemVer, rhs: ParquetSemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct ParquetUpdateValidator {
    public let expectedGitHubHost: String
    public let expectedGitHubAPIHost: String
    public let expectedRepoPath: String
    public let expectedReleasesLatestPath: String

    public init(
        expectedGitHubHost: String = "github.com",
        expectedGitHubAPIHost: String = "api.github.com",
        expectedRepoPath: String = "/rkrug/parquet-spotlight-quicklook",
        expectedReleasesLatestPath: String = "/repos/rkrug/parquet-spotlight-quicklook/releases/latest"
    ) {
        self.expectedGitHubHost = expectedGitHubHost
        self.expectedGitHubAPIHost = expectedGitHubAPIHost
        self.expectedRepoPath = expectedRepoPath
        self.expectedReleasesLatestPath = expectedReleasesLatestPath
    }

    public func isTrustedReleaseAPIResponseURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.host?.lowercased() == expectedGitHubAPIHost else { return false }
        return normalizedPath(url.path) == expectedReleasesLatestPath
    }

    public func isTrustedReleasePageURL(_ url: URL, expectedTag: String) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.host?.lowercased() == expectedGitHubHost else { return false }
        let expectedPath = "\(expectedRepoPath)/releases/tag/\(expectedTag)"
        return normalizedPath(url.path) == expectedPath
    }

    public func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

public enum ParquetUpdateErrorMapper {
    public static func describeNetworkError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Could not check for updates: you appear to be offline."
            case .timedOut:
                return "Could not check for updates: request timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Could not check for updates: cannot reach GitHub."
            default:
                return "Could not check for updates: \(urlError.localizedDescription)"
            }
        }
        return "Could not check for updates: \(error.localizedDescription)"
    }

    public static func describeHTTPError(statusCode: Int, data: Data?) -> String {
        let apiMessage = decodeGitHubErrorMessage(data)
        switch statusCode {
        case 403:
            if let apiMessage, !apiMessage.isEmpty {
                return "Could not check for updates: GitHub access was denied (\(apiMessage))."
            }
            return "Could not check for updates: GitHub API rate limit or access denied (HTTP 403)."
        case 404:
            return "Could not check for updates: release endpoint not found (HTTP 404)."
        case 429:
            return "Could not check for updates: too many requests (HTTP 429)."
        default:
            if let apiMessage, !apiMessage.isEmpty {
                return "Could not check for updates: HTTP \(statusCode) (\(apiMessage))."
            }
            return "Could not check for updates: HTTP \(statusCode)."
        }
    }

    private struct GitHubErrorResponse: Decodable {
        let message: String
    }

    private static func decodeGitHubErrorMessage(_ data: Data?) -> String? {
        guard let data else { return nil }
        guard let decoded = try? JSONDecoder().decode(GitHubErrorResponse.self, from: data) else {
            return nil
        }
        return decoded.message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ParquetDiagnosticsSanitizer {
    public static func anonymizePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        var output = path
        if output.hasPrefix(home) {
            output = "~" + output.dropFirst(home.count)
        }
        output = output.replacingOccurrences(
            of: "/Users/[^/\\s]+",
            with: "/Users/<user>",
            options: .regularExpression
        )
        return output
    }

    public static func sanitize(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(
            of: "/Users/[^/\\s]+",
            with: "/Users/<user>",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b",
            with: "<redacted-email>",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "\\b(ghp|github_pat)_[A-Za-z0-9_]+\\b",
            with: "<redacted-token>",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?i)\\b(api[_-]?key|token|password|secret)\\s*[:=]\\s*[^\\s,;]+",
            with: "$1=<redacted>",
            options: .regularExpression
        )
        return text
    }
}
