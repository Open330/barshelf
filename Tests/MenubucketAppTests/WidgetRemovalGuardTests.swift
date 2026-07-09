import XCTest
@testable import MenubucketApp

/// The path-traversal guard behind `WidgetRuntime.removeWidget`: only proper
/// subdirectories of the user widgets root may ever be deleted.
final class WidgetRemovalGuardTests: XCTestCase {
    private var root: URL { WidgetRuntime.userWidgetsRoot }

    func testAcceptsWidgetInsideUserRoot() {
        let dir = root.appendingPathComponent("my-widget", isDirectory: true)
        XCTAssertTrue(WidgetRuntime.isRemovableWidgetDirectory(dir))
    }

    func testRefusesRootItself() {
        XCTAssertFalse(WidgetRuntime.isRemovableWidgetDirectory(root))
    }

    func testRefusesPathTraversalEscape() {
        let escape = root.appendingPathComponent("../../../etc", isDirectory: true)
        XCTAssertFalse(WidgetRuntime.isRemovableWidgetDirectory(escape))
    }

    func testRefusesUnrelatedDirectory() {
        let outside = URL(fileURLWithPath: "/tmp/widgets/foo", isDirectory: true)
        XCTAssertFalse(WidgetRuntime.isRemovableWidgetDirectory(outside))
    }

    func testRefusesDevCheckoutWidget() {
        // ./widgets/<name> relative to cwd is a dev-mode widget, never removable.
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("widgets/sample", isDirectory: true)
        XCTAssertFalse(WidgetRuntime.isRemovableWidgetDirectory(dev))
    }
}
