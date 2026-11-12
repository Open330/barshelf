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

    /// The usage counts earn a figure at the top of the page only when there
    /// is something to judge by.
    func testUnusedWidgetsGetAStatOnlyWhenCounted() {
        XCTAssertEqual(PrivacySettingsPage.stats(allowed: [], waiting: [], denied: []).map(\.label),
                       ["Allowed", "Waiting for you", "Sensitive access"])
        let whole = UsageSummary(from: "2026-10-14", to: "2026-11-12", days: 30, popupOpens: 9, activeDays: 12, rows: [])
        let counted = PrivacySettingsPage.stats(
            allowed: [], waiting: [], denied: [],
            unused: SettingsStat(value: "4", label: UsageCountsSection.idleStatLabel(whole)))
        XCTAssertEqual(counted.last?.value, "4")
        XCTAssertEqual(counted.last?.label, "Not used in 30 days")
    }

    /// Counts that began this week cannot say "in 30 days".
    func testUsageWordingFollowsHowLongCountingHasRun() {
        let young = UsageSummary(from: "2026-11-10", to: "2026-11-12", days: 30, popupOpens: 1, activeDays: 1, rows: [])
        XCTAssertFalse(young.coversWholeWindow(calendar: .current))
        XCTAssertTrue(UsageCountsSection.idleStatLabel(young).hasPrefix("Not used since "))
        XCTAssertTrue(UsageCountsSection.idleTitle(3, summary: young).hasPrefix("3 widgets not used since "))
        XCTAssertTrue(UsageCountsSection.windowLine(young).hasSuffix("1 day with use"))

        let whole = UsageSummary(from: "2026-10-14", to: "2026-11-12", days: 30, popupOpens: 9, activeDays: 12, rows: [])
        XCTAssertTrue(whole.coversWholeWindow(calendar: .current))
        XCTAssertEqual(UsageCountsSection.idleTitle(1, summary: whole), "1 widget not used in 30 days")
        XCTAssertTrue(UsageCountsSection.windowLine(whole).hasSuffix("12 days with use"))
    }
}
