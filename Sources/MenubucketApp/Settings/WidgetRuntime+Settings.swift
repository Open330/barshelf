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
        !prefs.bucketOverrides.isEmpty || !prefs.groupOrder.isEmpty
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
        permissionStore.reset(widgetId: widgetID)
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

    static func lines(for manifest: Manifest) -> [Line] {
        guard let permissions = manifest.permissions else { return [] }
        var lines: [Line] = []
        let exec = permissions.exec ?? []
        if !exec.isEmpty {
            lines.append(Line(symbol: "terminal", text: "Run \(list(unique(exec.map { ($0.command as NSString).lastPathComponent })))"))
        }
        let network = permissions.network ?? []
        if !network.isEmpty {
            lines.append(Line(symbol: "network", text: "Connect to \(list(network))"))
        }
        let paths = permissions.readPaths ?? []
        if !paths.isEmpty {
            lines.append(Line(symbol: "folder", text: "Read \(list(paths))"))
        }
        if permissions.keychain == true {
            lines.append(Line(symbol: "key", text: "Read its own secrets from the Keychain"))
        }
        if permissions.notifications == true {
            lines.append(Line(symbol: "bell", text: "Send notifications"))
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
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and \(items.last!)"
        }
    }
}
