import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Stands in for the runtime: only the reads the mirror is given.
@MainActor
private final class StubSource: DesktopWidgetMirrorSource {
    var widgets: [LoadedWidget] = []
    var snapshots: [String: WidgetSnapshot] = [:]
    var sensitiveRenders: Set<String> = []
    var disabled: Set<String> = []
    /// By manifest id; anything not listed is approved.
    var statuses: [String: PermissionStore.Status] = [:]
    var accents: [String: String] = [:]
    var groups: [String: String] = [:]
    var intervalOverrides: [String: Double] = [:]
    var refreshMultiplier: Double = 1

    func hasSensitiveRender(_ widgetID: String) -> Bool { sensitiveRenders.contains(widgetID) }
    func isDisabled(_ widgetID: String) -> Bool { disabled.contains(widgetID) }
    func permissionStatus(for manifest: Manifest) -> PermissionStore.Status { statuses[manifest.id] ?? .approved }
    func accent(for widget: LoadedWidget) -> String? { accents[widget.id] }
    func effectiveGroup(for id: String) -> String { groups[id] ?? "General" }
    func refreshIntervalOverride(for widgetID: String) -> Double? { intervalOverrides[widgetID] }
}

@MainActor
final class DesktopWidgetMirrorTests: XCTestCase {
    private var container: URL!
    private var source: StubSource!

    override func setUp() async throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-mirror-\(UUID().uuidString)", isDirectory: true)
        source = StubSource()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func makeMirror(
        placementProbe: SharedShelfPublisher.PlacementProbe? = nil
    ) -> (DesktopWidgetMirror, SharedShelfPublisher) {
        let publisher = SharedShelfPublisher(
            container: container, reload: {}, scheduleRefreshTimeout: { _ in },
            placementProbe: placementProbe
        )
        let mirror = DesktopWidgetMirror(sharedShelf: publisher)
        mirror.source = source
        return (mirror, publisher)
    }

    private func widget(
        _ id: String, permissions: Manifest.Permissions? = nil,
        refresh: Manifest.Refresh? = nil, desktop: Manifest.Desktop? = nil
    ) -> LoadedWidget {
        LoadedWidget(
            manifest: Manifest(
                schemaVersion: 1, id: id, name: "Name of \(id)", icon: "gauge",
                entry: .init(kind: "exec"), refresh: refresh, permissions: permissions, desktop: desktop
            ),
            directory: container
        )
    }

    private func render(_ id: String, _ text: String = "reading", safeForSensitiveCache: Bool? = nil) -> WidgetSnapshot {
        WidgetSnapshot(
            widgetID: id, viewTree: UINode(type: "text", text: text),
            // Whole seconds: the shared file keeps dates to the second.
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), statusLabel: text,
            safeForSensitiveCache: safeForSensitiveCache
        )
    }

    private func offeredIDs() -> [String]? {
        SharedShelf.readIndex(from: container)?.entries.map(\.id)
    }

    private func shared(_ id: String) -> SharedShelf.Snapshot? {
        SharedShelf.readSnapshot(widgetID: id, from: container)
    }

    // MARK: - The index: which widgets may be offered

    func testIndexOffersAnApprovedEnabledPlainWidgetWithItsDescription() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain")]
        source.accents = ["plain": "teal"]
        source.groups = ["plain": "Work"]

        mirror.publishIndex()

        XCTAssertEqual(
            SharedShelf.readIndex(from: container)?.entries,
            [.init(id: "plain", name: "Name of plain", icon: "gauge", accent: "teal", page: "Work")]
        )
    }

    func testIndexNeverOffersAWidgetSensitiveByManifest() {
        let (mirror, _) = makeMirror()
        source.widgets = [
            widget("plain"),
            widget("secret-output", permissions: .init(exec: [.init(command: "/bin/sh", sensitiveOutput: true)])),
            widget("vault", permissions: .init(vault: .init(provider: "bitwarden"))),
        ]
        mirror.publishIndex()
        XCTAssertEqual(offeredIDs(), ["plain"])
    }

    func testIndexNeverOffersAWidgetWhoseLastRenderWasSensitive() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain"), widget("rendered-secret")]
        source.sensitiveRenders = ["rendered-secret"]
        mirror.publishIndex()
        XCTAssertEqual(offeredIDs(), ["plain"])
    }

    func testIndexNeverOffersADisabledWidget() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain"), widget("off")]
        source.disabled = ["off"]
        mirror.publishIndex()
        XCTAssertEqual(offeredIDs(), ["plain"])
    }

    func testIndexNeverOffersAnUnapprovedOrDeniedWidget() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain"), widget("pending"), widget("denied")]
        source.statuses = ["pending": .pending, "denied": .denied]
        mirror.publishIndex()
        XCTAssertEqual(offeredIDs(), ["plain"])
    }

    func testIndexLeavesOutAWidgetWhoseManifestDeclinesTheDesktop() {
        let (mirror, _) = makeMirror()
        source.widgets = [
            widget("plain"), widget("declined", desktop: .init(offer: false)),
            widget("offered", desktop: .init(offer: true)),
        ]
        mirror.publishIndex()
        XCTAssertEqual(offeredIDs(), ["plain", "offered"])
    }

    /// A widget that stops qualifying leaves the index, and its shared
    /// render goes with it.
    func testAWidgetThatTurnsSensitiveOrIsSwitchedOffLeavesTheSharedFolder() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("a"), widget("b")]
        source.snapshots = ["a": render("a"), "b": render("b")]
        mirror.publishIndex()
        XCTAssertNotNil(shared("a"))
        XCTAssertNotNil(shared("b"))

        source.sensitiveRenders = ["a"]
        source.disabled = ["b"]
        mirror.publishIndex()

        XCTAssertEqual(offeredIDs(), [])
        XCTAssertNil(shared("a"))
        XCTAssertNil(shared("b"))
    }

    // MARK: - Renders: the second lock
    //
    // No index is published in these, so the publisher's own "not in the
    // index" check is out of the way and only the mirror's checks decide.

    func testPublishWritesAnApprovedPlainWidgetsRender() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain")]
        mirror.publish(render("plain", "42%"))
        XCTAssertEqual(shared("plain")?.viewTree?.text, "42%")
    }

    func testPublishNeverWritesTheCacheSafeCopyOfASensitiveRender() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain")]
        mirror.publish(render("plain", safeForSensitiveCache: true))
        XCTAssertNil(shared("plain"))
    }

    func testPublishNeverWritesARenderOfAWidgetWhoseLastRenderWasSensitive() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain")]
        source.sensitiveRenders = ["plain"]
        mirror.publish(render("plain"))
        XCTAssertNil(shared("plain"))
    }

    func testPublishNeverWritesARenderOfAWidgetSensitiveByManifest() {
        let (mirror, _) = makeMirror()
        source.widgets = [
            widget("secret-output", permissions: .init(exec: [.init(command: "/bin/sh", sensitiveOutput: true)])),
            widget("vault", permissions: .init(vault: .init(provider: "bitwarden"))),
        ]
        mirror.publish(render("secret-output"))
        mirror.publish(render("vault"))
        XCTAssertNil(shared("secret-output"))
        XCTAssertNil(shared("vault"))
    }

    func testPublishNeverWritesARenderOfAnUnapprovedOrDeniedWidget() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("pending"), widget("denied")]
        source.statuses = ["pending": .pending, "denied": .denied]
        mirror.publish(render("pending"))
        mirror.publish(render("denied"))
        XCTAssertNil(shared("pending"))
        XCTAssertNil(shared("denied"))
    }

    func testPublishNeverWritesARenderOfAWidgetThatIsNotLoaded() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain")]
        mirror.publish(render("gone"))
        XCTAssertNil(shared("gone"))
    }

    /// `publish` itself does not look at the disabled flag: a disabled widget
    /// is kept out by the index it is no longer in.
    func testPublishNeverWritesARenderOfADisabledWidgetOnceTheIndexIsOut() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain"), widget("off")]
        source.disabled = ["off"]
        mirror.publishIndex()
        mirror.publish(render("off"))
        mirror.publish(render("plain"))
        XCTAssertNil(shared("off"))
        XCTAssertNotNil(shared("plain"))
    }

    func testNothingIsPublishedWithoutARuntimeOrWithoutTheAppGroup() {
        let (orphan, _) = makeMirror()
        orphan.source = nil
        orphan.publishIndex()
        orphan.publish(render("plain"))
        XCTAssertNil(SharedShelf.readIndex(from: container))
        XCTAssertNil(shared("plain"))

        let unentitled = DesktopWidgetMirror(sharedShelf: SharedShelfPublisher(container: nil))
        source.widgets = [widget("plain")]
        unentitled.source = source
        XCTAssertFalse(unentitled.isEnabled)
        unentitled.publishIndex()
        unentitled.publish(render("plain"))
        unentitled.withdraw(widgetID: "plain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
    }

    // MARK: - What a published render says

    func testPublishedRenderCarriesTheWidgetsDescriptionAndStaleTime() {
        let (mirror, _) = makeMirror()
        source.widgets = [
            widget("timed", refresh: .init(interval: 600, staleAfterSec: 7200), desktop: .init(style: "meters")),
            widget("overridden", refresh: .init(interval: 600)),
            widget("untimed", refresh: .init(staleAfterSec: 7200), desktop: .init(style: "no-such-style")),
        ]
        source.accents = ["timed": "teal"]
        source.intervalOverrides = ["overridden": 1000]
        source.refreshMultiplier = 3
        var failed = render("timed", "42%")
        failed.error = "offline"
        failed.statusTint = "red"

        mirror.publish(failed)
        mirror.publish(render("overridden"))
        mirror.publish(render("untimed"))

        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let timed = shared("timed")
        XCTAssertEqual(timed?.name, "Name of timed")
        XCTAssertEqual(timed?.icon, "gauge")
        XCTAssertEqual(timed?.accent, "teal")
        XCTAssertEqual(timed?.updatedAt, updatedAt)
        XCTAssertEqual(timed?.error, "offline")
        XCTAssertEqual(timed?.statusLabel, "42%")
        XCTAssertEqual(timed?.statusTint, "red")
        XCTAssertEqual(timed?.preferredStyle, "meters")
        // Two of the widget's intervals, scaled by the app-wide multiplier.
        XCTAssertEqual(timed?.staleAfter, updatedAt.addingTimeInterval(600 * 3 * 2))
        // The user's own interval wins over the manifest's.
        XCTAssertEqual(shared("overridden")?.staleAfter, updatedAt.addingTimeInterval(1000 * 3 * 2))
        // No interval at all: the manifest's stale time.
        XCTAssertEqual(shared("untimed")?.staleAfter, updatedAt.addingTimeInterval(7200))
        XCTAssertNil(shared("untimed")?.preferredStyle)
    }

    // MARK: - Index changes bring what the app already has

    func testAChangedIndexPublishesTheRendersAlreadyHeldAndAnUnchangedOneDoesNot() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("has-render"), widget("loading"), widget("secret")]
        source.sensitiveRenders = ["secret"]
        source.snapshots = [
            "has-render": render("has-render", "first"),
            "loading": WidgetSnapshot(widgetID: "loading", isLoading: true),
            "secret": render("secret"),
        ]

        mirror.publishIndex()

        XCTAssertEqual(shared("has-render")?.viewTree?.text, "first")
        XCTAssertNil(shared("loading"), "nothing rendered yet: nothing to show")
        XCTAssertNil(shared("secret"))

        // Same index again: renders ride the cache's throttle, not this.
        source.snapshots["has-render"] = render("has-render", "second")
        mirror.publishIndex()
        XCTAssertEqual(shared("has-render")?.viewTree?.text, "first")
    }

    // MARK: - Placement (#266) still decides through the mirror

    func testRendersAreHeldWhileNoDesktopWidgetIsPlaced() {
        var answer: ((Int?) -> Void)?
        let (mirror, publisher) = makeMirror(placementProbe: { answer = $0 })
        source.widgets = [widget("plain")]
        mirror.publishIndex()
        publisher.refreshPlacementIfDue()
        answer?(0)

        mirror.publish(render("plain", "held"))
        XCTAssertNil(shared("plain"))

        publisher.placementChanged(to: 1)
        XCTAssertEqual(shared("plain")?.viewTree?.text, "held")
    }

    // MARK: - Refresh requests and withdrawal

    func testADesktopRefreshRequestReachesOnlyAWidgetThatMayBeMirrored() throws {
        let (mirror, publisher) = makeMirror()
        source.widgets = [widget("plain"), widget("turned-secret")]
        mirror.publishIndex()
        var refreshed: [String] = []
        mirror.observeRefreshRequests { refreshed.append($0.id) }

        // Sensitive since the index was written, which still lists it.
        source.sensitiveRenders = ["turned-secret"]
        XCTAssertFalse(mirror.isAnswering("plain"))
        try SharedShelf.requestRefresh(widgetID: "plain", in: container)
        try SharedShelf.requestRefresh(widgetID: "turned-secret", in: container)
        publisher.takeRefreshRequests()

        XCTAssertEqual(refreshed, ["plain"])
        XCTAssertTrue(mirror.isAnswering("plain"))

        // The answer goes out and the request is done.
        mirror.publish(render("plain", "fresh"))
        XCTAssertEqual(shared("plain")?.viewTree?.text, "fresh")
        XCTAssertFalse(mirror.isAnswering("plain"))
    }

    func testWithdrawTakesTheRenderOutOfTheSharedFolderAtOnce() {
        let (mirror, _) = makeMirror()
        source.widgets = [widget("plain")]
        mirror.publishIndex()
        mirror.publish(render("plain"))
        XCTAssertNotNil(shared("plain"))

        mirror.withdraw(widgetID: "plain")

        XCTAssertNil(shared("plain"))
    }
}
