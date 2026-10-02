import Foundation
import MenubucketCore

/// What the settings pages need from the runtime, kept out of the 3,000-line
/// runtime file.
extension WidgetRuntime {
    /// Puts every widget back on its own page, in its own order, at its own
    /// size, and the pages back in their default order.
    func resetLayout() {
        for widget in widgets {
            prefs.setOverride(group: nil, order: nil, size: nil, for: widget.id)
        }
        prefs.setGroupsOrder([])
        objectWillChange.send()
    }

    var hasLayoutChanges: Bool {
        let loaded = Set(widgets.map(\.id))
        return prefs.bucketOverrides.keys.contains(where: loaded.contains) || !prefs.groupOrder.isEmpty
    }

    /// Runs a layout change — moving, reordering, resizing, turning widgets
    /// on or off — as one undo step (R13 decision 2).
    func changeLayout(_ name: String, undoManager: UndoManager?, _ change: () -> Void) {
        prefs.changeLayout(name, undoManager: undoManager, change) { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Every page with every widget — switched-off ones included — in the
    /// order the popup shows them. Pages that only hold switched-off
    /// widgets come last.
    var shelfPages: [WidgetPage] {
        func sortMembers(_ members: [LoadedWidget]) -> [LoadedWidget] {
            members.sorted { lhs, rhs in
                let lo = effectiveOrder(for: lhs.id), ro = effectiveOrder(for: rhs.id)
                if lo != ro { return lo < ro }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
        let grouped = Dictionary(grouping: widgets) { effectiveGroup(for: $0.id) }
        let visibleOrder = pages.map(\.group)
        let hiddenOnly = grouped.keys.filter { !visibleOrder.contains($0) }.sorted { lhs, rhs in
            let lk = prefs.groupSortKey(lhs) ?? .greatestFiniteMagnitude
            let rk = prefs.groupSortKey(rhs) ?? .greatestFiniteMagnitude
            if lk != rk { return lk < rk }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return (visibleOrder + hiddenOnly).map { WidgetPage(group: $0, widgets: sortMembers(grouped[$0] ?? [])) }
    }

    // MARK: - Permissions

    enum PermissionState: Equatable {
        /// The widget declares nothing that needs approval.
        case notNeeded
        case notAsked
        case allowed
        case denied
    }

    func permissionState(for widget: LoadedWidget) -> PermissionState {
        guard !WidgetPermissionSummary.lines(for: widget.manifest).isEmpty else { return .notNeeded }
        switch permissionStore.status(for: widget.manifest) {
        case .approved: return .allowed
        case .denied: return .denied
        case .pending: return .notAsked
        }
    }

    /// Forgets the decision, so the widget stops and asks again on its card.
    func revokePermissions(widgetID: String) {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return }
        // Decisions are stored per package, so a copy and its original share
        // one; revoking either revokes both, which the Privacy page says.
        permissionStore.reset(widgetId: widget.manifest.id)
        auditLog.record("permission.revoked", widgetId: widgetID, detail: [
            "hash": .string(PermissionStore.permissionsHash(of: widget.manifest)),
        ])
        refresh(widget, manual: true)
        objectWillChange.send()
    }
}

/// A manifest's declared permissions as sentences a person can judge.
enum WidgetPermissionSummary {
    struct Line: Hashable {
        let symbol: String
        let text: String
    }

    /// - Parameter workflow: the widget's workflow when known, which reveals a
    ///   command or system reading it uses without having declared it.
    static func lines(for manifest: Manifest, workflow: WorkflowDefinition? = nil) -> [Line] {
        var lines: [Line] = []
        // Missing declarations first: the widget will be blocked from doing
        // these, which matters more than what it is allowed.
        if (manifest.permissions?.exec ?? []).isEmpty,
           WidgetDiscovery.manifestRequiresExecPermission(manifest, workflow: workflow) {
            lines.append(Line(symbol: "exclamationmark.triangle", text: String(localized: "Runs a command it hasn't declared, so it will be blocked")))
        }
        if (manifest.permissions?.system ?? []).isEmpty, WidgetDiscovery.usesSystemSource(workflow) {
            lines.append(Line(symbol: "exclamationmark.triangle", text: String(localized: "Reads system information it hasn't declared, so it will be blocked")))
        }
        guard let permissions = manifest.permissions else { return lines }
        let exec = permissions.exec ?? []
        if !exec.isEmpty {
            lines.append(Line(symbol: "terminal", text: String(localized: "Run \(list(unique(exec.map { ($0.command as NSString).lastPathComponent })))", comment: "Permission summary: commands the widget may run")))
        }
        let network = permissions.network ?? []
        if !network.isEmpty {
            lines.append(Line(symbol: "network", text: String(localized: "Connect to \(list(network))", comment: "Permission summary: hosts the widget may reach")))
        }
        let paths = permissions.readPaths ?? []
        if !paths.isEmpty {
            lines.append(Line(symbol: "folder", text: String(localized: "Read \(list(paths))", comment: "Permission summary: paths the widget may read")))
        }
        if permissions.keychain == true {
            lines.append(Line(symbol: "key", text: String(localized: "Read its own secrets from the Keychain")))
        }
        if permissions.notifications == true {
            lines.append(Line(symbol: "bell", text: String(localized: "Send notifications")))
        }
        let environment = permissions.env ?? []
        if !environment.isEmpty {
            lines.append(Line(symbol: "list.bullet.rectangle", text: String(localized: "Read the environment variables \(list(environment))", comment: "Permission summary: environment variables the widget may read")))
        }
        if permissions.storage?.granted == true {
            lines.append(Line(symbol: "internaldrive", text: String(localized: "Save small amounts of data on this Mac")))
        }
        let system = permissions.system ?? []
        if !system.isEmpty {
            lines.append(Line(symbol: "cpu", text: String(localized: "Read system information: \(list(system))", comment: "Permission summary: system readings such as cpu or memory")))
        }
        return lines
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return String(localized: "\(items[0]) and \(items[1])", comment: "A list of two items")
        default:
            let head = items.dropLast().joined(separator: String(localized: ", ", comment: "Separator between list items"))
            return String(localized: "\(head), and \(items.last!)", comment: "The end of a list of three or more items: the leading items, then the last one")
        }
    }
}

extension LoadedWidget {
    /// `version` and `description` from the package's widget.json. The
    /// manifest decoder leaves both out — the runtime never needs them — so
    /// the inspector reads them on its own.
    var packageInfo: (version: String?, description: String?) {
        struct Probe: Decodable {
            let version: String?
            let description: String?
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("widget.json")),
              let probe = try? JSONDecoder().decode(Probe.self, from: data)
        else { return (nil, nil) }
        return (probe.version, probe.description)
    }
}
