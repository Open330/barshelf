import XCTest
@testable import MenubucketApp
import MenubucketCore

/// How a permission request words a widget's commands: what they do, each
/// phrase once, never a command line cut mid-word.
final class PermissionDescriptionTests: XCTestCase {
    private func manifest(_ exec: [Manifest.ExecPermission], localizations: String = "") throws -> Manifest {
        var manifest = Manifest(
            schemaVersion: 1, id: "dev.test.describe", name: "Describe",
            entry: .init(kind: "workflow"), permissions: .init(exec: exec)
        )
        if !localizations.isEmpty {
            manifest.localizations = try JSONDecoder().decode(WidgetLocalizations.self, from: Data(localizations.utf8))
        }
        return manifest
    }

    func testPurposeReplacesTheCommandLineAndIsTranslated() throws {
        let exec = Manifest.ExecPermission(command: "/usr/bin/pmset", allowedArgs: [["-g", "batt"]], purpose: "Read the battery level")
        let m = try manifest([exec], localizations: #"{"ko":{"Read the battery level":"배터리 잔량 읽기"}}"#)
        let english = try XCTUnwrap(ExecPermissionText.summary(for: m, localization: nil))
        XCTAssertEqual(english.phrases, ["Read the battery level"])
        XCTAssertEqual(english.commandLines, ["/usr/bin/pmset -g batt"])
        let korean = try XCTUnwrap(ExecPermissionText.summary(for: m, localization: m.localization(for: "ko")))
        XCTAssertEqual(korean.phrases, ["배터리 잔량 읽기"])
    }

    func testWithoutAPurposeOnlyTheToolIsNamed() throws {
        let m = try manifest([.init(command: "kubectl", allowedArgs: [
            ["get", "pods", "-n", "*", "-o", "go-template=[{{range $i, $p := .items}}"],
            ["config", "view"],
        ])])
        let summary = try XCTUnwrap(ExecPermissionText.summary(for: m, localization: nil))
        XCTAssertEqual(summary.phrases, ["Run kubectl"])
        XCTAssertFalse(summary.phrases.joined().contains("go-template"))
        // The exact lines stay available, quoted as a shell would need them.
        XCTAssertEqual(summary.commandLines.count, 2)
        XCTAssertTrue(summary.commandLines[0].contains("'go-template=[{{range $i, $p := .items}}'"))
    }

    func testRepeatedPhrasesBecomeOneRow() throws {
        let purpose = "Read the time in the cities you choose"
        let m = try manifest([
            .init(command: "/bin/date", allowedArgs: [["+%H:%M"]], purpose: purpose),
            .init(command: "/bin/sh", allowedArgs: [["-c", "TZ=\"$1\"; export TZ; exec /bin/date '+%H'", "x", "*"]], purpose: purpose),
        ])
        let requests = WidgetRuntime.permissionRequests(for: m, localization: .some(nil))
        let exec = requests.filter { $0.symbol == "terminal" }
        XCTAssertEqual(exec.count, 1)
        XCTAssertEqual(exec[0].description, purpose)
        XCTAssertEqual(exec[0].details.count, 2)
    }

    func testCommandsWithoutPurposesShareOneRowWithoutRepeats() throws {
        let m = try manifest([
            .init(command: "/bin/date", allowedArgs: [["+%H"], ["+%A"]]),
            .init(command: "/bin/sh", allowedArgs: [["-c", "/sbin/ping -c 1 1.1.1.1 | /usr/bin/sed -n p"]]),
        ])
        let requests = WidgetRuntime.permissionRequests(for: m, localization: .some(nil))
        XCTAssertEqual(requests.map(\.symbol), ["terminal"])
        XCTAssertEqual(requests[0].description.split(separator: "\n"), [
            "Read the current date and time",
            "Run a shell script that uses ping and sed",
        ])
    }

    func testAnyArgumentsIsStillSaid() throws {
        let m = try manifest([.init(command: "/usr/bin/open")])
        XCTAssertEqual(ExecPermissionText.summary(for: m, localization: nil)?.phrases, ["Run open with any arguments"])
    }

    // MARK: Shell scripts

    func testBareAndLookedUpCommandsAreListed() {
        let docker = #"""
        d=$(command -v docker 2>/dev/null); if [ -z "$d" ]; then for c in "$HOME/.orbstack/bin/docker" /Applications/Docker.app/Contents/Resources/bin/docker; do if [ -x "$c" ]; then d=$c; break; fi; done; fi; out=$("$d" ps $a --format '{{json .}}' 2>/dev/null) || { printf '{}'; exit 0; }; printf '%s' "$(printf '%s\n' "$out" | /usr/bin/paste -sd, -)"
        """#
        let found = ShellScriptCommands.analyze(docker)
        XCTAssertEqual(found.commands, ["docker", "paste"])
        // "$d" ps runs whatever was found: the list may not be all of it.
        XCTAssertFalse(found.isComplete)
        XCTAssertEqual(
            ExecPermissionText.describe(command: "/bin/sh", args: ["-c", docker]),
            "Run a shell script that uses docker, paste and others"
        )
    }

    func testQuotedTextAndAssignmentsAreNotCommands() {
        let script = #"""
        t=$(/usr/bin/osascript -e 'tell application "Music" to get name' | tr -d '"'); [ -z "$t" ] && t="Nothing playing"; echo '{"track":"'"$t"'"}'; awk '{print $1}' file
        """#
        let found = ShellScriptCommands.analyze(script)
        XCTAssertEqual(found.commands, ["osascript", "tr", "awk"])
        XCTAssertTrue(found.isComplete)
    }

    func testExecAndEnvironmentPrefixesAreSkipped() {
        let found = ShellScriptCommands.analyze(#"TZ="$1"; export TZ; exec /bin/date '+%H'; HOMEBREW_NO_ENV_HINTS=1 brew outdated"#)
        XCTAssertEqual(found.commands, ["date", "brew"])
        XCTAssertTrue(found.isComplete)
    }

    func testCaseAndForListsAreNotCommands() {
        let found = ShellScriptCommands.analyze(#"for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && "$b" outdated; done; case "$out" in "{"*) ;; *) printf x;; esac"#)
        XCTAssertEqual(found.commands, ["brew"])
        XCTAssertFalse(found.isComplete)
    }

    // MARK: The rest of the request

    func testVaultIsTwoShortRows() throws {
        var m = try manifest([])
        m.permissions = .init(vault: .init(provider: "bitwarden", idleLockMinutes: 5))
        let rows = WidgetRuntime.permissionRequests(for: m, localization: .some(nil))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].description.contains("5 minutes"))
        XCTAssertTrue(rows.allSatisfy { $0.description.count < 80 })
    }

    /// Writing or rewording a purpose must never ask the user again.
    func testPurposeIsNotPartOfThePermissionHash() throws {
        let plain = try manifest([.init(command: "/bin/ps", allowedArgs: [["-ax"]])])
        let described = try manifest([.init(command: "/bin/ps", allowedArgs: [["-ax"]], purpose: "List processes")])
        XCTAssertEqual(PermissionStore.permissionsHash(of: plain), PermissionStore.permissionsHash(of: described))
    }

    func testEveryBundledCommandHasAPurposeInEnglishAndKorean() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets")
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(name).appendingPathComponent("widget.json")
            guard let data = try? Data(contentsOf: url) else { continue }
            let m = try Manifest.decode(from: data)
            for exec in m.permissions?.exec ?? [] {
                let purpose = try XCTUnwrap(exec.purpose, "\(name): \(exec.command) has no purpose")
                XCTAssertNotEqual(m.localization(for: "ko")?.text(purpose), purpose, "\(name): no Korean for \(purpose)")
            }
        }
    }

    func testWaitingWidgetsGroupByRisk() throws {
        func risk(_ permissions: Manifest.Permissions) -> PermissionInventory.Risk {
            PermissionInventory.Risk.of(Manifest(schemaVersion: 1, id: "dev.test.r", name: "R", entry: .init(kind: "workflow"), permissions: permissions))
        }
        XCTAssertEqual(risk(.init(keychain: true)), .secrets)
        XCTAssertEqual(risk(.init(exec: [.init(command: "/usr/bin/osascript", allowedArgs: [["x.js"]])])), .controlsApps)
        XCTAssertEqual(risk(.init(network: ["api.example.com"])), .internet)
        XCTAssertEqual(risk(.init(exec: [.init(command: "/bin/sh", allowedArgs: [["-c", "/usr/bin/curl -s x"]])])), .internet)
        XCTAssertEqual(risk(.init(exec: [.init(command: "/usr/bin/pmset", allowedArgs: [["-g", "batt"]])])), .readsMac)
        XCTAssertEqual(risk(.init(notifications: true)), .notificationsAndStorage)
    }

    func testWaitingBannerShowsForSeveralOrOneOutOfSight() {
        XCTAssertFalse(ShelfAttention.showsWaitingBanner(waitingIDs: [], currentPageIDs: []))
        XCTAssertFalse(ShelfAttention.showsWaitingBanner(waitingIDs: ["a"], currentPageIDs: ["a"]))
        XCTAssertTrue(ShelfAttention.showsWaitingBanner(waitingIDs: ["a"], currentPageIDs: ["b"]))
        XCTAssertTrue(ShelfAttention.showsWaitingBanner(waitingIDs: ["a", "b"], currentPageIDs: ["a", "b"]))
    }
}
