import MenubucketCore
import SwiftUI

/// Root of the hub window: a sidebar (Widgets / Gallery / Create / Settings)
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
            List(HubTab.allCases, selection: selection) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .tag(tab)
                    .accessibilityLabel(tab.title)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
            .listStyle(.sidebar)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.tab.title)
        .background(
            // ⌘, jumps to Settings while the hub is key (Esc intentionally does
            // not close — this is a real window, not the popup).
            Button("", action: { model.tab = .settings })
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
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
        case .widgets:
            HubWidgetsView(runtime: runtime)
        case .gallery:
            GalleryView(model: galleryModel)
                .onAppear { galleryModel.onWindowShown() }
        case .create:
            HubCreateView(runtime: runtime) { model.tab = .widgets }
        case .settings:
            AppSettingsView(appPrefs: appPrefs, runtime: runtime)
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
            .onAppear {
                model.onCreated = { [weak runtime] in runtime?.loadWidgets() }
                model.onClose = { onFinished() }
            }
    }
}
