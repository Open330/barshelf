import XCTest
@testable import MenubucketApp

final class DirectoryWatcherTests: XCTestCase {
    @MainActor
    func testAlreadyQueuedChangeCannotRestartCallbackAfterCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let callback = expectation(description: "cancelled watcher must remain silent")
        callback.isInverted = true
        let watcher = try DirectoryWatcher(paths: [directory.path], debounce: 0) { callback.fulfill() }
        // FSEvents and descriptor notifications dispatch to main before
        // invoking this entry point. Cancel while that delivery is queued.
        DispatchQueue.main.async { watcher.fireDebounced() }
        watcher.cancel()
        await fulfillment(of: [callback], timeout: 0.2)
    }
}
