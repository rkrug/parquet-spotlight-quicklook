import Foundation

public protocol ParquetSystemAccess {
    func fileExists(atPath path: String) -> Bool
    func commandOutput(_ launchPath: String, _ arguments: [String]) -> String?
}

public struct ParquetStatusSnapshot {
    public let importerInstalled: Bool
    public let appInstalledInApplications: Bool
    public let quickLookBundlePresent: Bool

    public init(importerInstalled: Bool, appInstalledInApplications: Bool, quickLookBundlePresent: Bool) {
        self.importerInstalled = importerInstalled
        self.appInstalledInApplications = appInstalledInApplications
        self.quickLookBundlePresent = quickLookBundlePresent
    }
}

public struct ParquetStatusEvaluator {
    public let userImporterPath: String
    public let systemImporterPath: String
    public let appCandidatePaths: [String]
    public let quickLookAppexNames: [String]
    public let homeDirectory: String

    public init(
        userImporterPath: String,
        systemImporterPath: String,
        appCandidatePaths: [String],
        quickLookAppexNames: [String],
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.userImporterPath = userImporterPath
        self.systemImporterPath = systemImporterPath
        self.appCandidatePaths = appCandidatePaths
        self.quickLookAppexNames = quickLookAppexNames
        self.homeDirectory = homeDirectory
    }

    public func evaluate(using system: ParquetSystemAccess) -> ParquetStatusSnapshot {
        let appInstalled = appCandidatePaths.contains { candidate in
            system.fileExists(atPath: candidate) && isAppInApplications(candidate)
        }
        let quickLookPresent = appCandidatePaths.contains { candidate in
            hasEmbeddedQuickLookExtension(in: candidate, using: system)
        }
        let importerPresentOnDisk =
            system.fileExists(atPath: userImporterPath) || system.fileExists(atPath: systemImporterPath)
        let importerRegistered = isImporterRegistered(using: system)

        return ParquetStatusSnapshot(
            importerInstalled: importerPresentOnDisk || importerRegistered,
            appInstalledInApplications: appInstalled,
            quickLookBundlePresent: quickLookPresent
        )
    }

    public func isImporterRegistered(using system: ParquetSystemAccess) -> Bool {
        guard let out = system.commandOutput("/usr/bin/mdimport", ["-L"]) else {
            return false
        }
        return out.contains("Parquet.mdimporter")
    }

    public func isAppInApplications(_ appPath: String) -> Bool {
        let resolved = (appPath as NSString).resolvingSymlinksInPath
        let userApplications = (homeDirectory as NSString).appendingPathComponent("Applications") + "/"
        return resolved.hasPrefix("/Applications/") || resolved.hasPrefix(userApplications)
    }

    public func hasEmbeddedQuickLookExtension(in appPath: String, using system: ParquetSystemAccess) -> Bool {
        for appexName in quickLookAppexNames {
            let appexPath = (appPath as NSString).appendingPathComponent("Contents/PlugIns/\(appexName)")
            if system.fileExists(atPath: appexPath) {
                return true
            }
        }
        return false
    }
}
