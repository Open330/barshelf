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
        prefs.setKeptPages([])
        objectWillChange.send()
    }

    var hasLayoutChanges: Bool {
        let loaded = Set(widgets.map(\.id))
        return prefs.bucketOverrides.keys.contains(where: loaded.contains) || !prefs.groupOrder.isEmpty
            || !prefs.keptPages.isEmpty
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

    // MARK: - Page editing

    /// A page is not stored on its own: it is the name its widgets share
    /// (`bucket.group`, or the user's override of it). Renaming a page is
    /// therefore renaming it on every widget it holds, switched-off ones
    /// included, and keeping its place among the pages. Naming it after
    /// another page merges the two, its widgets after that page's own — which
    /// is also how a page is removed without removing any widget.
    func renamePage(_ name: String, to newName: String) {
        let pages = shelfPages
        guard let plan = ShelfPageEdit.rename(
            name, to: newName,
            pages: pages.map { page in (page.group, page.widgets.map { ($0.id, $0.group) }) }
        ) else { return }
        for placement in plan.placements {
            let existing = prefs.override(for: placement.id)
            prefs.setOverride(group: placement.group, order: placement.order, size: existing?.size, for: placement.id)
        }
        prefs.setGroupsOrder(plan.pageOrder)
        if prefs.isKeptPage(name) || newWidgetPage?.name == name {
            let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let merging = pages.contains { $0.group == target }
            if prefs.isKeptPage(name) {
                prefs.setKeptPages(merging
                    ? prefs.keptPages.filter { $0 != name }
                    : prefs.keptPages.map { $0 == name ? target : $0 })
            }
            if newWidgetPage?.name == name { newWidgetPage = (target, newWidgetPage!.until) }
        }
        objectWillChange.send()
    }

    /// Makes an empty page at the end, or at `index`. Returns the name used,
    /// or nil for an empty name. A name already taken returns that page.
    @discardableResult
    func createPage(_ name: String, at index: Int? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var order = shelfPages.map(\.group)
        guard !order.contains(trimmed) else { return trimmed }
        order.insert(trimmed, at: min(max(index ?? order.count, 0), order.count))
        prefs.setKeptPages(prefs.keptPages + [trimmed])
        prefs.setGroupsOrder(order)
        objectWillChange.send()
        return trimmed
    }

    /// Removes a page that has no widgets. One with widgets is removed by
    /// moving them (`renamePage` onto another page).
    func removeEmptyPage(_ name: String) {
        guard shelfPages.first(where: { $0.group == name })?.widgets.isEmpty ?? true else { return }
        prefs.setKeptPages(prefs.keptPages.filter { $0 != name })
        prefs.setGroupsOrder(shelfPages.map(\.group).filter { $0 != name })
        if newWidgetPage?.name == name { newWidgetPage = nil }
        objectWillChange.send()
    }

    /// Moves a widget to the end of a page.
    func moveWidgetToEnd(_ id: String, ofPage page: String) {
        guard let widget = widgets.first(where: { $0.id == id }) else { return }
        let count = shelfPages.first { $0.group == page }?.widgets.filter { $0.id != id }.count ?? 0
        prefs.setOverride(
            group: widget.group == page ? nil : page,
            order: Double(count), size: prefs.override(for: id)?.size, for: id
        )
        objectWillChange.send()
    }

    /// How long "add a widget here" keeps waiting for the widget: long
    /// enough to browse the gallery, short enough not to catch a widget
    /// installed for some other reason much later.
    static let newWidgetPageWindow: TimeInterval = 10 * 60

    /// Asks that the next widget installed land on `page`, at its end.
    func addNextWidget(toPage page: String) {
        newWidgetPage = (page, Date().addingTimeInterval(Self.newWidgetPageWindow))
    }

    /// Called by `loadWidgets` with the widgets that just appeared. A widget
    /// someone already placed (a copy, which stays beside its original) keeps
    /// its place.
    func landNewWidgets(_ ids: [String]) {
        guard let target = newWidgetPage, !ids.isEmpty else { return }
        newWidgetPage = nil
        guard target.until > Date(),
              shelfPages.contains(where: { $0.group == target.name }) else { return }
        var count = shelfPages.first { $0.group == target.name }?.widgets.count ?? 0
        for id in ids where prefs.override(for: id)?.group == nil {
            let manifestGroup = widgets.first { $0.id == id }?.group
            prefs.setOverride(
                group: manifestGroup == target.name ? nil : target.name,
                order: Double(count), size: prefs.override(for: id)?.size, for: id
            )
            count += 1
        }
    }

    /// Puts a page at `index` among the pages (clamped).
    func movePage(_ name: String, to index: Int) {
        var order = shelfPages.map(\.group)
        guard let from = order.firstIndex(of: name) else { return }
        order.remove(at: from)
        order.insert(name, at: min(max(index, 0), order.count))
        prefs.setGroupsOrder(order)
        objectWillChange.send()
    }

    /// Turns every widget on a page on or off. A page whose widgets are all
    /// off leaves the popup but stays on the Shelf board, ready to come back.
    func setPageEnabled(_ name: String, _ enabled: Bool) {
        guard let page = shelfPages.first(where: { $0.group == name }) else { return }
        for widget in page.widgets { setWidgetDisabled(widget.id, !enabled) }
    }

    // MARK: - Menu bar

    /// Widgets on the shelf that are not in the Menu Bar page's list — their
    /// author offered no menu bar reading — but can still be put there.
    var menuBarAddableWidgets: [LoadedWidget] {
        let listed = Set(menuBarCandidates.map(\.id))
        return widgets
            .filter { !prefs.isDisabled($0.id) && !listed.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Sets a widget's accent — its card's tint and its chip's colour.
    /// `nil` goes back to the widget's own.
    func setAccent(_ accent: String?, for id: String) {
        guard let widget = widgets.first(where: { $0.id == id }) else { return }
        let base = WidgetPrefs.baseAppearance(for: widget.manifest)
        var appearance = prefs.effectiveAppearance(for: widget.manifest, widgetID: id)
        appearance.accent = accent ?? base.accent
        prefs.setAppearanceOverride(appearance == base ? nil : appearance, for: id)
        objectWillChange.send()
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
        guard PermissionStore.requiresApproval(for: widget.manifest) else { return .notNeeded }
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
        stopForPermissionChange(packageID: widget.manifest.id, denied: false)
        auditLog.record("permission.revoked", widgetId: widgetID, detail: [
            "hash": .string(PermissionStore.permissionsHash(of: widget.manifest)),
        ])
        objectWillChange.send()
    }
}

/// A manifest's declared permissions as sentences a person can judge.
enum WidgetPermissionSummary {
    struct Line: Hashable {
        enum Tone: Hashable {
            case normal
            /// Secrets, the vault, environment variables, quitting apps.
            case sensitive
            /// Something the widget uses without declaring it: it will be blocked.
            case blocked
        }

        let symbol: String
        let text: String
        var tone: Tone = .normal
    }

    /// - Parameter workflow: the widget's workflow when known, which reveals a
    ///   command or system reading it uses without having declared it.
    static func lines(for manifest: Manifest, workflow: WorkflowDefinition? = nil) -> [Line] {
        var lines: [Line] = []
        // Missing declarations first: the widget will be blocked from doing
        // these, which matters more than what it is allowed.
        if (manifest.permissions?.exec ?? []).isEmpty,
           WidgetDiscovery.manifestRequiresExecPermission(manifest, workflow: workflow) {
            lines.append(Line(symbol: "exclamationmark.triangle", text: String(localized: "Runs a command it hasn't declared, so it will be blocked"), tone: .blocked))
        }
        if (manifest.permissions?.system ?? []).isEmpty, WidgetDiscovery.usesSystemSource(workflow) {
            lines.append(Line(symbol: "exclamationmark.triangle", text: String(localized: "Reads system information it hasn't declared, so it will be blocked"), tone: .blocked))
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
            lines.append(Line(symbol: "key", text: String(localized: "Read its own secrets from the Keychain"), tone: .sensitive))
        }
        if permissions.notifications == true {
            lines.append(Line(symbol: "bell", text: String(localized: "Send notifications")))
        }
        if permissions.quitApps == true {
            lines.append(Line(symbol: "xmark.app", text: String(localized: "Quit apps you choose, asking each time"), tone: .sensitive))
        }
        let environment = permissions.env ?? []
        if !environment.isEmpty {
            lines.append(Line(symbol: "list.bullet.rectangle", text: String(localized: "Read the environment variables \(list(environment))", comment: "Permission summary: environment variables the widget may read"), tone: .sensitive))
        }
        if permissions.storage?.granted == true {
            lines.append(Line(symbol: "internaldrive", text: String(localized: "Save small amounts of data on this Mac")))
        }
        if permissions.vault != nil {
            lines.append(Line(symbol: "lock.shield", text: String(localized: "Unlock your Bitwarden vault when you ask and copy fields you pick"), tone: .sensitive))
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

/// Renaming and merging pages as a plan over plain values, so the rules can
/// be checked without a runtime.
enum ShelfPageEdit {
    struct Placement: Equatable {
        let id: String
        /// nil when the widget's own manifest already names the page.
        let group: String?
        let order: Double
    }

    struct Plan: Equatable {
        let placements: [Placement]
        let pageOrder: [String]
    }

    /// - Parameter pages: every page in order, each with its widgets in
    ///   order as (id, the group its manifest names).
    /// - Returns: nil when there is nothing to do: an empty or unchanged
    ///   name, or no such page.
    static func rename(
        _ name: String, to newName: String,
        pages: [(group: String, widgets: [(id: String, manifestGroup: String)])]
    ) -> Plan? {
        let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != name,
              let source = pages.first(where: { $0.group == name }) else { return nil }
        let order = pages.map(\.group)
        let merging = order.contains(target)
        // Merged widgets go after the ones already there.
        let staying = merging ? (pages.first { $0.group == target }?.widgets ?? []) : []
        let placements = (staying + source.widgets).enumerated().map { position, widget in
            Placement(
                id: widget.id,
                group: widget.manifestGroup == target ? nil : target,
                order: Double(position)
            )
        }
        return Plan(
            placements: placements,
            pageOrder: merging ? order.filter { $0 != name } : order.map { $0 == name ? target : $0 }
        )
    }
}
