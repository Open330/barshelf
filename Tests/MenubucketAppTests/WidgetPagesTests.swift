import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Exercises the pure page layout used by `WidgetRuntime.pages`: bucket
/// overrides win over the manifest, disabled widgets vanish, empty groups
/// disappear, and both members and pages keep a stable order.
final class WidgetPagesTests: XCTestCase {
    private func widget(_ id: String, group: String?, order: Int?) -> LoadedWidget {
        LoadedWidget(
            manifest: Manifest(
                schemaVersion: 1,
                id: id,
                name: id,
                bucket: Manifest.Bucket(group: group, order: order),
                entry: Manifest.Entry(kind: "exec")
            ),
            directory: URL(fileURLWithPath: "/tmp/\(id)")
        )
    }

    func testOverridesRegroupAndReorder() {
        let widgets = [
            widget("a", group: "General", order: 0),
            widget("b", group: "General", order: 1),
            widget("c", group: "Ops", order: 0),
        ]
        // Move "a" into Ops and push it after "c" via an order override.
        let overrideGroup = ["a": "Ops"]
        let overrideOrder: [String: Double] = ["a": 5]

        let pages = WidgetRuntime.computePages(
            widgets,
            group: { overrideGroup[$0.id] ?? $0.group },
            order: { overrideOrder[$0.id] ?? Double($0.order) },
            isDisabled: { _ in false }
        )

        // Ops sorts first: its first member ("c", order 0) precedes General's
        // first member ("b", order 1). "a" lands after "c" via its order override.
        XCTAssertEqual(pages.map(\.group), ["Ops", "General"])
        XCTAssertEqual(pages[0].widgets.map(\.id), ["c", "a"])
        XCTAssertEqual(pages[1].widgets.map(\.id), ["b"])
    }

    func testDisabledWidgetLeavesEmptyGroupOut() {
        let widgets = [
            widget("a", group: "General", order: 0),
            widget("solo", group: "Solo", order: 0),
        ]

        let pages = WidgetRuntime.computePages(
            widgets,
            group: { $0.group },
            order: { Double($0.order) },
            isDisabled: { $0.id == "solo" }
        )

        XCTAssertEqual(pages.map(\.group), ["General"])
    }

    func testVisibleWidgetIDsContainOnlySelectedPageAndPinnedWidgets() {
        let pages = [
            WidgetPage(group: "First", widgets: [widget("a", group: "First", order: 0)]),
            WidgetPage(group: "Third", widgets: [widget("reminders", group: "Third", order: 0)]),
        ]

        XCTAssertEqual(
            RootView.visibleWidgetIDs(pages: pages, index: 0, pinned: ["pinned"]),
            ["a", "pinned"]
        )
        XCTAssertEqual(
            RootView.visibleWidgetIDs(pages: pages, index: 1, pinned: ["pinned"]),
            ["reminders", "pinned"]
        )
    }
}
