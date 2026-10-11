import AppKit
import MenubucketCore
import XCTest
@testable import MenubucketApp

final class RefreshOverheadTests: XCTestCase {
    @MainActor
    func testMeasureDockFileServiceCostWhenRequested() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BARSHELF_BENCH"] == "1")
        let path = "/Applications/BarShelf.app"
        func measure(lifetime: TimeInterval) -> Double {
            let cache = DockFilePresentationCache(lifetime: lifetime)
            _ = cache.presentation(at: path)
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<1000 { _ = cache.presentation(at: path) }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        print("DOCK — 1,000 icon/name requests: uncached \(measure(lifetime: 0)) ms; cached \(measure(lifetime: 60)) ms")
    }
    func testLoadingAndCardLayoutDoNotRebuildMenuBarButStatusAndFreshnessDo() {
        let original = WidgetSnapshot(widgetID: "cpu", updatedAt: Date(timeIntervalSince1970: 100), statusLabel: "42%")
        var loading = original
        loading.isLoading = true
        XCTAssertFalse(WidgetRuntime.menuBarStateChanged(from: original, to: loading))
        loading.viewTree = UINode(type: "text", text: "New card layout")
        XCTAssertFalse(WidgetRuntime.menuBarStateChanged(from: original, to: loading))

        let mutations: [(inout WidgetSnapshot) -> Void] = [
            { $0.updatedAt = Date(timeIntervalSince1970: 101) },
            { $0.error = "Unavailable" }, { $0.statusLabel = "43%" },
            { $0.statusMetrics = [StatusMetric(label: "CPU", number: 43)] },
            { $0.statusPrefix = "CPU" }, { $0.statusIcon = "cpu" },
            { $0.statusTint = "red" }, { $0.statusTooltip = "CPU load" },
            { $0.statusPresentation = MenuBarPresentation(chart: .line) }
        ]
        for mutate in mutations {
            var changed = original
            mutate(&changed)
            XCTAssertTrue(WidgetRuntime.menuBarStateChanged(from: original, to: changed))
        }
        XCTAssertTrue(WidgetRuntime.menuBarStateChanged(from: nil, to: original))
    }

    func testRepeatedDockRedrawsReuseFileServicesAndExpiryRefreshesMetadata() {
        var reads = 0
        let cache = DockFilePresentationCache(lifetime: 60) { _ in
            reads += 1
            return .init(name: "version \(reads)", icon: NSImage(size: NSSize(width: 32, height: 32)))
        }
        let now = Date(timeIntervalSince1970: 100)
        let first = cache.presentation(at: "/Applications/Example.app", now: now)
        for _ in 0..<1000 {
            let cached = cache.presentation(at: "/Applications/./Example.app/", now: now.addingTimeInterval(1))
            XCTAssertTrue(cached.icon === first.icon)
            XCTAssertEqual(cached.name, first.name)
        }
        XCTAssertEqual(reads, 1, "1,000 redraws should not make 1,000 icon/metadata reads")
        XCTAssertEqual(cache.presentation(at: "/Applications/Example.app", now: now.addingTimeInterval(60)).name, "version 2")
        XCTAssertEqual(reads, 2)
        _ = cache.presentation(at: "/Applications/Other.app", now: now)
        XCTAssertEqual(reads, 3, "different paths must not share an icon")
    }
}
