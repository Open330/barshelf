import MenubucketCore

/// The Privacy page's second view of the same permissions: by capability
/// rather than by widget. "Which widgets can run commands, and which?" is a
/// question the per-widget list makes you answer by reading every row.
///
/// Built from what installed widgets declare and their current decision.
/// It says what each widget may do, not what it has done (that is the
/// activity log's job), and it knows nothing about macOS's own privacy
/// grants beyond what widgets declare.
enum PermissionInventory {
    enum Kind: CaseIterable, Hashable {
        case commands, network, files, environment, keychain, vault, notifications, quitApps, storage, system

        var title: String {
            switch self {
            case .commands: return String(localized: "Commands", comment: "Privacy by capability: commands widgets may run")
            case .network: return String(localized: "Network", comment: "Privacy by capability: hosts widgets may reach")
            case .files: return String(localized: "Files and folders", comment: "Privacy by capability: paths widgets may read")
            case .environment: return String(localized: "Environment variables", comment: "Privacy by capability")
            case .keychain: return String(localized: "Keychain secrets", comment: "Privacy by capability")
            case .vault: return String(localized: "Password vault", comment: "Privacy by capability: widgets BarShelf unlocks a password manager for")
            case .notifications: return String(localized: "Notifications", comment: "Privacy by capability")
            case .quitApps: return String(localized: "Quitting apps", comment: "Privacy by capability: widgets that may quit apps, asking each time")
            case .storage: return String(localized: "Saved data", comment: "Privacy by capability: widgets that keep small data on this Mac")
            case .system: return String(localized: "System information", comment: "Privacy by capability: cpu, memory and similar readings")
            }
        }

        var symbol: String {
            switch self {
            case .commands: return "terminal"
            case .network: return "network"
            case .files: return "folder"
            case .environment: return "list.bullet.rectangle"
            case .keychain: return "key"
            case .vault: return "lock.shield"
            case .notifications: return "bell"
            case .quitApps: return "xmark.app"
            case .storage: return "internaldrive"
            case .system: return "cpu"
            }
        }
    }

    /// One thing a widget may use (a command, a host, a path), and who.
    struct Entry: Hashable {
        /// The command, host or path; empty for a capability with no
        /// detail (notifications, the Keychain).
        let detail: String
        let widgets: [Holder]
    }

    struct Holder: Hashable {
        let id: String
        let name: String
        let state: WidgetRuntime.PermissionState
    }

    struct Group: Hashable {
        let kind: Kind
        let entries: [Entry]
        /// Every widget in the group, once.
        var widgetCount: Int { Set(entries.flatMap { $0.widgets.map(\.id) }).count }
    }

    struct Input {
        let id: String
        let name: String
        let manifest: Manifest
        let state: WidgetRuntime.PermissionState
    }

    /// Only what is in effect: allowed widgets and those that need no
    /// approval. Waiting and denied requests grant nothing yet.
    static func inEffect(_ inputs: [Input]) -> [Group] {
        build(inputs.filter { $0.state == .allowed || $0.state == .notNeeded })
    }

    static func build(_ widgets: [Input]) -> [Group] {
        var buckets: [Kind: [String: [Holder]]] = [:]
        func add(_ kind: Kind, _ detail: String, _ holder: Holder) {
            var entries = buckets[kind, default: [:]]
            var holders = entries[detail, default: []]
            if !holders.contains(where: { $0.id == holder.id }) { holders.append(holder) }
            entries[detail] = holders
            buckets[kind] = entries
        }
        // Widgets that need no approval (system readings, quitting apps with
        // a prompt each time) are listed too: no approval is not no access.
        for widget in widgets {
            guard let permissions = widget.manifest.permissions else { continue }
            let holder = Holder(id: widget.id, name: widget.name, state: widget.state)
            for exec in permissions.exec ?? [] { add(.commands, exec.command, holder) }
            for host in permissions.network ?? [] { add(.network, host, holder) }
            for path in permissions.readPaths ?? [] { add(.files, path, holder) }
            for name in permissions.env ?? [] { add(.environment, name, holder) }
            for group in permissions.system ?? [] { add(.system, group, holder) }
            if permissions.keychain == true { add(.keychain, "", holder) }
            if let vault = permissions.vault { add(.vault, vault.provider, holder) }
            if permissions.notifications == true { add(.notifications, "", holder) }
            if permissions.quitApps == true { add(.quitApps, "", holder) }
            if permissions.storage?.granted == true { add(.storage, "", holder) }
        }
        return Kind.allCases.compactMap { kind in
            guard let entries = buckets[kind], !entries.isEmpty else { return nil }
            let sorted = entries
                .map { Entry(detail: $0.key, widgets: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
                .sorted { $0.detail.localizedStandardCompare($1.detail) == .orderedAscending }
            return Group(kind: kind, entries: sorted)
        }
    }
}

extension PermissionInventory {
    /// The Privacy page's waiting list, grouped by the most a widget could
    /// do, so thirty requests read as a few decisions: what may leave this
    /// Mac and touch secrets first, what only keeps a note last.
    enum Risk: Int, CaseIterable, Comparable {
        case secrets, controlsApps, internet, readsMac, notificationsAndStorage

        static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .secrets: return String(localized: "Uses passwords and secrets", comment: "Privacy: waiting widgets that use the Keychain, a vault or environment variables")
            case .controlsApps: return String(localized: "Controls other apps", comment: "Privacy: waiting widgets that script or quit other apps")
            case .internet: return String(localized: "Connects to the internet", comment: "Privacy: waiting widgets that reach the network")
            case .readsMac: return String(localized: "Reads from this Mac", comment: "Privacy: waiting widgets that run commands or read files and system readings")
            case .notificationsAndStorage: return String(localized: "Notifications and saved data", comment: "Privacy: waiting widgets that only notify or keep a little data")
            }
        }

        var symbol: String {
            switch self {
            case .secrets: return "key"
            case .controlsApps: return "macwindow.on.rectangle"
            case .internet: return "network"
            case .readsMac: return "desktopcomputer"
            case .notificationsAndStorage: return "bell"
            }
        }

        /// Commands that reach the network on their own.
        static let networkTools: Set<String> = ["curl", "wget", "ping", "networkQuality", "gh", "ssh", "nc", "kubectl"]

        /// The most a widget's declared permissions allow.
        static func of(_ manifest: Manifest) -> Risk {
            let permissions = manifest.permissions
            if permissions?.keychain == true || permissions?.vault != nil || !(permissions?.env ?? []).isEmpty {
                return .secrets
            }
            let tools = Set(ExecPermissionText.summary(for: manifest, localization: nil)?.tools ?? [])
            if permissions?.quitApps == true || tools.contains("osascript") { return .controlsApps }
            if !(permissions?.network ?? []).isEmpty || !tools.isDisjoint(with: networkTools) { return .internet }
            if !tools.isEmpty || !(permissions?.readPaths ?? []).isEmpty || !(permissions?.system ?? []).isEmpty {
                return .readsMac
            }
            return .notificationsAndStorage
        }
    }
}
