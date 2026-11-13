import Foundation
import MenubucketCore

/// What the mirror reads from the runtime, and nothing else: enough to
/// decide what may leave the app and to describe it. Read-only, so the
/// mirror can be tested against a stand-in without a `WidgetRuntime`.
@MainActor
protocol DesktopWidgetMirrorSource: AnyObject {
    var widgets: [LoadedWidget] { get }
    var snapshots: [String: WidgetSnapshot] { get }
    /// The widget's last render was marked sensitive (`sensitiveRenderIDs`).
    func hasSensitiveRender(_ widgetID: String) -> Bool
    func isDisabled(_ widgetID: String) -> Bool
    func permissionStatus(for manifest: Manifest) -> PermissionStore.Status
    func accent(for widget: LoadedWidget) -> String?
    func effectiveGroup(for id: String) -> String
    /// The user's own refresh interval for the widget, if they set one.
    func refreshIntervalOverride(for widgetID: String) -> Double?
    var refreshMultiplier: Double { get }
}

/// Mirrors the runtime's widgets onto the desktop (R14): decides which
/// widgets and which renders may leave the app, and hands those to the
/// `SharedShelfPublisher` it owns.
///
/// Main-actor isolated, like the runtime it reads and the publisher it
/// drives (which is main-thread only).
@MainActor
final class DesktopWidgetMirror {
    private let sharedShelf: SharedShelfPublisher
    /// The runtime. Weak: the runtime owns the mirror.
    weak var source: DesktopWidgetMirrorSource?

    init(sharedShelf: SharedShelfPublisher = SharedShelfPublisher()) {
        self.sharedShelf = sharedShelf
    }

    /// Whether this build can feed desktop widgets at all (App Group
    /// entitlement present).
    var isEnabled: Bool { sharedShelf.isEnabled }

    /// Whether a widget's next render answers a desktop refresh request, so
    /// it should be published without the usual throttle.
    func isAnswering(_ widgetID: String) -> Bool {
        sharedShelf.isAnswering(widgetID)
    }

    /// Starts listening for the refresh button on a desktop widget; `refresh`
    /// is called with the widget when it is one a desktop widget may mirror.
    func observeRefreshRequests(_ refresh: @escaping (LoadedWidget) -> Void) {
        sharedShelf.onRefreshRequest = { [weak self] widgetID in
            guard let self,
                  let widget = self.desktopWidgetCandidates().first(where: { $0.id == widgetID })
            else { return }
            refresh(widget)
        }
        sharedShelf.observeRefreshRequests()
    }

    /// Takes a widget out of the shared folder at once.
    func withdraw(widgetID: String) {
        sharedShelf.withdraw(widgetID: widgetID)
    }

    /// Widgets a desktop widget may mirror: everything switched on that is
    /// not sensitive, by manifest or by what it last rendered.
    private func desktopWidgetCandidates() -> [LoadedWidget] {
        guard let source else { return [] }
        return source.widgets.filter { mayMirror($0, source: source) }
    }

    /// The one answer to "may this widget leave the app", for the index and
    /// for each render. They used to differ: a render was not checked for a
    /// switched-off widget or one whose manifest declines the desktop, and
    /// relied on the publisher refusing ids that are not in the index, which
    /// it cannot do before the first index has been written.
    private func mayMirror(_ widget: LoadedWidget, source: DesktopWidgetMirrorSource) -> Bool {
        !widget.isSensitive && !source.hasSensitiveRender(widget.id) && !source.isDisabled(widget.id)
            && widget.manifest.desktop?.offer != false
            && source.permissionStatus(for: widget.manifest) == .approved
    }

    func publishIndex() {
        guard sharedShelf.isEnabled, let source else { return }
        let candidates = desktopWidgetCandidates()
        let changed = sharedShelf.publishIndex(candidates.map { widget in
            SharedShelf.Entry(
                id: widget.id,
                name: widget.displayName,
                icon: widget.manifest.icon,
                accent: source.accent(for: widget),
                page: source.effectiveGroup(for: widget.id)
            )
        })
        // A widget just offered (first launch, re-enabled) shows what BarShelf
        // already has instead of waiting for its next refresh.
        guard changed else { return }
        for widget in candidates {
            if let snapshot = source.snapshots[widget.id], snapshot.viewTree != nil {
                publish(snapshot)
            }
        }
    }

    /// Mirrors a render the cache has just kept, on the cache's 30-second
    /// throttle. Only the cache path calls this, so sensitive renders
    /// (memory-only) never get here; the checks below are the second lock.
    func publish(_ snapshot: WidgetSnapshot) {
        guard sharedShelf.isEnabled, snapshot.safeForSensitiveCache != true,
              let source,
              let widget = source.widgets.first(where: { $0.id == snapshot.widgetID }),
              mayMirror(widget, source: source)
        else { return }
        sharedShelf.publish(SharedShelf.Snapshot(
            widgetID: widget.id,
            name: widget.displayName,
            icon: widget.manifest.icon,
            accent: source.accent(for: widget),
            viewTree: snapshot.viewTree,
            updatedAt: snapshot.updatedAt,
            error: snapshot.error,
            statusLabel: snapshot.statusLabel,
            statusTint: snapshot.statusTint,
            staleAfter: SharedShelf.staleAfter(
                updatedAt: snapshot.updatedAt,
                interval: (source.refreshIntervalOverride(for: widget.id) ?? widget.manifest.refresh?.interval)
                    .map { $0 * source.refreshMultiplier },
                fallback: widget.manifest.refresh?.staleAfterSec ?? 3600
            ),
            preferredStyle: widget.manifest.desktop?.style
                .flatMap(SharedShelf.Template.init(rawValue:))?.rawValue
        ))
    }
}
