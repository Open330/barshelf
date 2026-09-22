import AppKit
import Foundation
import MenubucketCore
import XCTest

@testable import MenubucketApp

/// Measurement harness: what one menu bar item costs to redraw. Three items
/// refreshing every two or three seconds redraw this often, whether or not
/// the reading changed.
@MainActor
final class MenuBarRenderCostTests: XCTestCase {
    private func entry(_ label: String, _ value: String) -> MenuBarEntry {
        MenuBarEntry(
            widgetID: "dev.barshelf.system",
            name: label,
            symbol: "cpu.fill",
            prefix: label,
            style: .stacked,
            label: value
        )
    }

    func testReportRenderCost() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BARSHELF_BENCH"] == "1",
            "measurement harness; set BARSHELF_BENCH=1"
        )

        func time(_ label: String, runs: Int = 300, _ body: () -> Void) {
            body()
            var total: Double = 0
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            print(String(format: "MENUBAR %@: %.3f ms", label, total / Double(runs)))
        }

        let sample = entry("CPU", "23")
        time("symbolImage (untinted)") {
            _ = MenuBarController.symbolImage(
                named: "cpu.fill", describedAs: "CPU", tint: nil
            )
        }
        time("symbolImage (tinted)") {
            _ = MenuBarController.symbolImage(
                named: "cpu.fill", describedAs: "CPU", tint: .systemOrange
            )
        }
        let symbol = MenuBarController.symbolImage(
            named: "cpu.fill", describedAs: "CPU", tint: nil
        )
        time("stackedImage") {
            _ = MenuBarController.stackedImage(sample, symbol: symbol, glyph: nil)
        }
        time("full item redraw") {
            let image = MenuBarController.symbolImage(
                named: "cpu.fill", describedAs: "CPU", tint: nil
            )
            _ = MenuBarController.stackedImage(sample, symbol: image, glyph: nil)
        }
    }
}
