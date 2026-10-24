import XCTest
import MenubucketCore
@testable import MenubucketApp

final class NotificationServiceTests: XCTestCase {
    private actor Gate {
        var entered = false
        private var continuation: CheckedContinuation<Bool, Never>?
        func authorize() async -> Bool {
            entered = true
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(returning: true); continuation = nil }
    }

    func testRevokingWhileMacOSAuthorizationIsPendingPreventsSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PermissionStore(fileURL: directory.appendingPathComponent("permissions.json"))
        let manifest = Manifest(schemaVersion: 1, id: "dev.test.notification", name: "Test",
                                entry: .init(kind: "script"), permissions: .init(notifications: true))
        store.approve(manifest)
        let witness = directory.appendingPathComponent("must-not-submit")
        let gate = Gate()
        let service = NotificationService(authorize: { await gate.authorize() }, submit: { _, _ in
            try Data().write(to: witness)
        })
        let permit = ScriptRequestAuthorization(isApproved: { store.status(for: manifest) == .approved })
        let task = Task { try await service.show(title: "Test", body: nil, authorization: permit) }
        let deadline = Date().addingTimeInterval(5)
        while !(await gate.entered), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        store.reset(widgetId: manifest.id)
        await gate.release()
        do { try await task.value; XCTFail("revoked notification must not be submitted") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: witness.path))
    }
}
