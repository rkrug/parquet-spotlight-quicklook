import AppKit
import Foundation
import SwiftUI

private enum SettingsKeys {
    // Use the preview extension bundle identifier as settings domain so the
    // sandboxed extension can read values reliably.
    static let suite = "com.rkrug.parquetindexer.previewhost.preview"
    static let expandDepth = "expandDepth"
    static let showAllColumns = "showAllColumns"
    static let maxColumns = "maxColumns"
    static let showPhysicalType = "showPhysicalType"
    static let hideListElement = "hideListElement"
    static let fontSize = "fontSize"
}

private struct StatusInfo {
    let importerInstalled: Bool
    let appInstalledInApplications: Bool
    let previewBundlePresent: Bool
}

private struct PreviewSettingsData: Codable {
    let expandDepth: Int
    let showAllColumns: Bool
    let maxColumns: Int
    let showPhysicalType: Bool
    let hideListElement: Bool
    let fontSize: Double
}

private final class AppModel: ObservableObject {
    @Published var statusText = "Ready."
    @Published var importerInstalled = false
    @Published var appInstalledInApplications = false
    @Published var previewBundlePresent = false

    @Published var expandDepth = 1
    @Published var showAllColumns = true
    @Published var maxColumns = 500
    @Published var showPhysicalType = false
    @Published var hideListElement = true
    @Published var fontSize = 12.0

    private let fm = FileManager.default
    private let spotlightDst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Spotlight/Parquet.mdimporter")
    private let legacyQuickLookDst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/QuickLook/Parquet.qlgenerator")
    private let userAppDst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/ParquetPreviewHost.app")
    private let systemAppDst = URL(fileURLWithPath: "/Applications/ParquetPreviewHost.app")
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
            fontSize = max(9.0, min(decoded.fontSize, 24.0))
            return
        }

        let defaults = UserDefaults(suiteName: SettingsKeys.suite) ?? .standard
        if defaults.object(forKey: SettingsKeys.expandDepth) == nil {
            defaults.set(1, forKey: SettingsKeys.expandDepth)
            defaults.set(true, forKey: SettingsKeys.showAllColumns)
            defaults.set(500, forKey: SettingsKeys.maxColumns)
            defaults.set(false, forKey: SettingsKeys.showPhysicalType)
            defaults.set(true, forKey: SettingsKeys.hideListElement)
            defaults.set(12.0, forKey: SettingsKeys.fontSize)
        }
        expandDepth = defaults.integer(forKey: SettingsKeys.expandDepth)
        showAllColumns = defaults.bool(forKey: SettingsKeys.showAllColumns)
        let maxCols = defaults.integer(forKey: SettingsKeys.maxColumns)
        maxColumns = maxCols > 0 ? maxCols : 500
        showPhysicalType = defaults.bool(forKey: SettingsKeys.showPhysicalType)
        hideListElement = defaults.bool(forKey: SettingsKeys.hideListElement)
        let fs = defaults.double(forKey: SettingsKeys.fontSize)
        fontSize = fs > 0 ? fs : 12.0
    }

    func saveSettings() {
        let defaults = UserDefaults(suiteName: SettingsKeys.suite) ?? .standard
        let normalizedExpandDepth = max(0, min(expandDepth, 10))
        let normalizedMaxColumns = max(1, maxColumns)
        let normalizedFontSize = max(9.0, min(fontSize, 24.0))

        defaults.set(normalizedExpandDepth, forKey: SettingsKeys.expandDepth)
        defaults.set(showAllColumns, forKey: SettingsKeys.showAllColumns)
        defaults.set(normalizedMaxColumns, forKey: SettingsKeys.maxColumns)
        defaults.set(showPhysicalType, forKey: SettingsKeys.showPhysicalType)
        defaults.set(hideListElement, forKey: SettingsKeys.hideListElement)
        defaults.set(normalizedFontSize, forKey: SettingsKeys.fontSize)

        let payload = PreviewSettingsData(
            expandDepth: normalizedExpandDepth,
            showAllColumns: showAllColumns,
            maxColumns: normalizedMaxColumns,
            showPhysicalType: showPhysicalType,
            hideListElement: hideListElement,
            fontSize: normalizedFontSize
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
        fontSize = 12.0
        saveSettings()
    }

    func refreshStatus() {
        let runningApp = Bundle.main.bundleURL
        let candidateApps = [runningApp, userAppDst, systemAppDst]
        let appInApplications = candidateApps.contains { isAppInApplications($0) }
        let previewFound = candidateApps.contains {
            fm.fileExists(atPath: $0.appendingPathComponent("Contents/PlugIns/ParquetPreview.appex").path)
        }
        let info = StatusInfo(
            importerInstalled: fm.fileExists(atPath: spotlightDst.path),
            appInstalledInApplications: appInApplications,
            previewBundlePresent: previewFound
        )
        importerInstalled = info.importerInstalled
        appInstalledInApplications = info.appInstalledInApplications
        previewBundlePresent = info.previewBundlePresent
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
            for app in [Bundle.main.bundleURL, userAppDst, systemAppDst] {
                let appex = app.appendingPathComponent("Contents/PlugIns/ParquetPreview.appex")
                if fm.fileExists(atPath: appex.path) {
                    run("/usr/bin/pluginkit", ["-r", appex.path])
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
        let appex = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/ParquetPreview.appex")
        if fm.fileExists(atPath: appex.path) {
            run("/usr/bin/pluginkit", ["-a", appex.path])
        }
        run("/usr/bin/qlmanage", ["-r"])
        run("/usr/bin/qlmanage", ["-r", "cache"])
    }

    private func isAppInApplications(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        if !fm.fileExists(atPath: resolved.path) {
            return false
        }

        let userApplications = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications").path + "/"
        let systemApplications = "/Applications/"
        return resolved.path.hasPrefix(userApplications) || resolved.path.hasPrefix(systemApplications)
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

private enum SidebarPane: Hashable {
    case status
    case actions
    case settings
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
                Label("Preview Settings", systemImage: "slider.horizontal.3")
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
    }

    private var statusPane: some View {
        Form {
            Section("Component Status") {
                statusRow("Spotlight importer", model.importerInstalled)
                statusRow("Manager app in /Applications or ~/Applications", model.appInstalledInApplications)
                statusRow("Quick Look preview extension", model.previewBundlePresent)
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
            Text("Uninstall removes the importer and preview app from user locations.")
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
                    Spacer()
                    Stepper(value: $model.maxColumns, in: 1...20000, step: 50) { EmptyView() }
                        .labelsHidden()
                    Text("\(model.maxColumns)")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }

                Toggle("Show physical type next to logical type", isOn: $model.showPhysicalType)
                Toggle("Hide path tokens (list/element)", isOn: $model.hideListElement)
            }

            Section("Typography") {
                HStack {
                    Text("Preview font size")
                    Slider(value: $model.fontSize, in: 9...24, step: 1)
                    Text("\(Int(model.fontSize))")
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Section {
                HStack {
                    Button("Save Settings") { model.saveSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Reset Defaults") { model.resetSettings() }
                        .buttonStyle(.bordered)
                }
                Text("Saved settings apply to new Quick Look previews.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Preview Settings")
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
        window.title = "Parquet Manager"
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        setupMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Parquet Manager",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

@main
final class ParquetPreviewHostMain: NSObject {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
