import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A stand-in for the runtime: refuses writes on demand and records every
/// change it is told about.
@MainActor
private final class StubHost: CardOverlayStoreHost {
    struct Change: Equatable {
        let widgetID: String
        let overlay: CardOverlay?
    }

    var acceptsCardOverlayWrites = true
    private(set) var changes: [Change] = []

    func cardOverlayDidChange(widgetID: String, to overlay: CardOverlay?) {
        changes.append(Change(widgetID: widgetID, overlay: overlay))
    }
}

private let asked = [PermissionRequest(symbol: "key.fill", description: "asked")]

final class CardOverlayPolicyTests: XCTestCase {
    private func card(
        _ status: PermissionStore.Status, current: CardOverlay? = nil, crashLoopReason: String? = nil
    ) -> CardOverlay? {
        CardOverlayPolicy.card(
            for: status, current: current, crashLoopReason: crashLoopReason, requests: { asked }
        )
    }

    func testAPendingWidgetAsksAndADeniedOneSaysSo() {
        XCTAssertEqual(card(.pending), .approvalNeeded(asked))
        XCTAssertEqual(card(.denied), .denied(asked))
    }

    func testAnUnapprovedWidgetShowsItsPermissionCardWhateverItShowedBefore() {
        for current in [CardOverlay.approvalNeeded([]), .denied([]), .disabled(reason: "crashed")] {
            XCTAssertEqual(card(.pending, current: current, crashLoopReason: "crashed"), .approvalNeeded(asked))
            XCTAssertEqual(card(.denied, current: current, crashLoopReason: "crashed"), .denied(asked))
        }
    }

    func testAnApprovedWidgetShowsItsOwnContent() {
        XCTAssertNil(card(.approved))
        XCTAssertNil(card(.approved, current: .approvalNeeded(asked)))
        XCTAssertNil(card(.approved, current: .denied(asked)))
    }

    func testApprovalLeavesTheCardOfAWidgetStoppedAfterACrashLoop() {
        let restart = CardOverlay.disabled(reason: "crashed")
        XCTAssertEqual(card(.approved, current: restart, crashLoopReason: "crashed"), restart)
        XCTAssertNil(card(.approved, current: nil, crashLoopReason: "crashed"))
    }

    func testTheRequestsAreOnlyWorkedOutForACardThatListsThem() {
        var calls = 0
        let requests: () -> [PermissionRequest] = { calls += 1; return asked }
        _ = CardOverlayPolicy.card(for: .approved, current: .denied(asked), crashLoopReason: nil, requests: requests)
        _ = CardOverlayPolicy.card(for: .approved, current: nil, crashLoopReason: "crashed", requests: requests)
        XCTAssertEqual(calls, 0)
        _ = CardOverlayPolicy.card(for: .pending, current: nil, crashLoopReason: nil, requests: requests)
        XCTAssertEqual(calls, 1)
    }
}

@MainActor
final class CardOverlayStoreTests: XCTestCase {
    private var host: StubHost!
    private var store: CardOverlayStore!

    override func setUp() async throws {
        host = StubHost()
        store = CardOverlayStore(requests: { widget in
            [PermissionRequest(symbol: "key.fill", description: widget.id)]
        })
        store.host = host
    }

    private func widget(_ id: String) -> LoadedWidget {
        LoadedWidget(
            manifest: Manifest(schemaVersion: 1, id: id, name: id,
                               entry: .init(kind: "workflow", main: "workflow.json")),
            directory: URL(fileURLWithPath: "/nonexistent/\(id)")
        )
    }

    private func requests(_ id: String) -> [PermissionRequest] {
        [PermissionRequest(symbol: "key.fill", description: id)]
    }

    func testTheShippedRequestsAreThePermissionCardTexts() {
        let shipped = CardOverlayStore()
        let outcome = shipped.settlePermissionCard(for: widget("a"), status: .pending)
        XCTAssertEqual(outcome.card, .approvalNeeded(PermissionCardText.requests(for: widget("a"))))
    }

    func testAPendingWidgetGetsItsApprovalCardAndTheHostIsTold() {
        let outcome = store.settlePermissionCard(for: widget("a"), status: .pending)

        XCTAssertEqual(outcome, PermissionCardOutcome(card: .approvalNeeded(requests("a")), isNewRequest: true))
        XCTAssertEqual(store.overlays, ["a": .approvalNeeded(requests("a"))])
        XCTAssertEqual(host.changes, [.init(widgetID: "a", overlay: .approvalNeeded(requests("a")))])
    }

    func testTheHostIsToldOnlyWhenTheCardDiffers() {
        store.settlePermissionCard(for: widget("a"), status: .pending)
        let again = store.settlePermissionCard(for: widget("a"), status: .pending)

        XCTAssertFalse(again.isNewRequest, "the card was already up")
        XCTAssertEqual(host.changes.count, 1)

        store.settlePermissionCard(for: widget("b"), status: .approved)
        XCTAssertEqual(host.changes.count, 1, "nothing to clear")
    }

    func testTheHostIsToldAfterTheStoreHoldsTheNewCard() {
        final class Reader: CardOverlayStoreHost {
            weak var store: CardOverlayStore?
            var seen: [CardOverlay?] = []
            var acceptsCardOverlayWrites: Bool { true }
            func cardOverlayDidChange(widgetID: String, to overlay: CardOverlay?) {
                seen.append(store?.overlays[widgetID])
            }
        }
        let reader = Reader()
        reader.store = store
        store.host = reader

        store.settlePermissionCard(for: widget("a"), status: .denied)
        store.settlePermissionCard(for: widget("a"), status: .approved)

        XCTAssertEqual(reader.seen, [.denied(requests("a")), nil])
    }

    func testGoingFromAskingToDeniedIsNotANewRequest() {
        store.settlePermissionCard(for: widget("a"), status: .pending)
        let denied = store.settlePermissionCard(for: widget("a"), status: .denied)

        XCTAssertEqual(denied, PermissionCardOutcome(card: .denied(requests("a")), isNewRequest: false))
        XCTAssertEqual(host.changes.last, .init(widgetID: "a", overlay: .denied(requests("a"))))
    }

    func testApprovalTakesThePermissionCardDown() {
        store.settlePermissionCard(for: widget("a"), status: .denied)
        let approved = store.settlePermissionCard(for: widget("a"), status: .approved)

        XCTAssertEqual(approved, PermissionCardOutcome(card: nil, isNewRequest: false))
        XCTAssertTrue(store.overlays.isEmpty)
        XCTAssertEqual(host.changes.last, .init(widgetID: "a", overlay: nil))
    }

    func testAWriteTheHostRefusesChangesNothingButStillSaysWhetherTheRequestIsNew() {
        host.acceptsCardOverlayWrites = false
        let outcome = store.settlePermissionCard(for: widget("a"), status: .pending)

        XCTAssertEqual(outcome, PermissionCardOutcome(card: nil, isNewRequest: true))
        XCTAssertTrue(store.overlays.isEmpty)
        XCTAssertTrue(host.changes.isEmpty)

        store.showCrashLoopCard(reason: "crashed", for: "a")
        XCTAssertTrue(store.overlays.isEmpty)
        XCTAssertTrue(host.changes.isEmpty)
        XCTAssertTrue(store.isCrashLoopDisabled("a"), "the reason is kept without its card")
    }

    func testARefusedWriteLeavesAnExistingCardUp() {
        store.settlePermissionCard(for: widget("a"), status: .pending)
        host.acceptsCardOverlayWrites = false

        store.settlePermissionCard(for: widget("a"), status: .approved)
        store.clearAll()
        store.clearForRestart("a")

        XCTAssertEqual(store.overlays, ["a": .approvalNeeded(requests("a"))])
        XCTAssertEqual(host.changes.count, 1)
    }

    func testACrashLoopShowsTheRestartCardAndApprovalLeavesIt() {
        store.showCrashLoopCard(reason: "crashed 3 times", for: "a")

        XCTAssertTrue(store.isCrashLoopDisabled("a"))
        XCTAssertFalse(store.isCrashLoopDisabled("b"))
        XCTAssertEqual(host.changes, [.init(widgetID: "a", overlay: .disabled(reason: "crashed 3 times"))])

        let approved = store.settlePermissionCard(for: widget("a"), status: .approved)
        XCTAssertEqual(approved.card, .disabled(reason: "crashed 3 times"))
        XCTAssertEqual(host.changes.count, 1)
    }

    func testRestartTakesTheCardDownAndForgetsTheCrashLoop() {
        store.showCrashLoopCard(reason: "crashed", for: "a")
        store.clearForRestart("a")

        XCTAssertFalse(store.isCrashLoopDisabled("a"))
        XCTAssertTrue(store.overlays.isEmpty)
        XCTAssertEqual(host.changes.last, .init(widgetID: "a", overlay: nil))
    }

    func testClearingAllTakesEveryCardDownOneWriteEachAndKeepsCrashLoops() {
        store.settlePermissionCard(for: widget("a"), status: .pending)
        store.showCrashLoopCard(reason: "crashed", for: "b")
        store.clearAll()

        XCTAssertTrue(store.overlays.isEmpty)
        XCTAssertEqual(
            Set(host.changes.suffix(2)),
            [.init(widgetID: "a", overlay: nil), .init(widgetID: "b", overlay: nil)]
        )
        XCTAssertTrue(store.isCrashLoopDisabled("b"))
    }

    func testForgettingDropsGoneWidgetsWithoutTellingTheHostEvenWhenItRefusesWrites() {
        store.settlePermissionCard(for: widget("a"), status: .pending)
        store.settlePermissionCard(for: widget("b"), status: .denied)
        store.showCrashLoopCard(reason: "crashed", for: "c")
        let told = host.changes.count
        host.acceptsCardOverlayWrites = false

        store.forgetCards(notIn: ["b"])
        XCTAssertEqual(store.overlays, ["b": .denied(requests("b"))])
        XCTAssertTrue(store.isCrashLoopDisabled("c"), "cards and crash loops are forgotten separately")

        store.forgetCrashLoops(notIn: ["b"])
        XCTAssertFalse(store.isCrashLoopDisabled("c"))
        XCTAssertEqual(host.changes.count, told)
    }

    func testWithoutAHostWritesLand() {
        store.host = nil
        store.settlePermissionCard(for: widget("a"), status: .pending)
        XCTAssertEqual(store.overlays, ["a": .approvalNeeded(requests("a"))])
    }
}

extension StubHost.Change: Hashable {
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(widgetID) }
}

/// The store wired into a live runtime. Requires a disposable Foundation
/// home: never starts a live runtime against the user's installed widgets.
@MainActor
final class CardOverlayStoreRuntimeTests: XCTestCase {
    private struct Fixture {
        let runtime: WidgetRuntime
        let widget: LoadedWidget
        let files: [URL]

        var id: String { widget.id }

        func cleanUp() {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// A runtime with one workflow widget whose permissions nobody has
    /// answered yet.
    private func makeFixture() throws -> Fixture {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let tag = UUID().uuidString.lowercased()
        let id = "dev.test.cardoverlay.\(tag)"
        let widgetDirectory = root.appendingPathComponent("widgets/cardoverlay-\(tag)")
        let permissionsFile = root.appendingPathComponent("cardoverlay-permissions-\(tag).json")
        let appPrefsFile = root.appendingPathComponent("cardoverlay-app-prefs-\(tag).json")

        let manifest = Manifest(schemaVersion: 1, id: id, name: "Overlay",
                                entry: .init(kind: "workflow", main: "workflow.json"),
                                permissions: .init(storage: .init()))
        try FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: widgetDirectory.appendingPathComponent("widget.json"))
        try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"rendered"}}"#.utf8)
            .write(to: widgetDirectory.appendingPathComponent("workflow.json"))

        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: appPrefsFile),
                                    permissionStore: PermissionStore(fileURL: permissionsFile))
        let widget = try XCTUnwrap(runtime.widgets.first { $0.id == id })
        return Fixture(
            runtime: runtime, widget: widget,
            files: [widgetDirectory, permissionsFile, appPrefsFile,
                    root.appendingPathComponent("cache/\(id).json")]
        )
    }

    func testAChangedCardReachesTheObservedCardModelAndTheAttentionDot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let runtime = fixture.runtime
        let asking = CardOverlay.approvalNeeded(WidgetRuntime.permissionRequests(for: fixture.widget))

        XCTAssertEqual(runtime.overlayCards[fixture.id], asking)
        XCTAssertTrue(runtime.attention.waitingWidgetIDs.contains(fixture.id))
        XCTAssertTrue(runtime.attention.reasons.contains(.approvalNeeded))

        // The model exists from here on: later changes must be pushed to it.
        let model = runtime.cardModel(for: fixture.id)
        XCTAssertEqual(model.overlay, asking)

        runtime.approvePermissions(widgetID: fixture.id)
        XCTAssertNil(runtime.overlayCards[fixture.id])
        XCTAssertNil(model.overlay)
        XCTAssertFalse(runtime.attention.waitingWidgetIDs.contains(fixture.id))

        runtime.denyPermissions(widgetID: fixture.id)
        let denied = CardOverlay.denied(WidgetRuntime.permissionRequests(for: fixture.widget))
        XCTAssertEqual(runtime.overlayCards[fixture.id], denied)
        XCTAssertEqual(model.overlay, denied)
        XCTAssertFalse(runtime.attention.waitingWidgetIDs.contains(fixture.id), "denied is not waiting")

        runtime.revokePermissions(widgetID: fixture.id)
        XCTAssertEqual(model.overlay, asking)
        XCTAssertTrue(runtime.attention.waitingWidgetIDs.contains(fixture.id))
    }

    func testAStagedPreviewTakesTheCardsDownAndLetsNoneBackUp() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let runtime = fixture.runtime
        let model = runtime.cardModel(for: fixture.id)
        XCTAssertNotNil(model.overlay)

        runtime.stagePreview(widgets: [fixture.widget], renders: [])
        XCTAssertTrue(runtime.overlayCards.isEmpty)
        XCTAssertNil(model.overlay)

        runtime.denyPermissions(widgetID: fixture.id)
        XCTAssertTrue(runtime.overlayCards.isEmpty, "a staged preview shows only what was staged")
        XCTAssertNil(model.overlay)
    }
}
