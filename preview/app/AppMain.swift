import AppKit
import Foundation
import SwiftUI

private enum SidebarPane: String, Hashable {
    case status
    case actions
    case settings
}

private enum AppEvents {
    static let selectSidebarPane = Notification.Name("SelectSidebarPane")
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

    private let fm = FileManager.default
    private let spotlightDst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Spotlight/Parquet.mdimporter")
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

    init() {
        loadSettings()
        refreshStatus()
    }

    func loadSettings() {
        if let data = try? Data(contentsOf: previewContainerSettings),
           let decoded = try? JSONDecoder().decode(PreviewSettingsData.self, from: data) {
            expandDepth = max(0, min(decoded.expandDepth, 10))
            showAllColumns = decoded.showAllColumns
            maxColumns = max(1, decoded.maxColumns)
            showPhysicalType = decoded.showPhysicalType
            hideListElement = decoded.hideListElement
            return
        }

        let defaults = UserDefaults(suiteName: SettingsKeys.suite) ?? .standard
        if defaults.object(forKey: SettingsKeys.expandDepth) == nil {
            defaults.set(1, forKey: SettingsKeys.expandDepth)
            defaults.set(true, forKey: SettingsKeys.showAllColumns)
            defaults.set(500, forKey: SettingsKeys.maxColumns)
            defaults.set(false, forKey: SettingsKeys.showPhysicalType)
            defaults.set(true, forKey: SettingsKeys.hideListElement)
        }
        expandDepth = defaults.integer(forKey: SettingsKeys.expandDepth)
        showAllColumns = defaults.bool(forKey: SettingsKeys.showAllColumns)
        let maxCols = defaults.integer(forKey: SettingsKeys.maxColumns)
        maxColumns = maxCols > 0 ? maxCols : 500
        showPhysicalType = defaults.bool(forKey: SettingsKeys.showPhysicalType)
        hideListElement = defaults.bool(forKey: SettingsKeys.hideListElement)
    }

    func saveSettings() {
        let defaults = UserDefaults(suiteName: SettingsKeys.suite) ?? .standard
        let normalizedExpandDepth = max(0, min(expandDepth, 10))
        let normalizedMaxColumns = max(1, maxColumns)

        defaults.set(normalizedExpandDepth, forKey: SettingsKeys.expandDepth)
        defaults.set(showAllColumns, forKey: SettingsKeys.showAllColumns)
        defaults.set(normalizedMaxColumns, forKey: SettingsKeys.maxColumns)
        defaults.set(showPhysicalType, forKey: SettingsKeys.showPhysicalType)
        defaults.set(hideListElement, forKey: SettingsKeys.hideListElement)

        let payload = PreviewSettingsData(
            expandDepth: normalizedExpandDepth,
            showAllColumns: showAllColumns,
            maxColumns: normalizedMaxColumns,
            showPhysicalType: showPhysicalType,
            hideListElement: hideListElement
        )
        if let data = try? JSONEncoder().encode(payload) {
            let dir = previewContainerSettings.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: previewContainerSettings, options: .atomic)
        }

        run("/usr/bin/qlmanage", ["-r"])
        run("/usr/bin/qlmanage", ["-r", "cache"])
        statusText = "Settings saved. Reopen Quick Look to apply."
    }

    func resetSettings() {
        expandDepth = 1
        showAllColumns = true
        maxColumns = 500
        showPhysicalType = false
        hideListElement = true
        saveSettings()
    }

    func refreshStatus() {
        let appCandidates = candidateAppBundles()
        let appInApplications = appCandidates.contains { isAppInApplications($0) }
        let quickLookPresent = appCandidates.contains {
            hasEmbeddedQuickLookExtension(in: $0)
        }
        let info = StatusInfo(
            importerInstalled: fm.fileExists(atPath: spotlightDst.path),
            appInstalledInApplications: appInApplications,
            quickLookBundlePresent: quickLookPresent
        )
        importerInstalled = info.importerInstalled
        appInstalledInApplications = info.appInstalledInApplications
        quickLookBundlePresent = info.quickLookBundlePresent
    }

    func install() {
        guard let bundledImporter = Bundle.main.url(forResource: "Parquet", withExtension: "mdimporter") else {
            statusText = "Install failed: bundled importer missing."
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
            statusText = "Install complete."
        } catch {
            statusText = "Install failed: \(error.localizedDescription)"
        }
    }

    func repair() {
        registerAndRefresh()
        refreshStatus()
        statusText = "Repair actions completed."
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

            run("/usr/bin/qlmanage", ["-r"])
            run("/usr/bin/qlmanage", ["-r", "cache"])
            run("/usr/bin/killall", ["quicklookd", "QuickLookUIService", "Finder"])

            // Remove this app asynchronously after termination.
            let appPath = Bundle.main.bundleURL.path.replacingOccurrences(of: "\"", with: "\\\"")
            run("/bin/sh", ["-lc", "(sleep 1; rm -rf \"\(appPath)\") >/dev/null 2>&1 &"])
            statusText = "Uninstall complete. App will close."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        } catch {
            statusText = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    private func registerAndRefresh() {
        if fm.fileExists(atPath: spotlightDst.path) {
            run("/usr/bin/mdimport", ["-r", spotlightDst.path])
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

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}

private struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SidebarPane? = .status

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Status", systemImage: "checkmark.shield")
                    .tag(SidebarPane.status)
                Label("Actions", systemImage: "wrench.and.screwdriver")
                    .tag(SidebarPane.actions)
                Label("Quick Look Settings", systemImage: "slider.horizontal.3")
                    .tag(SidebarPane.settings)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            Group {
                switch selection ?? .status {
                case .status:
                    statusPane
                case .actions:
                    actionsPane
                case .settings:
                    settingsPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(18)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", action: model.refreshStatus)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: AppEvents.selectSidebarPane)) { note in
            guard
                let raw = note.userInfo?["pane"] as? String,
                let pane = SidebarPane(rawValue: raw)
            else { return }
            selection = pane
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
        }
        .formStyle(.grouped)
        .navigationTitle("Status")
    }

    private var actionsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Management Actions")
                .font(.title3).fontWeight(.semibold)

            HStack(spacing: 10) {
                Button("Install") { model.install() }
                    .buttonStyle(.borderedProminent)
                Button("Repair") { model.repair() }
                    .buttonStyle(.bordered)
                Button("Refresh Status") { model.refreshStatus() }
                    .buttonStyle(.bordered)
            }

            Divider()

            Text("Danger Zone")
                .font(.headline)
            Text("Uninstall removes the importer and Quick Look app from user locations.")
                .foregroundStyle(.secondary)
            Button("Uninstall") { model.uninstall() }
                .buttonStyle(.bordered)
                .tint(.red)

            Spacer()

            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Actions")
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
            model.statusText = "Could not open NEWS.md (missing from app bundle)."
            showMainWindow()
        }
    }

    @objc private func openIssueTracker(_ sender: Any?) {
        NSWorkspace.shared.open(issuesURL)
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
