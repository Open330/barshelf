import MenubucketCore
import SwiftUI

/// Root of the hub window: a two-group sidebar (workspace pages, then settings)
/// driving a detail area. The sidebar selection is stored in `HubModel` so the
/// controller can re-target it while the window stays open.
struct HubView: View {
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var appPrefs: AppPrefs
    @ObservedObject var model: HubModel

    /// The gallery keeps its own registry model; created once and reused so a
    /// re-visit to the Gallery section does not re-fetch the index every time.
    @StateObject private var galleryModel = GalleryModel()

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach(HubTab.workspace) { sidebarRow($0) }
                }
                Section("Settings") {
                    ForEach(HubTab.settingsPages) { sidebarRow($0) }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                // The window toolbar carries the page's name; no second
                // header repeats it inside the page.
                .navigationTitle(model.tab.title)
                .navigationSubtitle(model.tab.subtitle)
        }
    }

    private func sidebarRow(_ tab: HubTab) -> some View {
        Label(tab.title, systemImage: tab.symbol)
            .tag(tab)
            // A press as well as a selection, so accessibility clients that
            // press rather than select (automation, Switch Control) can
            // change pages; the row did not answer AXPress before.
            .accessibilityAction { model.tab = tab }
    }

    private var sidebarHeader: some View {
        HStack(spacing: Spacing.xs) {
            AccentTile(size: 28) {
                Image(nsImage: BarShelfStatusIcon.logoImage(size: NSSize(width: 24, height: 18)))
                    .renderingMode(.template)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("BarShelf")
                    .font(.headline)
                Text("\(runtime.widgets.count) widgets installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var selection: Binding<HubTab?> {
        Binding(
            get: { model.tab },
            set: { if let value = $0 { model.tab = value } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch model.tab {
        case .shelf:
            ShelfView(runtime: runtime, model: model)
        case .menuBar:
            MenuBarPage(appPrefs: appPrefs, runtime: runtime)
        case .dock:
            DockSettingsPage(store: DockStore.shared, runtime: runtime)
        case .gallery:
            GalleryView(model: galleryModel, runtime: runtime)
                .onAppear { galleryModel.onWindowShown() }
        case .create:
            HubCreateView(runtime: runtime) { model.tab = .shelf }
        case .automation:
            SettingsPage { AutomationSettingsView() }
        case .general:
            GeneralSettingsPage(appPrefs: appPrefs)
        case .shortcuts:
            ShortcutsSettingsPage(appPrefs: appPrefs)
        case .updates:
            UpdatesSettingsPage(appPrefs: appPrefs)
        case .privacy:
            PrivacySettingsPage(runtime: runtime)
        case .advanced:
            AdvancedSettingsPage(appPrefs: appPrefs, runtime: runtime)
        }
    }
}

/// Hosts the widget-builder wizard inside the hub. The builder is a plain
/// SwiftUI view, so embedding it directly (rather than a launcher pane) keeps
/// the flow in one window. `onFinished` navigates back to the Widgets section
/// after a widget is created or the wizard is dismissed.
struct HubCreateView: View {
    @StateObject private var model: WidgetBuilderModel
    private let onFinished: () -> Void

    init(runtime: WidgetRuntime, onFinished: @escaping () -> Void) {
        _model = StateObject(
            wrappedValue: WidgetBuilderModel(existingGroups: runtime.bucketGroups)
        )
        self.onFinished = onFinished
        // `runtime` is captured weakly by the model callbacks below via onAppear
        // so the created widget lands through the runtime's hot reload.
        self.runtime = runtime
    }

    private let runtime: WidgetRuntime

    var body: some View {
        WidgetBuilderView(model: model)
            .onAppear { [weak runtime] in
                model.onCreated = { [weak runtime] in runtime?.loadWidgets() }
                model.onClose = { onFinished() }
            }
    }
}
