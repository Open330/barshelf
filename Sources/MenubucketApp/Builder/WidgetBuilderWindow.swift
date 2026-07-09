import AppKit
import MenubucketCore
import SwiftUI

// MARK: - Window shim (the builder now lives in the hub's Create section)

/// Back-compat shim: the widget builder is embedded in the hub's Create
/// section (`HubCreateView`), so opening it routes there. Keeps the historical
/// `show(runtime:)` signature so RootView and the status item menu need no
/// edits.
@MainActor
final class WidgetBuilderController {
    static let shared = WidgetBuilderController()

    func show(runtime: WidgetRuntime) {
        HubWindowController.shared.show(runtime: runtime, tab: .create)
    }
}
