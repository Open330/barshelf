import AppKit
import Combine
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A stand-in for the runtime: refuses writes on demand and records every
/// change it is told about, with what the store and the card model held at
/// that moment.
@MainActor
private final class StubHost: SnapshotStoreHost {
    struct Change: Equatable {
        let widgetID: String
        let previous: WidgetSnapshot?
        let snapshot: WidgetSnapshot
    }

    var acceptsSnapshotWrites = true
    private(set) var changes: [Change] = []
    /// Read when a change is reported.
    var whenTold: () -> Void = {}

    func snapshotDidChange(widgetID: String, from previous: WidgetSnapshot?, to snapshot: WidgetSnapshot) {
        changes.append(Change(widgetID: widgetID, previous: previous, snapshot: snapshot))
        whenTold()
    }
}

@MainActor
final class SnapshotStoreTests: XCTestCase {
    private var host: StubHost!
    private var store: SnapshotStore!
    private var observers: Set<AnyCancellable> = []

    override func setUp() async throws {
        host = StubHost()
        store = SnapshotStore()
        store.host = host
        observers = []
    }

    private func render(_ id: String, _ text: String, error: String? = nil) -> WidgetSnapshot {
        WidgetSnapshot(widgetID: id, viewTree: UINode(type: "text", text: text), error: error)
    }

    /// Counts how often the model announces a change.
    private func publishes(of model: WidgetCardModel) -> () -> Int {
        var count = 0
        model.objectWillChange.sink { count += 1 }.store(in: &observers)
        return { count }
    }

    // MARK: - Writing

    func testAFirstSnapshotIsHeldAndTheHostIsTold() {
        let first = render("a", "one")
        store.set(first, for: "a")
        XCTAssertEqual(store.snapshots, ["a": first])
        XCTAssertEqual(host.changes, [.init(widgetID: "a", previous: nil, snapshot: first)])
    }

    func testAChangedSnapshotIsReportedWithTheOneItReplaced() {
        let first = render("a", "one")
        let second = render("a", "two")
        store.set(first, for: "a")
        store.set(second, for: "a")
        XCTAssertEqual(store.snapshots["a"], second)
        XCTAssertEqual(host.changes.last, .init(widgetID: "a", previous: first, snapshot: second))
        XCTAssertEqual(host.changes.count, 2)
    }

    func testAnUnchangedSnapshotIsNeitherPublishedNorReported() {
        let first = render("a", "one")
        store.set(first, for: "a")
        let count = publishes(of: store.cardModel(for: "a", overlay: nil))
        store.set(first, for: "a")
        store.update("a") { _ in }
        XCTAssertEqual(host.changes.count, 1)
        XCTAssertEqual(count(), 0)
    }

    func testAChangePublishesOnThatWidgetsCardModelOnly() {
        store.set(render("a", "one"), for: "a")
        store.set(render("b", "one"), for: "b")
        let a = store.cardModel(for: "a", overlay: nil)
        let b = store.cardModel(for: "b", overlay: nil)
        let aCount = publishes(of: a)
        let bCount = publishes(of: b)

        let next = render("a", "two")
        store.set(next, for: "a")
        XCTAssertEqual(a.snapshot, next)
        XCTAssertEqual(aCount(), 1, "one change, one announcement")
        XCTAssertEqual(bCount(), 0)
        XCTAssertEqual(b.snapshot, render("b", "one"))
    }

    func testTheHostIsToldAfterTheStoreAndTheCardModelHoldTheNewSnapshot() {
        store.set(render("a", "one"), for: "a")
        let model = store.cardModel(for: "a", overlay: nil)
        let next = render("a", "two")
        var seen: [WidgetSnapshot?] = []
        host.whenTold = { [store] in seen = [store?.snapshots["a"], model.snapshot] }
        store.set(next, for: "a")
        XCTAssertEqual(seen, [next, next])
    }

    func testWhileTheHostRefusesWritesNothingChanges() {
        let staged = render("a", "staged")
        store.set(staged, for: "a")
        let model = store.cardModel(for: "a", overlay: nil)
        let count = publishes(of: model)
        host.acceptsSnapshotWrites = false

        store.set(render("a", "live"), for: "a")
        store.update("a") { $0.isLoading = true }
        store.set(render("b", "live"), for: "b")
        XCTAssertEqual(store.snapshots, ["a": staged])
        XCTAssertEqual(model.snapshot, staged)
        XCTAssertEqual(count(), 0)
        XCTAssertEqual(host.changes.count, 1)

        host.acceptsSnapshotWrites = true
        store.set(render("a", "live"), for: "a")
        XCTAssertEqual(model.snapshot, render("a", "live"))
    }

    func testWithoutAHostWritesLand() {
        store.host = nil
        store.set(render("a", "one"), for: "a")
        XCTAssertEqual(store.snapshots["a"], render("a", "one"))
        XCTAssertTrue(host.changes.isEmpty)
    }

    // MARK: - Updating in place

    func testAnUpdateChangesTheCurrentSnapshot() {
        store.set(render("a", "one"), for: "a")
        store.update("a") { $0.error = "failed" }
        XCTAssertEqual(store.snapshots["a"], render("a", "one", error: "failed"), "the render stays")
        XCTAssertEqual(host.changes.last?.previous, render("a", "one"))
    }

    func testAnUpdateOfAWidgetWithNoSnapshotStartsFromAnEmptyOne() {
        store.update("a") { $0.isLoading = true }
        XCTAssertEqual(store.snapshots["a"], WidgetSnapshot(widgetID: "a", isLoading: true))
        XCTAssertEqual(host.changes, [
            .init(widgetID: "a", previous: nil, snapshot: WidgetSnapshot(widgetID: "a", isLoading: true)),
        ])
    }

    func testAnUpdateThatChangesNothingStillGivesAnUnknownWidgetItsEmptySnapshot() {
        store.update("a") { _ in }
        XCTAssertEqual(store.snapshots["a"], WidgetSnapshot(widgetID: "a"))
        XCTAssertEqual(host.changes.count, 1)
    }

    // MARK: - Card models

    func testACardModelStartsFromTheSnapshotAndTheCardShownNow() {
        let current = render("a", "one")
        store.set(current, for: "a")
        let card = CardOverlay.disabled(reason: "crashed")
        let model = store.cardModel(for: "a", overlay: card)
        XCTAssertEqual(model.snapshot, current)
        XCTAssertEqual(model.overlay, card)
    }

    func testACardModelIsMadeOnceAndKept() {
        let model = store.cardModel(for: "a", overlay: nil)
        // The card passed later is not applied: changes come by `setOverlay`.
        let again = store.cardModel(for: "a", overlay: .disabled(reason: "crashed"))
        XCTAssertTrue(model === again)
        XCTAssertNil(again.overlay)
    }

    func testACardModelForAWidgetWithNoSnapshotShowsAnEmptyOneAndStoresNone() {
        let model = store.cardModel(for: "a", overlay: nil)
        XCTAssertEqual(model.snapshot, WidgetSnapshot(widgetID: "a"))
        XCTAssertNil(store.snapshots["a"])
        XCTAssertTrue(host.changes.isEmpty)
    }

    func testAChangedCardIsPublishedOnTheWidgetsCardModel() {
        let model = store.cardModel(for: "a", overlay: nil)
        let count = publishes(of: model)
        store.setOverlay(.disabled(reason: "crashed"), for: "a")
        XCTAssertEqual(model.overlay, .disabled(reason: "crashed"))
        XCTAssertEqual(count(), 1)
        store.setOverlay(nil, for: "a")
        XCTAssertNil(model.overlay)
        XCTAssertTrue(host.changes.isEmpty, "a card is not a snapshot change")
    }

    func testAChangedCardIsPublishedEvenWhileSnapshotWritesAreRefused() {
        let model = store.cardModel(for: "a", overlay: .disabled(reason: "crashed"))
        host.acceptsSnapshotWrites = false
        store.setOverlay(nil, for: "a")
        XCTAssertNil(model.overlay, "the card store has its own gate")
    }

    func testACardForAWidgetNobodyObservesMakesNoCardModel() {
        store.setOverlay(.disabled(reason: "crashed"), for: "a")
        // The model made afterwards starts from what it is handed.
        XCTAssertNil(store.cardModel(for: "a", overlay: nil).overlay)
    }

    // MARK: - Housekeeping

    func testForgettingDropsTheSnapshotsAndCardModelsOfWidgetsThatAreGone() {
        store.set(render("a", "one"), for: "a")
        store.set(render("b", "one"), for: "b")
        let a = store.cardModel(for: "a", overlay: nil)
        let b = store.cardModel(for: "b", overlay: nil)
        let told = host.changes.count

        store.forget(notIn: ["b"])
        XCTAssertEqual(store.snapshots, ["b": render("b", "one")])
        XCTAssertEqual(host.changes.count, told, "not a write: the host is not told")
        XCTAssertTrue(store.cardModel(for: "b", overlay: nil) === b)
        let reinstalled = store.cardModel(for: "a", overlay: nil)
        XCTAssertFalse(reinstalled === a)
        XCTAssertEqual(reinstalled.snapshot, WidgetSnapshot(widgetID: "a"))
    }

    func testForgettingIsNotHeldBackByARefusedWrite() {
        store.set(render("a", "one"), for: "a")
        host.acceptsSnapshotWrites = false
        store.forget(notIn: [])
        XCTAssertTrue(store.snapshots.isEmpty)
    }
}

/// The runtime wired to its store. Requires a disposable Foundation home,
/// like RefreshAgainTests: run with CFFIXED_USER_HOME set to a
/// barshelf-quality-home-* directory.
@MainActor
final class SnapshotStoreRuntimeTests: XCTestCase {
    private func makeRuntime() throws -> (WidgetRuntime, LoadedWidget, cleanUp: () -> Void) {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let tag = UUID().uuidString.lowercased()
        let permissionsFile = root.appendingPathComponent("snapshot-store-permissions-\(tag).json")
        let appPrefsFile = root.appendingPathComponent("snapshot-store-app-prefs-\(tag).json")
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: appPrefsFile),
                                    permissionStore: PermissionStore(fileURL: permissionsFile))
        // Never on disk: a staged preview takes its widgets as given.
        let widget = LoadedWidget(
            manifest: Manifest(schemaVersion: 1, id: "dev.test.snapshot-store.\(tag)", name: "Staged",
                               entry: .init(kind: "workflow", main: "workflow.json"),
                               statusItem: .init(mode: "dynamic")),
            directory: URL(fileURLWithPath: "/nonexistent/snapshot-store-\(tag)")
        )
        return (runtime, widget, {
            try? FileManager.default.removeItem(at: permissionsFile)
            try? FileManager.default.removeItem(at: appPrefsFile)
        })
    }

    /// A staged render goes through the store to everything that follows a
    /// snapshot: the runtime's own view of it, the observed card model, and
    /// the attention the status item shows.
    func testAStagedRenderReachesTheCardModelAndTheAttention() throws {
        let (runtime, widget, cleanUp) = try makeRuntime()
        defer { cleanUp() }
        let id = widget.id
        let first = WidgetSnapshot(widgetID: id, viewTree: UINode(type: "text", text: "one"), updatedAt: Date())
        runtime.stagePreview(widgets: [widget], renders: [first])
        XCTAssertEqual(runtime.snapshots[id], first)
        let model = runtime.cardModel(for: id)
        XCTAssertEqual(model.snapshot, first)
        XCTAssertFalse(runtime.attention.problems.contains { $0.widgetID == id })

        var modelPublishes = 0
        var runtimePublishes = 0
        let watchingModel = model.objectWillChange.sink { modelPublishes += 1 }
        let watchingRuntime = runtime.objectWillChange.sink { runtimePublishes += 1 }
        defer { watchingModel.cancel(); watchingRuntime.cancel() }

        var failed = first
        failed.error = "broken"
        runtime.stageRender(failed)
        XCTAssertEqual(runtime.snapshots[id], failed)
        XCTAssertEqual(model.snapshot, failed)
        XCTAssertEqual(modelPublishes, 1, "one change, one announcement on the card")
        XCTAssertEqual(runtimePublishes, 0, "a snapshot change does not announce on the runtime")
        XCTAssertTrue(runtime.attention.problems.contains { $0.widgetID == id },
                      "the changed error reaches the attention")

        runtime.stageRender(failed)
        XCTAssertEqual(modelPublishes, 1, "an unchanged render is not published again")
    }

    /// A new reading of a widget the menu bar owns goes on to its reading
    /// history and, with the next batched sync, to the menu bar itself.
    func testAStagedReadingReachesTheReadingHistoryAndTheMenuBar() async throws {
        let (runtime, widget, cleanUp) = try makeRuntime()
        defer { cleanUp() }
        let id = widget.id
        runtime.permissionStore.approve(widget.manifest)
        runtime.stagePreview(widgets: [widget], renders: [])
        runtime.setMenuBarPlacement(.init(enabled: true), for: id)
        defer { runtime.setMenuBarPlacement(nil, for: id) }
        XCTAssertTrue(runtime.menuBarWidgetIDs.contains(id))
        XCTAssertNil(runtime.readingHistory.values[id])
        // The runtime syncs the menu bar once more after it is made, when
        // its preferences arrive on the main run loop. This subscription
        // was made later, so it hears after that one: from here on, only
        // the snapshot's own report can ask for a sync.
        let settled = expectation(description: "the runtime took its preferences")
        let hearing = runtime.appPrefs.$preferences.receive(on: RunLoop.main).first().sink { _ in settled.fulfill() }
        await fulfillment(of: [settled], timeout: 10)
        hearing.cancel()

        runtime.stageRender(WidgetSnapshot(
            widgetID: id, viewTree: UINode(type: "text", text: "42"), updatedAt: Date(), statusLabel: "42",
            statusMetrics: [StatusMetric(label: "load", value: "42", number: 42)]
        ))
        XCTAssertEqual(runtime.readingHistory.values[id], [42])

        func shown() -> Bool {
            runtime.ownedMenuBarEntries.contains {
                $0.widgetID == id && $0.label == MenuBarPolicy.normalizedLabel("42")
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while !shown() {
            guard Date() < deadline else { return XCTFail("timed out waiting for the menu bar to show the reading") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Once a preview is staged, only staged renders are written: anything
    /// else that would change a snapshot leaves it as staged.
    func testAStagedPreviewRefusesEveryOtherSnapshotWrite() throws {
        let (runtime, widget, cleanUp) = try makeRuntime()
        defer { cleanUp() }
        let id = widget.id
        let staged = WidgetSnapshot(widgetID: id, viewTree: UINode(type: "text", text: "one"), isLoading: true)
        runtime.stagePreview(widgets: [widget], renders: [staged])
        let model = runtime.cardModel(for: id)

        // Denying withdraws the widget's reading: a snapshot write like any
        // other, from outside the stage.
        runtime.denyPermissions(widgetID: id)
        XCTAssertEqual(runtime.snapshots[id], staged)
        XCTAssertEqual(model.snapshot, staged)

        var next = staged
        next.isLoading = false
        runtime.stageRender(next)
        XCTAssertEqual(model.snapshot, next, "a staged render is still written")
    }
}
