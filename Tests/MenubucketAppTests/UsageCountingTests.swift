import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class UsageCountingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRuntime() -> (WidgetRuntime, UsageStore) {
        let store = UsageStore(fileURL: root.appendingPathComponent("usage.json"), writeDelay: 3600)
        let runtime = WidgetRuntime(
            appPrefs: AppPrefs(fileURL: root.appendingPathComponent("app-prefs.json")),
            usageStore: store
        )
        return (runtime, store)
    }

    func testCountsOpensAndWidgetEvents() {
        let (runtime, store) = makeRuntime()
        runtime.popupOpened()
        runtime.popupClosed()
        runtime.popupOpened()
        runtime.countUsage(.action, widgetID: "dev.a")
        runtime.countUsage(.menuBarCardOpen, widgetID: "dev.a")
        let day = store.snapshot().days[store.today]
        XCTAssertEqual(day?.popupOpens, 2)
        XCTAssertEqual(day?.widgets["dev.a"], WidgetUsage(actions: 1, menuBarCardOpens: 1))
    }

    func testTurningCountingOffStopsIt() {
        let (runtime, store) = makeRuntime()
        runtime.appPrefs.update { $0.usageCountsEnabled = false }
        runtime.popupOpened()
        runtime.countUsage(.action, widgetID: "dev.a")
        XCTAssertEqual(store.snapshot(), UsageLog())
    }

    func testActionRouterCountsTheAction() async {
        let (runtime, store) = makeRuntime()
        ActionRouter.perform(NodeAction(type: "nothing-known"), widgetID: "dev.b", runtime: runtime)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(store.snapshot().days[store.today]?.widgets["dev.b"]?.actions, 1)
    }
}
