import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// BarShelf window ▸ Dock (R15): whether there is a BarShelf Dock and how it
/// relates to the Apple Dock, how it looks, and its profiles.
struct DockSettingsPage: View {
    @ObservedObject var store: DockStore
    @ObservedObject var runtime: WidgetRuntime

    @State private var selectedProfileID: String?
    @State private var shortcuts: [String]?
    @State private var linkDraft = ""
    @State private var showLinkPrompt = false
    @State private var newProfileName = ""
    @State private var showNewProfilePrompt = false
    @State private var profileToDelete: DockProfile?

    static let symbolPresets = [
        "square.grid.2x2", "briefcase", "house", "laptopcomputer", "hammer",
        "paintbrush", "book", "gamecontroller", "music.note", "airplane",
        "moon", "sun.max", "person.2", "graduationcap", "cup.and.saucer",
    ]

    private var config: DockConfiguration { store.configuration }

    private var selectedProfile: DockProfile {
        config.profiles.first { $0.id == selectedProfileID } ?? config.activeProfile
    }

    var body: some View {
        SettingsPage {
            modeSection
            if let error = store.lastError {
                Section {
                    StatusBanner(tone: .critical, message: String(localized: "Couldn't save dock settings: \(error)"))
                }
            }
            appearanceSection
            profilesSection
            itemsSection
            appleDockSection
            switchingSection
        }
        .alert("Add Link", isPresented: $showLinkPrompt) {
            TextField("https://example.com", text: $linkDraft)
            Button("Cancel", role: .cancel) { linkDraft = "" }
            Button("Add") { addLink() }
        } message: {
            Text("A web page to open from the dock.")
        }
        .alert("New Profile", isPresented: $showNewProfilePrompt) {
            TextField("Profile name", text: $newProfileName)
            Button("Cancel", role: .cancel) { newProfileName = "" }
            Button("Add") {
                let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                newProfileName = ""
                guard !name.isEmpty else { return }
                selectedProfileID = store.addProfile(named: name)
            }
        } message: {
            Text("Starts empty. Add apps, folders, and widgets below.")
        }
        .alert(
            "Delete \(profileToDelete?.name ?? "")?",
            isPresented: Binding(get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) { profileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    store.removeProfile(profile.id)
                    selectedProfileID = nil
                }
                profileToDelete = nil
            }
        } message: {
            Text("Its items and saved Apple Dock layout are removed. Nothing on disk is touched.")
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        Section {
            Picker("BarShelf Dock", selection: Binding(
                get: { config.mode },
                set: { mode in store.update { $0.mode = mode } }
            )) {
                Text("Off").tag(DockConfiguration.Mode.off)
                Text("Alongside the Apple Dock").tag(DockConfiguration.Mode.alongside)
                Text("Instead of the Apple Dock").tag(DockConfiguration.Mode.replace)
            }
            .pickerStyle(.radioGroup)
            if config.mode == .replace {
                StatusBanner(
                    tone: .info,
                    message: String(localized: "The Apple Dock is hidden while BarShelf runs and comes back when you quit BarShelf or turn this off. If it ever stays hidden, run barshelf dock restore-apple-dock in Terminal.")
                )
            } else if config.mode == .alongside, sharesEdgeWithAppleDock {
                StatusBanner(
                    tone: .warning,
                    message: String(localized: "The Apple Dock is on the same edge. The BarShelf Dock sits just above it; another position, or auto-hide, keeps them apart.")
                )
            }
        } header: {
            Text("Dock")
        } footer: {
            Text("Profiles below also work with the BarShelf Dock off: they can switch the Apple Dock's apps.")
        }
    }

    private var sharesEdgeWithAppleDock: Bool {
        store.appleDock.orientation == config.edge.rawValue && store.appleDock.visibility.autohide != true
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Style", selection: binding(\.style)) {
                Text("Classic").tag(DockConfiguration.Style.classic)
                Text("Shelf").tag(DockConfiguration.Style.shelf)
            }
            .pickerStyle(.segmented)
            Text(config.style == .classic
                 ? "Like the Apple Dock: icons on glass, names on hover. Widgets show their main reading at icon height."
                 : "A sturdier bar with names under icons, and widgets as full cards.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Position on screen", selection: binding(\.edge)) {
                Text("Left").tag(DockConfiguration.Edge.left)
                Text("Bottom").tag(DockConfiguration.Edge.bottom)
                Text("Right").tag(DockConfiguration.Edge.right)
            }
            .pickerStyle(.segmented)
            LabeledContent("Icon size") {
                HStack {
                    Slider(value: binding(\.tileSize), in: DockConfiguration.tileSizeRange, step: 2)
                        .frame(maxWidth: 220)
                    if let apple = store.appleDock.tileSize, abs(apple - config.tileSize) >= 1 {
                        Button("Match Apple Dock") { store.update { $0.tileSize = apple } }
                            .controlSize(.small)
                    }
                }
            }
            if config.style == .shelf {
                LabeledContent("Widget size") {
                    Slider(value: binding(\.widgetSize), in: DockConfiguration.widgetSizeRange, step: 2)
                        .frame(maxWidth: 220)
                }
            }
            Toggle("Magnification", isOn: binding(\.magnification))
                .disabled(config.style != .classic)
            Toggle("Automatically hide and show the dock", isOn: binding(\.autoHide))
            Toggle("Show open apps that aren't in the dock", isOn: binding(\.showRunningApps))
            Toggle("Show Trash", isOn: binding(\.showTrash))
        }
        .disabled(!config.mode.showsDock)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DockConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { store.configuration[keyPath: keyPath] },
            set: { value in store.update { $0[keyPath: keyPath] = value } }
        )
    }

    // MARK: Profiles

    private var profilesSection: some View {
        Section {
            ForEach(Array(config.profiles.enumerated()), id: \.element.id) { index, profile in
                profileRow(profile, position: index + 1)
            }
            .onMove { from, to in
                store.update { $0.profiles.move(fromOffsets: from, toOffset: to) }
            }
            HStack {
                Button("Add Profile…") { showNewProfilePrompt = true }
                Button("Duplicate") {
                    selectedProfileID = store.addProfile(
                        named: String(localized: "\(selectedProfile.name) Copy"), copying: selectedProfile
                    )
                }
                Spacer()
                Button("Delete…", role: .destructive) { profileToDelete = selectedProfile }
                    .disabled(config.profiles.count < 2)
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("Each profile has its own dock items, and can carry an Apple Dock layout and a popup page. Drag to reorder; the first nine get ⌃⌥1–9.")
        }
    }

    private func profileRow(_ profile: DockProfile, position: Int) -> some View {
        let isSelected = profile.id == selectedProfile.id
        let isActive = profile.id == config.activeProfileID
        return HStack(spacing: Spacing.xs) {
            Image(systemName: profile.symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(profile.name)
                .fontWeight(isSelected ? .semibold : .regular)
            if isActive {
                Text("Active")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            Spacer()
            if config.profileHotkeysEnabled, let label = DockHotkeys.label(forPosition: position) {
                Text(label).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if !isActive {
                Button("Switch") { store.activate(profileID: profile.id) }
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedProfileID = profile.id }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Items of the selected profile

    private var itemsSection: some View {
        let profile = selectedProfile
        return Section {
            TextField("Name", text: Binding(
                get: { profile.name },
                set: { name in store.updateProfile(profile.id) { $0.name = name } }
            ))
            Picker("Symbol", selection: Binding(
                get: { profile.symbol },
                set: { symbol in store.updateProfile(profile.id) { $0.symbol = symbol } }
            )) {
                ForEach(Self.symbolPresets, id: \.self) { symbol in
                    Label(symbol, systemImage: symbol).labelStyle(.iconOnly).tag(symbol)
                }
                if !Self.symbolPresets.contains(profile.symbol) {
                    Label(profile.symbol, systemImage: profile.symbol).tag(profile.symbol)
                }
            }
            Picker("Popup page", selection: Binding(
                get: { profile.popupPage ?? "" },
                set: { page in store.updateProfile(profile.id) { $0.popupPage = page.isEmpty ? nil : page } }
            )) {
                Text("Don't change").tag("")
                ForEach(runtime.allGroups, id: \.self) { Text($0).tag($0) }
            }
            if profile.items.isEmpty {
                Text("No items yet. Add some below, or drop apps, folders, and files on the dock.")
                    .foregroundStyle(.secondary)
            }
            ForEach(profile.items) { item in
                itemRow(item, profileID: profile.id)
            }
            .onMove { from, to in
                store.updateProfile(profile.id) { $0.items.move(fromOffsets: from, toOffset: to) }
            }
            addMenu(profileID: profile.id)
        } header: {
            Text("Items in \(profile.name)")
        }
    }

    private func itemRow(_ item: DockItem, profileID: String) -> some View {
        HStack(spacing: Spacing.xs) {
            itemIcon(item)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(itemTitle(item)).lineLimit(1)
                Text(itemKind(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if case .folder(let path, let color, let label) = item.kind {
                Picker("Color", selection: Binding(
                    get: { color },
                    set: { store.replaceItem(DockItem(id: item.id, kind: .folder(path: path, color: $0, label: label)), profileID: profileID) }
                )) {
                    Text("Folder icon").tag(DockItem.FolderColor?.none)
                    ForEach(DockItem.FolderColor.allCases, id: \.self) { option in
                        Text(FolderBadge.name(option)).tag(Optional(option))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Button {
                store.removeItem(item.id, profileID: profileID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from the dock")
            .accessibilityLabel(Text("Remove \(itemTitle(item))"))
        }
    }

    @ViewBuilder
    private func itemIcon(_ item: DockItem) -> some View {
        switch item.kind {
        case .widget:
            Image(systemName: "square.grid.2x2").foregroundStyle(Color.accentColor)
        case .spacer:
            Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
        case .separator:
            Image(systemName: "line.diagonal").foregroundStyle(.secondary)
        case .link:
            Image(systemName: "globe").foregroundStyle(.teal)
        case .folder(_, let color?, let label):
            FolderBadge(color: color, label: label ?? itemTitle(item))
        default:
            if let icon = DockActions.icon(for: item) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "questionmark.app.dashed")
            }
        }
    }

    private func itemTitle(_ item: DockItem) -> String {
        if case .widget(let id) = item.kind {
            return runtime.widgets.first { $0.id == id }?.displayName ?? id
        }
        return DockActions.displayName(for: item)
    }

    private func itemKind(_ item: DockItem) -> String {
        switch item.kind {
        case .app: return String(localized: "App")
        case .folder(let path, _, _): return path.abbreviatingWithTildeInPath
        case .file(let path): return path.abbreviatingWithTildeInPath
        case .link(let url, _): return url
        case .shortcut: return String(localized: "Shortcut")
        case .widget: return String(localized: "Widget")
        case .spacer: return String(localized: "Space")
        case .separator: return String(localized: "Divider")
        }
    }

    private func addMenu(profileID: String) -> some View {
        HStack {
            Menu("Add") {
                Button("App…") { choose(profileID: profileID, apps: true) }
                Button("Folder or File…") { choose(profileID: profileID, apps: false) }
                Button("Link…") {
                    selectedProfileID = profileID
                    showLinkPrompt = true
                }
                Menu("Shortcut") {
                    if let shortcuts {
                        if shortcuts.isEmpty { Text("No Shortcuts found") }
                        ForEach(shortcuts, id: \.self) { name in
                            Button(name) { store.addItems([DockItem(kind: .shortcut(name: name))], profileID: profileID) }
                        }
                    } else {
                        Text("Loading…")
                    }
                }
                Menu("Widget") {
                    ForEach(runtime.widgets) { widget in
                        Button(widget.displayName) {
                            store.addItems([DockItem(kind: .widget(id: widget.id))], profileID: profileID)
                        }
                    }
                }
                Divider()
                Button("Space") { store.addItems([DockItem(kind: .spacer)], profileID: profileID) }
                Button("Divider") { store.addItems([DockItem(kind: .separator)], profileID: profileID) }
            }
            .fixedSize()
            .onAppear {
                guard shortcuts == nil else { return }
                DockActions.listShortcuts { shortcuts = $0 }
            }
            Button("Copy from Apple Dock") {
                store.addItems(store.appleDockItems(), profileID: profileID)
            }
            .help("Adds the Apple Dock's apps, folders, and files to this profile.")
            Spacer()
        }
    }

    private func choose(profileID: String, apps: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = !apps
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        if apps {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        panel.prompt = String(localized: "Add to Dock")
        guard panel.runModal() == .OK else { return }
        let items = panel.urls.map { url in
            DockItem.forFile(at: url, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
        store.addItems(items, profileID: profileID)
    }

    private func addLink() {
        var text = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        linkDraft = ""
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else { return }
        store.addItems([DockItem(kind: .link(url: url.absoluteString, title: url.host))], profileID: selectedProfile.id)
    }

    // MARK: Apple Dock layouts

    private var appleDockSection: some View {
        let profile = selectedProfile
        return Section {
            Toggle("Switch the Apple Dock's apps with the profile", isOn: binding(\.appleDockLayouts))
            if let layout = profile.appleDock {
                LabeledContent("Saved in \(profile.name)") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.summary(layout.appNames + layout.otherNames))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                        Text(layout.capturedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("\(profile.name) has no Apple Dock layout saved; switching to it leaves the Apple Dock as it is.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(profile.appleDock == nil ? "Save Current Apple Dock" : "Replace with Current Apple Dock") {
                    store.captureAppleDock(into: profile.id)
                }
                Button("Apply Now") { store.applyAppleDockLayout(of: profile.id) }
                    .disabled(profile.appleDock == nil)
                Spacer()
                Button("Forget") { store.updateProfile(profile.id) { $0.appleDock = nil } }
                    .disabled(profile.appleDock == nil)
            }
        } header: {
            Text("Apple Dock Layout")
        } footer: {
            Text("Arrange the Apple Dock the way you want it for this profile, then save. Switching restarts the Dock briefly; open apps and windows stay as they are. The previous layout is backed up first.")
        }
    }

    static func summary(_ names: [String]) -> String {
        let shown = names.prefix(6).joined(separator: ", ")
        return names.count > 6 ? String(localized: "\(shown), and \(names.count - 6) more") : shown
    }

    // MARK: Switching

    private var switchingSection: some View {
        let profile = selectedProfile
        let url = Self.switchURL(for: profile)
        return Section {
            Toggle("Switch profiles with ⌃⌥1–9", isOn: binding(\.profileHotkeysEnabled))
            Text("You can also swipe sideways with two fingers on the dock, or scroll over it holding ⌘, or pick a profile from the BarShelf menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Link to \(profile.name)") {
                HStack {
                    Text(url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Switching")
        } footer: {
            Text("To follow a Focus: in Shortcuts, add a personal automation for when the Focus turns on, with the Open URLs action and this link. From Terminal: barshelf dock use \"\(profile.name)\".")
        }
    }

    static func switchURL(for profile: DockProfile) -> String {
        let value = profile.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? profile.id
        return "barshelf://dock?profile=\(value)"
    }
}

private extension String {
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
