import AppKit
import Combine
import MenubucketCore
import UniformTypeIdentifiers

/// Apps with a Dock presence that are running now, in launch order. Feeds the
/// running dots and the section of apps that are open but not in the profile.
final class RunningApps: ObservableObject {
    struct App: Identifiable, Equatable {
        let path: String
        let bundleID: String?
        let processID: pid_t
        var id: String { path }
    }

    @Published private(set) var apps: [App] = []
    @Published private(set) var frontmostPath: String?

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            })
        }
        reload()
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func reload() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
            .compactMap { app -> App? in
                guard let url = app.bundleURL else { return nil }
                return App(path: Self.key(url.path), bundleID: app.bundleIdentifier, processID: app.processIdentifier)
            }
        if running != apps { apps = running }
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL.map { Self.key($0.path) }
        if front != frontmostPath { frontmostPath = front }
    }

    func isRunning(path: String) -> Bool {
        let key = Self.key(path)
        return apps.contains { $0.path == key }
    }

    func runningApplication(path: String) -> NSRunningApplication? {
        let key = Self.key(path)
        guard let app = apps.first(where: { $0.path == key }) else { return nil }
        return NSRunningApplication(processIdentifier: app.processID)
    }

    /// Paths compare without a trailing slash or `..` noise.
    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// What clicking, dropping on, and right-clicking a dock tile does.
enum DockActions {
    static var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    // MARK: Open

    static func open(_ item: DockItem) {
        switch item.kind {
        case .app(let path):
            openApp(path: path)
        case .folder(let path, _, _), .file(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .link(let string, _):
            if let url = URL(string: string) { NSWorkspace.shared.open(url) }
        case .shortcut(let name):
            runShortcut(named: name)
        case .widget(let id):
            if let url = URL(string: "barshelf://show?widget=\(id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id)") {
                NSWorkspace.shared.open(url)
            }
        case .spacer, .separator:
            break
        }
    }

    /// Launches the app, or brings it forward with a reopen event so an app
    /// with no windows opens one — what clicking the Apple Dock does.
    static func openApp(path: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }

    static func open(_ urls: [URL], withAppAt path: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: path), configuration: configuration)
    }

    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openTrash() {
        NSWorkspace.shared.open(trashURL)
    }

    static func moveToTrash(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    // MARK: Shortcuts

    /// Runs a Shortcut through the `shortcuts` tool, off the main thread.
    static func runShortcut(named name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// The user's Shortcuts by name, for the "Add Shortcut" picker.
    static func listShortcuts(completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var names: [String] = []
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                names = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            DispatchQueue.main.async { completion(names) }
        }
    }

    // MARK: Icons

    static func icon(for item: DockItem) -> NSImage? {
        switch item.kind {
        case .app(let path), .file(let path):
            return NSWorkspace.shared.icon(forFile: path)
        case .folder(let path, _, _):
            return NSWorkspace.shared.icon(forFile: path)
        case .shortcut:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts")
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        default:
            return nil
        }
    }

    static func displayName(for item: DockItem) -> String {
        switch item.kind {
        case .app(let path), .file(let path):
            return FileManager.default.displayName(atPath: path)
                .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        default:
            return item.fallbackTitle
        }
    }

    // MARK: Folder menu (a "list" stack)

    /// The folder's contents as a menu, subfolders opening as submenus —
    /// the Apple Dock's list view of a stack.
    static func folderMenu(path: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let open = NSMenuItem(
            title: String(localized: "Open in Finder"),
            action: #selector(FolderMenuTarget.openItem(_:)), keyEquivalent: ""
        )
        open.target = FolderMenuTarget.shared
        open.representedObject = url
        menu.addItem(open)
        menu.addItem(.separator())
        FolderMenuTarget.fill(menu, with: url)
        return menu
    }
}

/// Target and lazy filler for folder menus; subfolders fill when opened.
final class FolderMenuTarget: NSObject, NSMenuDelegate {
    static let shared = FolderMenuTarget()
    /// Enough to find something in Downloads without a menu taller than the
    /// screen; "Open in Finder" covers the rest.
    static let limit = 80

    static func fill(_ menu: NSMenu, with folder: URL) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if entries.isEmpty {
            let empty = NSMenuItem(title: String(localized: "Empty Folder"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for entry in entries.prefix(limit) {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: entry.path),
                action: #selector(openItem(_:)), keyEquivalent: ""
            )
            item.target = shared
            item.representedObject = entry
            let icon = NSWorkspace.shared.icon(forFile: entry.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                submenu.delegate = shared
                submenu.title = entry.path
                item.submenu = submenu
            }
            menu.addItem(item)
        }
        if entries.count > limit {
            let more = NSMenuItem(
                title: String(localized: "\(entries.count - limit) more…"),
                action: #selector(openItem(_:)), keyEquivalent: ""
            )
            more.target = shared
            more.representedObject = folder
            menu.addItem(more)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.isEmpty else { return }
        let folder = URL(fileURLWithPath: menu.title, isDirectory: true)
        let open = NSMenuItem(
            title: String(localized: "Open in Finder"), action: #selector(openItem(_:)), keyEquivalent: ""
        )
        open.target = self
        open.representedObject = folder
        menu.addItem(open)
        menu.addItem(.separator())
        Self.fill(menu, with: folder)
    }

    @objc func openItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
}
