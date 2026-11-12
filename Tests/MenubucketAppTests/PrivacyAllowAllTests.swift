import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Settings ▸ Privacy's Allow All: one confirmation, which still names what
/// is being allowed, and one approval per widget (copies share it).
final class PrivacyAllowAllTests: XCTestCase {
    private func widget(_ id: String, _ name: String, instance: String? = nil, vault: Bool = false) -> LoadedWidget {
        let manifest = Manifest(
            schemaVersion: 1, id: id, name: name, entry: .init(kind: "workflow"),
            permissions: .init(network: ["api.example.com"],
                               vault: vault ? .init(provider: "bitwarden", idleLockMinutes: 10, maxSessionMinutes: 60) : nil)
        )
        return LoadedWidget(manifest: manifest, directory: FileManager.default.temporaryDirectory, instanceID: instance)
    }

    func testCopiesAreAllowedOnceAndSensitiveAccessIsNamed() {
        let waiting = [
            widget("dev.test.weather", "Weather"),
            widget("dev.test.weather", "Weather", instance: "dev.test.weather#2"),
            widget("dev.test.vault", "Vault", vault: true),
        ]
        XCTAssertEqual(PrivacySettingsPage.distinctManifests(waiting).map(\.id), ["dev.test.weather", "dev.test.vault"])
        XCTAssertEqual(PrivacySettingsPage.allowAllTitle(waiting), "Allow 2 widgets?")
        let message = PrivacySettingsPage.allowAllMessage(waiting)
        // Sensitive access is read first, in the note and in the list.
        XCTAssertTrue(message.hasPrefix("Sensitive access: Vault."), message)
        XCTAssertTrue(message.contains("Vault and Weather"), message)
        XCTAssertFalse(PrivacySettingsPage.allowAllMessage(Array(waiting.prefix(1))).contains("Sensitive"))
    }
}
