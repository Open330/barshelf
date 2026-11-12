import AppKit
import SwiftUI
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Feedback that reaches the person on the surface they acted on: refreshes
/// turned away say why, failed actions get a toast instead of a refresh
/// error, and staleness is one rule everywhere.
@MainActor
final class FeedbackChannelTests: XCTestCase {
    private struct Fixture {
        let id: String
        let manifest: Manifest
        let runtime: WidgetRuntime
        let permissions: PermissionStore
        let directory: URL
    }

    private func makeRuntime(
        approve: Bool = true,
        exec: [Manifest.ExecPermission] = [.init(command: "/bin/sh")],
        interval: Double? = nil
    ) throws -> Fixture {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("requires a disposable barshelf-quality-home-* Foundation home")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let id = "dev.test.feedback-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = root.appendingPathComponent("widgets/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let manifest = Manifest(
            schemaVersion: 1, id: id, name: "Feedback",
            entry: .init(kind: "workflow", main: "workflow.json"),
            refresh: interval.map { .init(interval: $0) },
            permissions: .init(exec: exec)
        )
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("widget.json"))
        try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"ready"}}"#.utf8)
            .write(to: directory.appendingPathComponent("workflow.json"))
        let permissions = PermissionStore(fileURL: root.appendingPathComponent("feedback-permissions-\(id).json"))
        if approve { permissions.approve(manifest) }
        let runtime = WidgetRuntime(
            appPrefs: AppPrefs(fileURL: root.appendingPathComponent("feedback-app-prefs-\(id).json")),
            permissionStore: permissions
        )
        runtime.loadWidgets()
        return Fixture(id: id, manifest: manifest, runtime: runtime, permissions: permissions, directory: directory)
    }

    // MARK: Refresh turned away

    func testRefreshTurnedAwayReturnsWhyAndSaysSoOnItsSurface() throws {
        let fixture = try makeRuntime(approve: false)
        var said: [RuntimeFeedback] = []
        fixture.runtime.feedback = { said.append($0) }

        XCTAssertEqual(fixture.runtime.requestRefresh(widgetID: fixture.id), .waitingForPermission)
        fixture.runtime.requestRefresh(widgetID: fixture.id, feedbackOn: .dock)
        XCTAssertEqual(said.map(\.surface), [.dock])
        XCTAssertTrue(said.first?.message.contains("Feedback") == true, "names the widget")
        XCTAssertNotNil(said.first?.detail, "says what to do, and stays up long enough to read")
        XCTAssertEqual(said.first?.tone, .failure)

        fixture.permissions.approve(fixture.manifest)
        fixture.runtime.prefs.setDisabled(fixture.id, true)
        defer { fixture.runtime.prefs.setDisabled(fixture.id, false) }
        XCTAssertEqual(fixture.runtime.requestRefresh(widgetID: fixture.id), .disabled)

        fixture.runtime.prefs.setDisabled(fixture.id, false)
        said.removeAll()
        XCTAssertNil(fixture.runtime.requestRefresh(widgetID: fixture.id))
        fixture.runtime.requestRefresh(widgetID: fixture.id, feedbackOn: .popup)
        XCTAssertEqual(said, [], "a refresh that runs needs no toast")
    }

    func testEachRejectionHasItsOwnWords() {
        let messages = [RefreshRejection.disabled, .waitingForPermission, .needsNewerBarShelf]
            .map { $0.message(widgetName: "Weather") }
        XCTAssertEqual(Set(messages).count, 3)
        XCTAssertTrue(messages.allSatisfy { $0.hasPrefix("Weather ") })
        XCTAssertEqual(Set([RefreshRejection.disabled, .waitingForPermission, .needsNewerBarShelf].map(\.detail)).count, 3)
    }

    // MARK: Action failures

    func testFailedActionToastsAndLeavesTheReadingAlone() async throws {
        let fixture = try makeRuntime()
        var said: [RuntimeFeedback] = []
        fixture.runtime.feedback = { said.append($0) }
        let errorBefore = fixture.runtime.snapshots[fixture.id]?.error

        let task = try XCTUnwrap(fixture.runtime.performRun(
            action: NodeAction(type: "run", command: ["/bin/sh", "-c", "exit 3"]),
            widgetID: fixture.id, title: "Restart", surface: .menuBarCard
        ))
        await task.value

        XCTAssertEqual(fixture.runtime.snapshots[fixture.id]?.error, errorBefore,
                       "an action failure is not a refresh failure")
        XCTAssertEqual(said.count, 1)
        XCTAssertEqual(said.first?.message, "Couldn’t Restart")
        XCTAssertEqual(said.first?.tone, .failure)
        XCTAssertEqual(said.first?.surface, .menuBarCard)
        XCTAssertFalse(said.first?.detail?.contains("run action failed") ?? true)
    }

    func testBlockedActionIsExplainedToo() throws {
        let fixture = try makeRuntime()
        var said: [RuntimeFeedback] = []
        fixture.runtime.feedback = { said.append($0) }
        XCTAssertNil(fixture.runtime.performRun(
            action: NodeAction(type: "run", command: ["/usr/bin/true"]), widgetID: fixture.id, surface: .popup
        ))
        XCTAssertEqual(said.map(\.message), ["That didn’t work"], "a button without words still gets a toast")
    }

    func testActionFailureTitle() {
        XCTAssertEqual(WidgetRuntime.actionFailureTitle("Restart"), "Couldn’t Restart")
        XCTAssertEqual(WidgetRuntime.actionFailureTitle("  "), "That didn’t work")
        XCTAssertEqual(WidgetRuntime.actionFailureTitle(nil), "That didn’t work")
    }

    // MARK: Staleness

    /// The card under a menu bar item dims at the same moment as the item:
    /// against the user's interval, not the author's.
    func testStalenessFollowsTheUsersInterval() throws {
        let fixture = try makeRuntime(interval: 10)
        let widget = try XCTUnwrap(fixture.runtime.widgets.first { $0.id == fixture.id })
        let now = Date()
        let ninetySecondsAgo = now.addingTimeInterval(-90)
        XCTAssertTrue(fixture.runtime.readingIsStale(widget, updatedAt: ninetySecondsAgo, now: now),
                      "author's 10 s → stale after the 60 s floor")
        fixture.runtime.prefs.setRefreshInterval(60, for: fixture.id)
        XCTAssertFalse(fixture.runtime.readingIsStale(widget, updatedAt: ninetySecondsAgo, now: now),
                       "user's 60 s → not stale until 180 s")
        XCTAssertTrue(fixture.runtime.readingIsStale(widget, updatedAt: now.addingTimeInterval(-200), now: now))
    }

    func testOneStaleDimEverywhere() {
        XCTAssertEqual(Double(MenuBarController.staleOpacity), Fill.staleOpacity, accuracy: 0.0001)
        XCTAssertEqual(Double(MenuBarController.ChipMetrics.staleAlpha), Fill.staleOpacity, accuracy: 0.0001)
    }

    func testMenuBarTooltipExplainsTheError() {
        let tooltip = WidgetRuntime.errorTooltip("HTTP 503 from https://example.com/api")
        XCTAssertFalse(tooltip.contains("https://"))
        XCTAssertTrue(tooltip.contains("503"))
    }

    // MARK: Toasts

    func testToastsGoToTheSurfaceTheyWereRaisedOn() {
        let toasts = ToastCenter(announcer: AnnouncementSink())
        toasts.show("Copied", on: .dock)
        XCTAssertEqual(toasts.current?.surface, .dock)
        // A toast that names no surface follows the last one acted on.
        toasts.show("Unlocked")
        XCTAssertEqual(toasts.current?.surface, .dock)
        toasts.lastSurface = .hub
        toasts.show("Moved to Work")
        XCTAssertEqual(toasts.current?.surface, .hub)
    }

    func testToastUndoRunsOnceAndClears() {
        let toasts = ToastCenter(announcer: AnnouncementSink())
        var undone = 0
        toasts.show("Removed Safari from the Dock", on: .dock,
                    action: Toast.Action(title: "Undo") { undone += 1 })
        let id = try! XCTUnwrap(toasts.current?.id)
        toasts.performAction(of: id)
        toasts.performAction(of: id)
        XCTAssertEqual(undone, 1)
        XCTAssertNil(toasts.current)
    }
}

/// Opt-in renders of the feedback pieces, for looking at them:
/// `BARSHELF_SHOT_DIR=… swift test --filter FeedbackRenderTests`.
@MainActor
final class FeedbackRenderTests: XCTestCase {
    func testRenderFeedbackWhenRequested() throws {
        guard let folder = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("Set BARSHELF_SHOT_DIR to inspect toasts and error views")
        }
        _ = NSApplication.shared
        defer { NSApp.appearance = nil }
        let toasts: [(String, Toast)] = [
            ("toast-copied", Toast(message: "Copied", surface: .dock)),
            ("toast-undo", Toast(message: "Removed Safari from the Dock", surface: .dock,
                                 action: Toast.Action(title: "Undo") {})),
            ("toast-failure", Toast(message: WidgetRuntime.actionFailureTitle("Restart"),
                                    detail: { let e = ErrorExplainer.explain("exited with code 3", context: .action); return "\(e.cause) \(e.fix)" }(),
                                    tone: .failure, surface: .popup)),
            ("toast-refresh-refused", Toast(message: RefreshRejection.waitingForPermission.message(widgetName: "Weather"),
                                            detail: RefreshRejection.waitingForPermission.detail, tone: .failure, surface: .hub)),
        ]
        for dark in [false, true] {
            let suffix = dark ? "-dark" : "-light"
            for (name, toast) in toasts {
                try render(ToastCapsule(toast: toast) {}.padding(Spacing.m), size: NSSize(width: 420, height: 110),
                           name: name + suffix, dark: dark, to: folder)
            }
            try render(CrashDisabledView(reason: "crashed 3 times within 5 minutes", onRestart: {}, onOpenLogs: {})
                .padding(Spacing.s), size: NSSize(width: 340, height: 150), name: "crash-card" + suffix, dark: dark, to: folder)
            try render(ExplainedErrorView(error: "HTTP 404 from https://api.example.com/v1/items", context: .test)
                .padding(Spacing.s), size: NSSize(width: 420, height: 90), name: "builder-test-error" + suffix, dark: dark, to: folder)
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool, to folder: String) throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = window.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
}

private final class AnnouncementSink: AccessibilityAnnouncing {
    func announce(_ message: String) {}
}
