import AppKit
import MenubucketCore
import SwiftUI
import XCTest
@testable import MenubucketApp

/// A dock with more tiles than its display is long scrolls instead of being
/// cut off. Offscreen only: no Dock mode, preferences, or launches.
@MainActor
final class DockOverflowTests: XCTestCase {
    private let laptop = NSRect(x: 0, y: 0, width: 1280, height: 800)
    /// A portrait display short enough that a side dock overflows.
    private let portrait = NSRect(x: 1280, y: 0, width: 600, height: 560)

    // MARK: Panel geometry

    func testPanelStaysOnItsDisplayWhateverTheBarLength() {
        let visible = laptop.insetBy(dx: 0, dy: 20)
        for edge in [DockConfiguration.Edge.bottom, .left, .right] {
            for length in [300.0, 1264.0, 3302.0] {
                let bar = edge.isVertical ? CGSize(width: 150, height: length) : CGSize(width: length, height: 150)
                let frame = DockPanelController.panelFrame(
                    edge: edge, barSize: bar, headroom: (along: 320, across: 120),
                    visible: visible, full: laptop, revealed: true
                )
                XCTAssertTrue(visible.contains(frame), "\(edge) \(length): \(frame)")
            }
        }
        let hidden = DockPanelController.panelFrame(
            edge: .bottom, barSize: CGSize(width: 3302, height: 150), headroom: (along: 320, across: 120),
            visible: visible, full: laptop, revealed: false
        )
        XCTAssertLessThanOrEqual(hidden.maxY, laptop.minY)
    }

    func testMaxBarLengthFollowsTheEdgeOfThatDisplay() {
        XCTAssertEqual(DockPanelController.maxBarLength(edge: .bottom, visible: laptop), 1264)
        XCTAssertEqual(DockPanelController.maxBarLength(edge: .left, visible: portrait), 544)
        XCTAssertEqual(DockPanelController.maxBarLength(edge: .right, visible: portrait), 544)
    }

    // MARK: Scroll routing

    func testScrollsKeepProfileSwitchingAndReachEveryTile() {
        typealias Host = DockHostingView<EmptyView>
        func route(command: Bool = false, momentum: Bool = false, precise: Bool,
                   dx: CGFloat, dy: CGFloat, axis: Axis?) -> Host.ScrollRoute {
            Host.route(command: command, momentum: momentum, precise: precise,
                       deltaX: dx, deltaY: dy, scrollingAxis: axis)
        }
        // Not overflowing: a sideways trackpad swipe switches profiles; every
        // other scroll goes to what is under the pointer (a widget's list).
        XCTAssertEqual(route(precise: true, dx: -30, dy: 2, axis: nil), .host)
        XCTAssertEqual(route(precise: false, dx: 0, dy: 3, axis: nil), .dispatch)
        XCTAssertEqual(route(precise: true, dx: 0, dy: -20, axis: nil), .dispatch)
        XCTAssertEqual(route(precise: false, dx: -3, dy: 0, axis: nil), .dispatch)
        XCTAssertEqual(route(momentum: true, precise: true, dx: -8, dy: 0, axis: nil), .dispatch)
        // ⌘-scroll switches profiles even over a scrolling dock.
        XCTAssertEqual(route(command: true, precise: true, dx: -30, dy: 0, axis: .horizontal), .host)
        XCTAssertEqual(route(command: true, precise: false, dx: 0, dy: 3, axis: .vertical), .host)
        // A bottom dock that overflows: swipes and wheels scroll its tiles.
        XCTAssertEqual(route(precise: true, dx: -30, dy: 2, axis: .horizontal), .dispatch)
        XCTAssertEqual(route(precise: false, dx: 0, dy: -3, axis: .horizontal), .tilesSideways)
        XCTAssertEqual(route(momentum: true, precise: true, dx: -8, dy: 0, axis: .horizontal), .dispatch)
        // A side dock that overflows: vertical scrolls it, a sideways swipe
        // still switches profiles.
        XCTAssertEqual(route(precise: true, dx: 0, dy: -20, axis: .vertical), .dispatch)
        XCTAssertEqual(route(precise: false, dx: 0, dy: -3, axis: .vertical), .dispatch)
        XCTAssertEqual(route(precise: true, dx: -30, dy: 2, axis: .vertical), .host)
    }

    func testAWheelOverAWidgetThatScrollsKeepsScrollingTheWidget() {
        typealias Host = DockHostingView<EmptyView>
        XCTAssertEqual(Host.route(command: false, momentum: false, precise: false, deltaX: 0, deltaY: -3,
                                  scrollingAxis: .horizontal, overVerticalScroller: true), .dispatch)
        // Shift-wheel arrives sideways and scrolls the dock, widget or not.
        XCTAssertEqual(Host.route(command: false, momentum: false, precise: false, deltaX: -3, deltaY: 0,
                                  scrollingAxis: .horizontal, overVerticalScroller: true), .dispatch)
        XCTAssertEqual(Host.route(command: false, momentum: false, precise: false, deltaX: 0, deltaY: -3,
                                  scrollingAxis: .horizontal, overVerticalScroller: false), .tilesSideways)
    }

    func testOnlyAScrollViewThatCanScrollVerticallyCounts() {
        func scrollView(document: CGSize) -> NSScrollView {
            let view = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            view.documentView = NSView(frame: NSRect(origin: .zero, size: document))
            return view
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 200))
        let dock = scrollView(document: CGSize(width: 3000, height: 100)) // sideways only
        root.addSubview(dock)
        let list = scrollView(document: CGSize(width: 300, height: 400)) // a widget's list
        dock.documentView?.addSubview(list)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        list.documentView?.addSubview(row)
        let icon = NSView(frame: NSRect(x: 400, y: 0, width: 64, height: 64))
        dock.documentView?.addSubview(icon)

        XCTAssertTrue(DockHostingView<EmptyView>.scrollsVertically(from: row, within: root))
        XCTAssertFalse(DockHostingView<EmptyView>.scrollsVertically(from: icon, within: root))
        XCTAssertFalse(DockHostingView<EmptyView>.scrollsVertically(from: root, within: root))
    }

    func testWheelNotchesMoveToTheHorizontalAxis() throws {
        let source = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: source))
        let sideways = try XCTUnwrap(DockHostingView<EmptyView>.sideways(event))
        XCTAssertEqual(sideways.scrollingDeltaY, 0)
        XCTAssertEqual(sideways.scrollingDeltaX, event.scrollingDeltaY)
        XCTAssertNotEqual(sideways.scrollingDeltaX, 0)
    }

    // MARK: Routing wrapper

    private func wheel(dy: Int32, command: Bool = false) throws -> NSEvent {
        let source = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0
        ))
        // A nil CGEvent source inherits live modifier state. Tests must not
        // turn a user's held Command key into an unintended profile switch.
        source.flags = command ? .maskCommand : []
        return try XCTUnwrap(NSEvent(cgEvent: source))
    }

    func testRouterDeliversOrdinaryScrollsAndConsumesProfileSwitches() throws {
        _ = NSApplication.shared
        var swipes: [Int] = []
        let host = DockHostingView(rootView: EmptyView())
        host.onSwipe = { swipes.append($0) }
        let router = DockPanelController.scrollRouter(for: host)

        // Not overflowing: a wheel goes on to whatever is under the pointer.
        let plain = try wheel(dy: -3)
        XCTAssertTrue(router(plain) === plain)
        XCTAssertEqual(swipes, [])

        // ⌘-scroll switches once and is not delivered a second time.
        XCTAssertNil(router(try wheel(dy: -3, command: true)))
        XCTAssertEqual(swipes.count, 1)

        // Overflowing sideways: the wheel is turned, not swallowed.
        host.scrollingAxis = .horizontal
        let turned = try XCTUnwrap(router(try wheel(dy: -3)))
        XCTAssertEqual(turned.scrollingDeltaY, 0)
        XCTAssertNotEqual(turned.scrollingDeltaX, 0)
        XCTAssertEqual(swipes.count, 1)
    }

    func testRouterOutlivingItsHostingViewDeliversEverything() throws {
        var router: ((NSEvent) -> NSEvent?)?
        autoreleasepool {
            let host = DockHostingView(rootView: EmptyView())
            router = DockPanelController.scrollRouter(for: host)
        }
        let command = try wheel(dy: -3, command: true)
        XCTAssertTrue(try XCTUnwrap(router)(command) === command)
    }

    func testAWidgetListInTheDockIsFoundUnderThePointer() throws {
        _ = NSApplication.shared
        let content = AnyView(
            HStack(spacing: 0) {
                ScrollView(.vertical) { Color.red.frame(width: 100, height: 400) }
                    .frame(width: 100, height: 100)
                Color.blue.frame(width: 100, height: 100)
            }
            .frame(width: 200, height: 100)
        )
        let host = DockHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { window.close() }
        try spin(until: { Self.findScrollView(in: host) != nil })
        XCTAssertTrue(host.isOverVerticalScroller(atWindowPoint: NSPoint(x: 50, y: 50)))
        XCTAssertFalse(host.isOverVerticalScroller(atWindowPoint: NSPoint(x: 150, y: 50)))
    }

    // MARK: Keyboard

    func testTabSkipsDividersAndSpacesAndWraps() {
        let tiles: [DockTile] = [
            .item(DockItem(id: "a", kind: .app(path: "/Applications/A.app"))),
            .item(DockItem(id: "gap", kind: .spacer)),
            .item(DockItem(id: "w", kind: .widget(id: "dev.test.widget"))),
            .divider("trash"),
            .trash,
        ]
        let order = DockView.focusOrder(tiles)
        XCTAssertEqual(order, ["a", "w", "trash"])
        XCTAssertEqual(DockView.nextFocus(after: nil, in: order, backward: false), "a")
        XCTAssertEqual(DockView.nextFocus(after: nil, in: order, backward: true), "trash")
        XCTAssertEqual(DockView.nextFocus(after: "a", in: order, backward: false), "w")
        XCTAssertEqual(DockView.nextFocus(after: "trash", in: order, backward: false), "a")
        XCTAssertEqual(DockView.nextFocus(after: "a", in: order, backward: true), "trash")
        XCTAssertEqual(DockView.nextFocus(after: "gone", in: order, backward: false), "a")
        XCTAssertNil(DockView.nextFocus(after: nil, in: [], backward: false))
        XCTAssertEqual(DockView.focusOrder([.divider("x"), .item(DockItem(id: "s", kind: .separator))]), [])
    }

    // MARK: Rendered layout

    func testTwentyFourIconsAt128ScrollAlongA1280PointDisplay() throws {
        let maxLength = DockPanelController.maxBarLength(edge: .bottom, visible: laptop)
        let probe = try render(axis: .horizontal, count: 24, tile: CGSize(width: 128, height: 128), maxLength: maxLength)
        XCTAssertEqual(probe.scrolling, true)
        XCTAssertEqual(probe.size.width, maxLength, accuracy: 1)
        XCTAssertEqual(probe.size.height, 128, accuracy: 1, "the user's tile size is kept")
        let scrollView = try XCTUnwrap(probe.scrollView)
        let natural = 24 * 128 + 23 * 10.0
        XCTAssertEqual(try XCTUnwrap(scrollView.documentView).frame.width, natural, accuracy: 1,
                       "every tile, the Trash at the end included, is in the scrolled content")

        // Keyboard focus on the last tile scrolls it into view: no keystrokes.
        probe.focus("23")
        try spin(until: { scrollView.contentView.bounds.maxX >= natural - 1 })
        XCTAssertEqual(scrollView.contentView.bounds.maxX, natural, accuracy: 1)
    }

    func testWideWidgetsOverflowLikeIcons() throws {
        let maxLength = DockPanelController.maxBarLength(edge: .bottom, visible: laptop)
        let probe = try render(axis: .horizontal, count: 6, tile: CGSize(width: 384, height: 128), maxLength: maxLength)
        XCTAssertEqual(probe.scrolling, true)
        XCTAssertEqual(probe.size.width, maxLength, accuracy: 1)
    }

    func testSideDockOnAShortPortraitDisplayScrollsVertically() throws {
        let maxLength = DockPanelController.maxBarLength(edge: .left, visible: portrait)
        let probe = try render(axis: .vertical, count: 20, tile: CGSize(width: 64, height: 64), maxLength: maxLength)
        XCTAssertEqual(probe.scrolling, true)
        XCTAssertEqual(probe.size.height, maxLength, accuracy: 1)
        XCTAssertEqual(probe.size.width, 64, accuracy: 1)
        let scrollView = try XCTUnwrap(probe.scrollView)
        XCTAssertEqual(try XCTUnwrap(scrollView.documentView).frame.height, 20 * 64 + 19 * 10.0, accuracy: 1)
    }

    func testADockThatFitsKeepsItsNaturalLengthAndDoesNotScroll() throws {
        let probe = try render(axis: .horizontal, count: 6, tile: CGSize(width: 128, height: 128), maxLength: 1264)
        XCTAssertEqual(probe.scrolling, false)
        XCTAssertEqual(probe.size.width, 6 * 128 + 5 * 10, accuracy: 1)
        XCTAssertNil(probe.scrollView)
    }

    // MARK: Helpers

    private final class Probe {
        var scrolling: Bool?
        var size: CGSize = .zero
        var scrollView: NSScrollView?
        var focus: (String) -> Void = { _ in }
    }

    private struct Harness: View {
        let axis: Axis
        let count: Int
        let tile: CGSize
        let maxLength: CGFloat
        let focusedID: String?
        let onScrollingChange: (Bool) -> Void

        var body: some View {
            DockOverflowStack(
                layout: axis == .horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10)),
                axis: axis, maxLength: maxLength, isResting: true, focusedID: focusedID,
                onScrollingChange: onScrollingChange
            ) {
                ForEach(0..<count, id: \.self) { index in
                    Color.blue.frame(width: tile.width, height: tile.height).id(String(index))
                }
            }
            .fixedSize()
        }
    }

    private func render(axis: Axis, count: Int, tile: CGSize, maxLength: CGFloat) throws -> Probe {
        let probe = Probe()
        func harness(focus: String?) -> Harness {
            Harness(axis: axis, count: count, tile: tile, maxLength: maxLength, focusedID: focus,
                    onScrollingChange: { probe.scrolling = $0 })
        }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: harness(focus: nil))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 4000, height: 4000),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { window.close() }
        try spin(until: { probe.scrolling != nil && host.intrinsicContentSize.width > 0 })
        // One more pass: switching to scrolling replaces the stack.
        try spin(until: { false }, timeout: 0.3)
        probe.size = host.intrinsicContentSize
        probe.scrollView = Self.findScrollView(in: host)
        probe.focus = { host.rootView = harness(focus: $0) }
        return probe
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }
}
