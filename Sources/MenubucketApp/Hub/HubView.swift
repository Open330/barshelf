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
            VStack(spacing: 0) {
                sidebarHeader
                List(HubTab.allCases, selection: selection) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .tag(tab)
                        .padding(.vertical, 3)
                        .accessibilityLabel(tab.title)
                }
                .listStyle(.sidebar)
                Spacer(minLength: 0)
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
        } detail: {
            VStack(spacing: 0) {
                detailHeader
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
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

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: BarShelfStatusIcon.logoImage(size: NSSize(width: 26, height: 20)))
                .renderingMode(.template)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("BarShelf")
                    .font(.system(size: 13, weight: .semibold))
                Text("Widget workspace")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebarFooter: some View {
        Text("\(runtime.widgets.count) installed")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: model.tab.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.tab.title)
                    .font(.system(size: 18, weight: .semibold))
                Text(model.tab.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
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
