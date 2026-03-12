import AppKit
import Foundation
import SwiftUI

private enum SidebarPane: String, Hashable {
    case status
    case settings
    case updates
}

private enum AppEvents {
    static let selectSidebarPane = Notification.Name("SelectSidebarPane")
    static let manualUpdateCheck = Notification.Name("ManualUpdateCheck")
}

private enum SettingsKeys {
    // Use the preview extension bundle identifier as settings domain so the
    // sandboxed extension can read values reliably.
    static let suite = "com.rkrug.parquetindexer.previewhost.preview"
    static let expandDepth = "expandDepth"
    static let showAllColumns = "showAllColumns"
    static let maxColumns = "maxColumns"
    static let showPhysicalType = "showPhysicalType"
    static let hideListElement = "hideListElement"
    static let scanAllFiles = "scanAllFiles"
    static let maxScanFiles = "maxScanFiles"
    static let recursiveScan = "recursiveScan"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let updateCheckInterval = "updateCheckInterval"
    static let lastUpdateCheckAt = "lastUpdateCheckAt"
    static let skippedUpdateVersion = "skippedUpdateVersion"
}

private enum UpdateCheckInterval: String, CaseIterable {
    case daily
    case weekly
    case monthly

    var seconds: TimeInterval {
        switch self {
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        }
    }

    var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

private struct StatusInfo {
    let importerInstalled: Bool
    let appInstalledInApplications: Bool
    let quickLookBundlePresent: Bool
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

private struct LiveSystemAccess: ParquetSystemAccess {
    let fileManager: FileManager
    let runOutput: (String, [String]) -> String?

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func commandOutput(_ launchPath: String, _ arguments: [String]) -> String? {
        runOutput(launchPath, arguments)
    }
}

private final class AppModel: ObservableObject {
    @Published var statusText = "Ready."
    @Published var importerInstalled = false
    @Published var appInstalledInApplications = false
    @Published var quickLookBundlePresent = false

    @Published var expandDepth = 1
    @Published var showAllColumns = true
    @Published var maxColumns = 500
    @Published var showPhysicalType = false
    @Published var hideListElement = true
    @Published var scanAllFiles = false
    @Published var maxScanFiles = 500
    @Published var recursiveScan = true
    @Published var autoCheckUpdates = true
    @Published var updateCheckInterval: UpdateCheckInterval = .daily
    @Published private(set) var recentErrors: [String] = []
    private let appDisplayName = "Parquet Quick Look and Index"
    private let maxRecentErrors = 20

    private struct GitHubLatestRelease: Decodable {
        let tag_name: String
        let html_url: String
    }

    private let fm = FileManager.default
    private let spotlightDst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Spotlight/Parquet.mdimporter")
    private let systemSpotlightDst = URL(fileURLWithPath: "/Library/Spotlight/Parquet.mdimporter")
    private let legacyQuickLookDst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/QuickLook/Parquet.qlgenerator")
    private let userAppDst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Parquet Quick Look and Index.app")
    private let systemAppDst = URL(fileURLWithPath: "/Applications/Parquet Quick Look and Index.app")
    private let legacyQuickViewUserAppDst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Parquet QuickView and Index.app")
    private let legacyQuickViewSystemAppDst = URL(fileURLWithPath: "/Applications/Parquet QuickView and Index.app")
    private let legacyUserAppDst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/ParquetPreviewHost.app")
    private let legacySystemAppDst = URL(fileURLWithPath: "/Applications/ParquetPreviewHost.app")
    private let quickLookAppexName = "ParquetQuickLook.appex"
    private let legacyQuickViewAppexName = "ParquetQuickView.appex"
    private let legacyPreviewAppexName = "ParquetPreview.appex"
    private let previewContainerSettings = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers/com.rkrug.parquetindexer.previewhost.preview/Data/Library/Application Support/ParquetPreview/settings.json")
    private let previewContainerRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers/com.rkrug.parquetindexer.previewhost.preview")
    private let previewSupportDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/ParquetPreview")
    private let previewCacheDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/com.rkrug.parquetindexer.previewhost.preview")
    private let updateValidator = ParquetUpdateValidator()
    private let releaseCheckURL = URL(string: "https://api.github.com/repos/rkrug/parquet-spotlight-quicklook/releases/latest")!

    init() {
        loadSettings()
        refreshStatus()
    }

    func setStatus(_ message: String, error: Bool = false) {
        statusText = message
        if error {
            appendError(message)
        }
    }

    func loadSettings() {
        if let data = try? Data(contentsOf: previewContainerSettings),
           let decoded = try? JSONDecoder().decode(PreviewSettingsData.self, from: data) {
            expandDepth = max(0, min(decoded.expandDepth, 10))
            showAllColumns = decoded.showAllColumns
            maxColumns = max(1, decoded.maxColumns)
            showPhysicalType = decoded.showPhysicalType
            hideListElement = decoded.hideListElement
            scanAllFiles = decoded.scanAllFiles
            maxScanFiles = max(1, decoded.maxScanFiles)
            recursiveScan = decoded.recursiveScan
            return
        }

        let defaults = UserDefaults(suiteName: SettingsKeys.suite) ?? .standard
        if defaults.object(forKey: SettingsKeys.expandDepth) == nil {
            defaults.set(1, forKey: SettingsKeys.expandDepth)
            defaults.set(true, forKey: SettingsKeys.showAllColumns)
            defaults.set(500, forKey: SettingsKeys.maxColumns)
            defaults.set(false, forKey: SettingsKeys.showPhysicalType)
            defaults.set(true, forKey: SettingsKeys.hideListElement)
            defaults.set(false, forKey: SettingsKeys.scanAllFiles)
            defaults.set(500, forKey: SettingsKeys.maxScanFiles)
            defaults.set(true, forKey: SettingsKeys.recursiveScan)
        }
        if defaults.object(forKey: SettingsKeys.autoCheckUpdates) == nil {
            defaults.set(true, forKey: SettingsKeys.autoCheckUpdates)
        }
        if defaults.object(forKey: SettingsKeys.updateCheckInterval) == nil {
            defaults.set(UpdateCheckInterval.daily.rawValue, forKey: SettingsKeys.updateCheckInterval)
        }
        expandDepth = defaults.integer(forKey: SettingsKeys.expandDepth)
        showAllColumns = defaults.bool(forKey: SettingsKeys.showAllColumns)
        let maxCols = defaults.integer(forKey: SettingsKeys.maxColumns)
        maxColumns = maxCols > 0 ? maxCols : 500
        showPhysicalType = defaults.bool(forKey: SettingsKeys.showPhysicalType)
        hideListElement = defaults.bool(forKey: SettingsKeys.hideListElement)
        scanAllFiles = defaults.bool(forKey: SettingsKeys.scanAllFiles)
        let maxScan = defaults.integer(forKey: SettingsKeys.maxScanFiles)
        maxScanFiles = maxScan > 0 ? maxScan : 500
        if defaults.object(forKey: SettingsKeys.recursiveScan) == nil {
            recursiveScan = true
        } else {
            recursiveScan = defaults.bool(forKey: SettingsKeys.recursiveScan)
        }
        if defaults.object(forKey: SettingsKeys.autoCheckUpdates) == nil {
            autoCheckUpdates = true
        } else {
            autoCheckUpdates = defaults.bool(forKey: SettingsKeys.autoCheckUpdates)
        }
        if let raw = defaults.string(forKey: SettingsKeys.updateCheckInterval),
           let interval = UpdateCheckInterval(rawValue: raw) {
            updateCheckInterval = interval
        } else {
            updateCheckInterval = .daily
        }
    }

    func saveSettings() {
        let defaults = UserDefaults(suiteName: SettingsKeys.suite) ?? .standard
        let normalizedExpandDepth = max(0, min(expandDepth, 10))
        let normalizedMaxColumns = max(1, maxColumns)
        let normalizedMaxScanFiles = max(1, maxScanFiles)

        defaults.set(normalizedExpandDepth, forKey: SettingsKeys.expandDepth)
        defaults.set(showAllColumns, forKey: SettingsKeys.showAllColumns)
        defaults.set(normalizedMaxColumns, forKey: SettingsKeys.maxColumns)
        defaults.set(showPhysicalType, forKey: SettingsKeys.showPhysicalType)
        defaults.set(hideListElement, forKey: SettingsKeys.hideListElement)
        defaults.set(scanAllFiles, forKey: SettingsKeys.scanAllFiles)
        defaults.set(normalizedMaxScanFiles, forKey: SettingsKeys.maxScanFiles)
        defaults.set(recursiveScan, forKey: SettingsKeys.recursiveScan)
        defaults.set(autoCheckUpdates, forKey: SettingsKeys.autoCheckUpdates)
        defaults.set(updateCheckInterval.rawValue, forKey: SettingsKeys.updateCheckInterval)

        let payload = PreviewSettingsData(
            expandDepth: normalizedExpandDepth,
            showAllColumns: showAllColumns,
            maxColumns: normalizedMaxColumns,
            showPhysicalType: showPhysicalType,
            hideListElement: hideListElement,
            scanAllFiles: scanAllFiles,
            maxScanFiles: normalizedMaxScanFiles,
            recursiveScan: recursiveScan
        )
        if let data = try? JSONEncoder().encode(payload) {
            let dir = previewContainerSettings.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: previewContainerSettings, options: .atomic)
        }

        run("/usr/bin/qlmanage", ["-r"])
        run("/usr/bin/qlmanage", ["-r", "cache"])
        setStatus("Settings saved. Reopen Quick Look to apply.")
    }

    func resetSettings() {
        expandDepth = 1
        showAllColumns = true
        maxColumns = 500
        showPhysicalType = false
        hideListElement = true
        scanAllFiles = false
        maxScanFiles = 500
        recursiveScan = true
        autoCheckUpdates = true
        updateCheckInterval = .daily
        saveSettings()
    }

    func autoCheckForUpdatesIfNeeded() {
        checkForUpdates(manual: false)
    }

    func checkForUpdates(manual: Bool) {
        let defaults = UserDefaults(suiteName: SettingsKeys.suite) ?? .standard
        let now = Date().timeIntervalSince1970
        if !manual {
            guard autoCheckUpdates else { return }
            let last = defaults.double(forKey: SettingsKeys.lastUpdateCheckAt)
            if last > 0, (now - last) < updateCheckInterval.seconds {
                return
            }
        }
        defaults.set(now, forKey: SettingsKeys.lastUpdateCheckAt)

        var request = URLRequest(url: releaseCheckURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ParquetQuickLookAndIndex", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async {
                    if manual {
                        self.showUpdateErrorDialog(ParquetUpdateErrorMapper.describeNetworkError(error))
                    }
                }
                return
            }

            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    if manual {
                        self.showUpdateErrorDialog("Could not check for updates: invalid server response.")
                    }
                }
                return
            }

            guard self.updateValidator.isTrustedReleaseAPIResponseURL(http.url) else {
                DispatchQueue.main.async {
                    if manual {
                        self.showUpdateErrorDialog("Could not check for updates: response origin was not trusted.")
                    }
                }
                return
            }

            guard (200...299).contains(http.statusCode) else {
                DispatchQueue.main.async {
                    if manual {
                        self.showUpdateErrorDialog(ParquetUpdateErrorMapper.describeHTTPError(statusCode: http.statusCode, data: data))
                    }
                }
                return
            }

            guard let data else {
                DispatchQueue.main.async {
                    if manual {
                        self.showUpdateErrorDialog("Could not check for updates: empty server response.")
                    }
                }
                return
            }

            guard let release = try? JSONDecoder().decode(GitHubLatestRelease.self, from: data) else {
                DispatchQueue.main.async {
                    if manual { self.showUpdateErrorDialog("Could not parse release information.") }
                }
                return
            }

            guard let latestVersion = ParquetSemVer(strictTag: release.tag_name) else {
                DispatchQueue.main.async {
                    if manual {
                        self.showUpdateErrorDialog("Could not check for updates: latest release tag is not valid semver (expected vX.Y.Z).")
                    }
                }
                return
            }

            let currentVersion = ParquetSemVer(looseVersion: self.currentVersion()) ?? .zero
            let skippedVersion = defaults.string(forKey: SettingsKeys.skippedUpdateVersion) ?? ""

            if latestVersion > currentVersion {
                if !manual && latestVersion.normalized == skippedVersion {
                    return
                }
                guard let releaseURL = URL(string: release.html_url) else {
                    DispatchQueue.main.async {
                        if manual { self.showUpdateErrorDialog("Latest release URL is invalid.") }
                    }
                    return
                }
                guard self.updateValidator.isTrustedReleasePageURL(releaseURL, expectedTag: release.tag_name) else {
                    DispatchQueue.main.async {
                        if manual {
                            self.showUpdateErrorDialog("Could not check for updates: latest release page URL is not trusted.")
                        }
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.showUpdateAvailableDialog(version: "v\(latestVersion.normalized)", skippedVersion: latestVersion.normalized, url: releaseURL)
                }
            } else if manual {
                DispatchQueue.main.async {
                    self.showUpToDateDialog()
                }
            }
        }.resume()
    }

    private func showUpdateAvailableDialog(version: String, skippedVersion: String, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "New Version Available"
        alert.informativeText = "\(appDisplayName) (\(currentVersion())) can be updated to \(version)."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Skip this version")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(url)
        case .alertSecondButtonReturn:
            let defaults = UserDefaults(suiteName: SettingsKeys.suite) ?? .standard
            defaults.set(skippedVersion, forKey: SettingsKeys.skippedUpdateVersion)
        default:
            break
        }
    }

    private func showUpToDateDialog() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "No Updates Available"
        alert.informativeText = "\(appDisplayName) (\(currentVersion())) is up to date."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showUpdateErrorDialog(_ message: String) {
        appendError(message)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func currentVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    func refreshStatus() {
        let appCandidatePaths = candidateAppBundles().map(\.path)
        let evaluator = ParquetStatusEvaluator(
            userImporterPath: spotlightDst.path,
            systemImporterPath: systemSpotlightDst.path,
            appCandidatePaths: appCandidatePaths,
            quickLookAppexNames: [quickLookAppexName, legacyQuickViewAppexName, legacyPreviewAppexName]
        )
        let system = LiveSystemAccess(
            fileManager: fm,
            runOutput: { [weak self] launchPath, args in
                self?.runOutput(launchPath, args)
            }
        )
        let info = evaluator.evaluate(using: system)
        let statusInfo = StatusInfo(
            importerInstalled: info.importerInstalled,
            appInstalledInApplications: info.appInstalledInApplications,
            quickLookBundlePresent: info.quickLookBundlePresent
        )
        importerInstalled = statusInfo.importerInstalled
        appInstalledInApplications = statusInfo.appInstalledInApplications
        quickLookBundlePresent = statusInfo.quickLookBundlePresent
    }

    func install() {
        guard let bundledImporter = Bundle.main.url(forResource: "Parquet", withExtension: "mdimporter") else {
            setStatus("Install failed: bundled importer missing.", error: true)
            return
        }

        do {
            let spotlightDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Spotlight")
            let appsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
            try fm.createDirectory(at: spotlightDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)

            if fm.fileExists(atPath: spotlightDst.path) {
                try fm.removeItem(at: spotlightDst)
            }
            try fm.copyItem(at: bundledImporter, to: spotlightDst)

            run("/usr/bin/xattr", ["-cr", spotlightDst.path])
            registerAndRefresh()
            refreshStatus()
            setStatus("Install complete.")
        } catch {
            setStatus("Install failed: \(error.localizedDescription)", error: true)
        }
    }

    func autoInstallImporterIfMissing() {
        refreshStatus()
        guard !importerInstalled else { return }
        install()
        refreshStatus()
        if importerInstalled {
            setStatus("Spotlight importer auto-installed.")
        }
    }

    func repair() {
        registerAndRefresh()
        refreshStatus()
        setStatus("Repair actions completed.")
    }

    func uninstall() {
        do {
            for app in candidateAppBundles() {
                for appexName in [quickLookAppexName, legacyQuickViewAppexName, legacyPreviewAppexName] {
                    let appex = app.appendingPathComponent("Contents/PlugIns/\(appexName)")
                    if fm.fileExists(atPath: appex.path) {
                        run("/usr/bin/pluginkit", ["-r", appex.path])
                    }
                }
            }
            if fm.fileExists(atPath: spotlightDst.path) {
                try fm.removeItem(at: spotlightDst)
            }
            if fm.fileExists(atPath: legacyQuickLookDst.path) {
                try fm.removeItem(at: legacyQuickLookDst)
            }
            if fm.fileExists(atPath: previewContainerSettings.path) {
                try? fm.removeItem(at: previewContainerSettings)
            }
            if fm.fileExists(atPath: previewSupportDir.path) {
                try? fm.removeItem(at: previewSupportDir)
            }
            if fm.fileExists(atPath: previewCacheDir.path) {
                try? fm.removeItem(at: previewCacheDir)
            }
            if fm.fileExists(atPath: previewContainerRoot.path) {
                try? fm.removeItem(at: previewContainerRoot)
                // Container roots may be protected by containermanager.
                // Remove the Data subtree as a best effort so settings do not persist.
                let dataDir = previewContainerRoot.appendingPathComponent("Data")
                if fm.fileExists(atPath: dataDir.path) {
                    try? fm.removeItem(at: dataDir)
                }
            }
            UserDefaults.standard.removePersistentDomain(forName: SettingsKeys.suite)
            run("/usr/bin/defaults", ["delete", SettingsKeys.suite])

            run("/usr/bin/qlmanage", ["-r"])
            run("/usr/bin/qlmanage", ["-r", "cache"])
            run("/usr/bin/killall", ["quicklookd", "QuickLookUIService", "Finder"])

            // Remove this app asynchronously after termination.
            let appPath = Bundle.main.bundleURL.path.replacingOccurrences(of: "\"", with: "\\\"")
            run("/bin/sh", ["-lc", "(sleep 1; rm -rf \"\(appPath)\") >/dev/null 2>&1 &"])
            setStatus("Uninstall complete. App will close.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            setStatus("Uninstall failed: \(error.localizedDescription)", error: true)
        }
    }

    private func registerAndRefresh() {
        if fm.fileExists(atPath: spotlightDst.path) {
            run("/usr/bin/mdimport", ["-r", spotlightDst.path])
        }
        if fm.fileExists(atPath: systemSpotlightDst.path) {
            run("/usr/bin/mdimport", ["-r", systemSpotlightDst.path])
        }
        for appBundle in registrationAppBundles() {
            for appexName in [quickLookAppexName, legacyQuickViewAppexName, legacyPreviewAppexName] {
                let appex = appBundle.appendingPathComponent("Contents/PlugIns/\(appexName)")
                if fm.fileExists(atPath: appex.path) {
                    run("/usr/bin/pluginkit", ["-a", appex.path])
                }
            }
        }
        run("/usr/bin/qlmanage", ["-r"])
        run("/usr/bin/qlmanage", ["-r", "cache"])
    }

    private func isImporterRegistered() -> Bool {
        guard let out = runOutput("/usr/bin/mdimport", ["-L"]) else {
            return false
        }
        return out.contains("Parquet.mdimporter")
    }

    private func registrationAppBundles() -> [URL] {
        // Prefer stable installed app locations first, then fall back to the currently running bundle.
        let candidates = [
            userAppDst,
            systemAppDst,
            legacyQuickViewUserAppDst,
            legacyQuickViewSystemAppDst,
            legacyUserAppDst,
            legacySystemAppDst,
            Bundle.main.bundleURL,
        ]
        var seen = Set<String>()
        return candidates.filter {
            let path = $0.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return fm.fileExists(atPath: path)
        }
    }

    private func candidateAppBundles() -> [URL] {
        let candidates = [
            Bundle.main.bundleURL,
            userAppDst,
            systemAppDst,
            legacyQuickViewUserAppDst,
            legacyQuickViewSystemAppDst,
            legacyUserAppDst,
            legacySystemAppDst,
        ]
        var seen = Set<String>()
        return candidates.filter {
            let path = $0.path
            if seen.contains(path) { return false }
            seen.insert(path)
            return true
        }
    }

    private func hasEmbeddedQuickLookExtension(in appBundle: URL) -> Bool {
        let quickLook = appBundle.appendingPathComponent("Contents/PlugIns/\(quickLookAppexName)")
        if fm.fileExists(atPath: quickLook.path) {
            return true
        }
        let quickView = appBundle.appendingPathComponent("Contents/PlugIns/\(legacyQuickViewAppexName)")
        if fm.fileExists(atPath: quickView.path) {
            return true
        }
        let legacy = appBundle.appendingPathComponent("Contents/PlugIns/\(legacyPreviewAppexName)")
        return fm.fileExists(atPath: legacy.path)
    }

    private func isAppInApplications(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        if !fm.fileExists(atPath: resolved.path) {
            return false
        }
        let userApplications = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications").path + "/"
        return resolved.path.hasPrefix("/Applications/") || resolved.path.hasPrefix(userApplications)
    }

    func copyDiagnosticReport() {
        let report = diagnosticReport()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        setStatus("Diagnostic report copied to clipboard.")
    }

    private func diagnosticReport() -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let current = currentVersion()
        let extensionVersion = embeddedQuickLookVersion()
        let importerVersion = embeddedImporterVersion()
        let appPath = anonymizePath(Bundle.main.bundleURL.path)
        let importerUserPath = anonymizePath(spotlightDst.path)
        let importerSystemPath = anonymizePath(systemSpotlightDst.path)
        let qlFromMain = anonymizePath(Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/\(quickLookAppexName)").path)
        let mdimportList = filteredCommandSnapshot("/usr/bin/mdimport", ["-L"], includePatterns: ["parquet", "mdimporter"])
        let pluginkitList = filteredCommandSnapshot("/usr/bin/pluginkit", ["-m", "-A"], includePatterns: ["parquet", "quicklook", "quick look", "qlgenerator"])
        let qlList = filteredCommandSnapshot("/usr/bin/qlmanage", ["-m", "plugins"], includePatterns: ["parquet", "quicklook", "quick look", "qlgenerator"])

        let bundleCandidates = candidateAppBundles().map { bundle -> String in
            let exists = fm.fileExists(atPath: bundle.path)
            let inApps = isAppInApplications(bundle)
            let hasExt = hasEmbeddedQuickLookExtension(in: bundle)
            return "- \(anonymizePath(bundle.path)) | exists=\(exists) | inApplications=\(inApps) | hasQuickLookExt=\(hasExt)"
        }.joined(separator: "\n")

        let errors = recentErrors.isEmpty
            ? "- (none)"
            : recentErrors.map { "- \($0)" }.joined(separator: "\n")

        let text = """
        # Parquet Quick Look and Index Diagnostics
        Generated: \(now)

        ## App
        - appVersion: \(current)
        - extensionVersion: \(extensionVersion)
        - importerVersion: \(importerVersion)
        - appBundlePath: \(appPath)

        ## Status Snapshot
        - importerInstalled: \(importerInstalled)
        - appInstalledInApplications: \(appInstalledInApplications)
        - quickLookBundlePresent: \(quickLookBundlePresent)
        - statusText: \(statusText)

        ## Important Paths
        - userImporterPath: \(importerUserPath) (exists: \(fm.fileExists(atPath: spotlightDst.path)))
        - systemImporterPath: \(importerSystemPath) (exists: \(fm.fileExists(atPath: systemSpotlightDst.path)))
        - mainQuickLookAppexPath: \(qlFromMain) (exists: \(fm.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/\(quickLookAppexName)").path)))

        ## App Bundle Candidates
        \(bundleCandidates)

        ## Registration Snapshots
        ### mdimport -L (filtered)
        \(mdimportList)

        ### pluginkit -m -A (filtered)
        \(pluginkitList)

        ### qlmanage -m plugins (filtered)
        \(qlList)

        ## Settings
        - expandDepth: \(expandDepth)
        - showAllColumns: \(showAllColumns)
        - maxColumns: \(maxColumns)
        - showPhysicalType: \(showPhysicalType)
        - hideListElement: \(hideListElement)
        - scanAllFiles: \(scanAllFiles)
        - maxScanFiles: \(maxScanFiles)
        - recursiveScan: \(recursiveScan)
        - autoCheckUpdates: \(autoCheckUpdates)
        - updateCheckInterval: \(updateCheckInterval.rawValue)

        ## Recent Errors
        \(errors)
        """
        return sanitizeForDiagnostics(text)
    }

    private func filteredCommandSnapshot(_ launchPath: String, _ arguments: [String], includePatterns: [String]) -> String {
        guard let captured = runCapture(launchPath, arguments) else {
            return "(command failed to run)"
        }
        let combined = ([captured.stdout, captured.stderr].joined(separator: "\n"))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let needles = includePatterns.map { $0.lowercased() }
        let filtered = combined.filter { line in
            let l = line.lowercased()
            return needles.contains { l.contains($0) }
        }

        if filtered.isEmpty {
            return "(no parquet-related entries found)"
        }
        let clipped = filtered.prefix(120).joined(separator: "\n")
        return clipped
    }

    private func embeddedQuickLookVersion() -> String {
        let appexInfo = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/\(quickLookAppexName)/Contents/Info.plist")
        return bundleVersionString(fromInfoPlistAt: appexInfo) ?? "unknown"
    }

    private func embeddedImporterVersion() -> String {
        let importerInfo = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Parquet.mdimporter/Contents/Info.plist")
        return bundleVersionString(fromInfoPlistAt: importerInfo) ?? "unknown"
    }

    private func bundleVersionString(fromInfoPlistAt url: URL) -> String? {
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            return nil
        }
        if let short = dict["CFBundleShortVersionString"] as? String {
            return short
        }
        return dict["CFBundleVersion"] as? String
    }

    private func appendError(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamped = "[\(formatter.string(from: Date()))] \(message)"
        recentErrors.append(sanitizeForDiagnostics(stamped))
        if recentErrors.count > maxRecentErrors {
            recentErrors.removeFirst(recentErrors.count - maxRecentErrors)
        }
    }

    private func anonymizePath(_ path: String) -> String {
        ParquetDiagnosticsSanitizer.anonymizePath(path)
    }

    private func sanitizeForDiagnostics(_ raw: String) -> String {
        ParquetDiagnosticsSanitizer.sanitize(raw)
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        do {
            try p.run()
            p.waitUntilExit()
            let status = p.terminationStatus
            if status != 0 {
                appendError("Command failed (\(status)): \(launchPath) \(arguments.joined(separator: " "))")
            }
            return status
        } catch {
            appendError("Command launch failed: \(launchPath) (\(error.localizedDescription))")
            return -1
        }
    }

    private func runOutput(_ launchPath: String, _ arguments: [String]) -> String? {
        guard let captured = runCapture(launchPath, arguments) else {
            return nil
        }
        return captured.stdout
    }

    private func runCapture(_ launchPath: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String)? {
        let p = Process()
        let out = Pipe()
        let err = Pipe()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let status = p.terminationStatus
            if status != 0 {
                let errMsg = stderr.isEmpty ? stdout : stderr
                let snippet = errMsg.split(separator: "\n").prefix(1).joined(separator: "\n")
                appendError("Command failed (\(status)): \(launchPath) \(arguments.joined(separator: " ")) \(snippet)")
            }
            return (status: status, stdout: stdout, stderr: stderr)
        } catch {
            appendError("Command launch failed: \(launchPath) (\(error.localizedDescription))")
            return nil
        }
    }
}

private struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SidebarPane? = .status
    @State private var showUninstallConfirm = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Status", systemImage: "checkmark.shield")
                    .tag(SidebarPane.status)
                Label("Quick Look Settings", systemImage: "slider.horizontal.3")
                    .tag(SidebarPane.settings)
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    .tag(SidebarPane.updates)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            Group {
                switch selection ?? .status {
                case .status:
                    statusPane
                case .settings:
                    settingsPane
                case .updates:
                    updatesPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(18)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: AppEvents.selectSidebarPane)) { note in
            guard
                let raw = note.userInfo?["pane"] as? String,
                let pane = SidebarPane(rawValue: raw)
            else { return }
            selection = pane
        }
        .onReceive(NotificationCenter.default.publisher(for: AppEvents.manualUpdateCheck)) { _ in
            model.checkForUpdates(manual: true)
        }
    }

    private var statusPane: some View {
        Form {
            Section("Component Status") {
                statusRow("Spotlight importer", model.importerInstalled)
                statusRow("Manager app in /Applications or ~/Applications", model.appInstalledInApplications)
                statusRow("Quick Look extension", model.quickLookBundlePresent)
            }

            Section("Current Message") {
                Text(model.statusText).foregroundStyle(.secondary)
            }

            Section("Actions") {
                HStack(spacing: 10) {
                    Button("Re-Install") { model.install() }
                        .buttonStyle(.borderedProminent)
                    Button("Repair Registration") { model.repair() }
                        .buttonStyle(.bordered)
                    Button("Refresh Status") { model.refreshStatus() }
                        .buttonStyle(.bordered)
                    Button("Copy Diagnostic Report") { model.copyDiagnosticReport() }
                        .buttonStyle(.bordered)
                }
            }

            Section("Recent Errors") {
                if model.recentErrors.isEmpty {
                    Text("No recent errors captured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.recentErrors.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Danger Zone") {
                Text("Uninstall removes the importer and Quick Look app from user locations. Finder will be restarted to unregister Quick Look plugins.")
                    .foregroundStyle(.secondary)
                Button("Uninstall") { showUninstallConfirm = true }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Status")
        .confirmationDialog(
            "Are you sure that you want to uninstall Parquet Quick Look and Index?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                model.uninstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove installed components from user locations and restart Finder.")
        }
    }

    private var settingsPane: some View {
        Form {
            Section("Schema Display") {
                HStack {
                    Text("Default expand depth")
                    Spacer()
                    Stepper(value: $model.expandDepth, in: 0...10) { EmptyView() }
                        .labelsHidden()
                    Text("\(model.expandDepth)")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }

                Toggle("Show all columns", isOn: $model.showAllColumns)

                HStack {
                    Text("Max columns (if not all)")
                        .foregroundStyle(model.showAllColumns ? .secondary : .primary)
                    Spacer()
                    Stepper(value: $model.maxColumns, in: 1...20000, step: 50) { EmptyView() }
                        .labelsHidden()
                    Text("\(model.maxColumns)")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                        .foregroundStyle(model.showAllColumns ? .secondary : .primary)
                }
                .disabled(model.showAllColumns)

                Toggle("Show physical type next to logical type", isOn: $model.showPhysicalType)
                Toggle("Hide path tokens (list/element)", isOn: $model.hideListElement)
            }

            Section("Dataset Scanning") {
                Toggle("Scan all files", isOn: $model.scanAllFiles)

                HStack {
                    Text("Max files (if not all)")
                        .foregroundStyle(model.scanAllFiles ? .secondary : .primary)
                    Spacer()
                    Stepper(value: $model.maxScanFiles, in: 1...50000, step: 100) { EmptyView() }
                        .labelsHidden()
                    Text("\(model.maxScanFiles)")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                        .foregroundStyle(model.scanAllFiles ? .secondary : .primary)
                }
                .disabled(model.scanAllFiles)

                Toggle("Recursive scan folders", isOn: $model.recursiveScan)
            }

            Section {
                HStack {
                    Button("Apply Settings") { model.saveSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Reset Defaults") { model.resetSettings() }
                        .buttonStyle(.bordered)
                }
                Text("Saved settings apply to new Quick Look windows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Quick Look Settings")
    }

    private var updatesPane: some View {
        Form {
            Section("Update Checks") {
                Toggle("Auto-check updates", isOn: $model.autoCheckUpdates)
                Picker("Check interval", selection: $model.updateCheckInterval) {
                    ForEach(UpdateCheckInterval.allCases, id: \.rawValue) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .disabled(!model.autoCheckUpdates)
                Button("Check for Updates Now") {
                    model.checkForUpdates(manual: true)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Updates")
    }

    private func statusRow(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let model = AppModel()
    private let appName = "Parquet Quick Look and Index"
    private let issuesURL = URL(string: "https://github.com/rkrug/parquet-spotlight-quicklook/issues/new/choose")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = ContentView(model: model)
        let hosting = NSHostingView(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "\(appName) Manager"
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        setupMenu()
        DispatchQueue.main.async { [weak self] in
            self?.model.autoInstallImporterIfMissing()
            self?.model.autoCheckForUpdatesIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func openSettings(_ sender: Any?) {
        NotificationCenter.default.post(
            name: AppEvents.selectSidebarPane,
            object: nil,
            userInfo: ["pane": SidebarPane.settings.rawValue]
        )
        showMainWindow()
    }

    @objc private func openNews(_ sender: Any?) {
        if let bundledNews = Bundle.main.url(forResource: "NEWS", withExtension: "md") {
            NSWorkspace.shared.open(bundledNews)
        } else {
            model.setStatus("Could not open NEWS.md (missing from app bundle).", error: true)
            showMainWindow()
        }
    }

    @objc private func openIssueTracker(_ sender: Any?) {
        NSWorkspace.shared.open(issuesURL)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        NotificationCenter.default.post(name: AppEvents.manualUpdateCheck, object: nil)
    }

    private func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.title = appName
        mainMenu.addItem(appItem)

        let appMenu = NSMenu(title: appName)
        let aboutItem = NSMenuItem(
            title: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        let updatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = self
        appMenu.addItem(updatesItem)
        appMenu.addItem(NSMenuItem.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(
            NSMenuItem(
                title: "Hide \(appName)",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"
            )
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            NSMenuItem(
                title: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""
            )
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit \(appName)",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            NSMenuItem(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
        )
        windowMenu.addItem(
            NSMenuItem(
                title: "Zoom",
                action: #selector(NSWindow.performZoom(_:)),
                keyEquivalent: ""
            )
        )
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(
            NSMenuItem(
                title: "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)),
                keyEquivalent: ""
            )
        )
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let newsItem = NSMenuItem(title: "News", action: #selector(openNews(_:)), keyEquivalent: "")
        newsItem.target = self
        helpMenu.addItem(newsItem)
        let issuesItem = NSMenuItem(title: "Report Issue or Send Feedback...", action: #selector(openIssueTracker(_:)), keyEquivalent: "")
        issuesItem.target = self
        helpMenu.addItem(issuesItem)
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}

@main
final class ParquetQuickLookAndIndexMain: NSObject {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
