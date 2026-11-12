import XCTest
@testable import MenubucketCore

/// Bundled developer and file widgets that used to fail the whole card with a
/// CLI's stderr, or show a failure as data (a "down" site while the Mac was
/// offline, "+0 since last check" on every refresh). Each case evaluates the
/// real workflow with fake sources and `errors` (§8E), as the host would
/// after an optional source failed.
final class DeveloperWidgetFailureTests: XCTestCase {
    private struct Widget {
        let definition: WorkflowDefinition
        let defaults: [String: JSONValue]
    }

    private func widget(_ name: String) throws -> Widget {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets/\(name)")
        let manifest = try Manifest.decode(from: Data(contentsOf: root.appendingPathComponent("widget.json")))
        let definition = try WorkflowDefinition.decode(
            from: Data(contentsOf: root.appendingPathComponent("workflow.json"))
        )
        return Widget(definition: definition, defaults: manifest.settingsDefaults().objectValue ?? [:])
    }

    private func evaluate(
        _ name: String,
        sources: [String: JSONValue],
        errors: [String: JSONValue] = [:],
        settings overrides: [String: JSONValue] = [:],
        storage: [String: JSONValue] = [:],
        requested: Bool = false
    ) throws -> WorkflowEngine.Output {
        let widget = try widget(name)
        var settings = widget.defaults
        for (key, value) in overrides { settings[key] = value }
        return try WorkflowEngine.evaluate(
            widget.definition, sources: sources, settings: .object(settings),
            storage: .object(storage),
            widget: .object(["locale": .string("en"), "requested": .bool(requested)]),
            errors: errors
        )
    }

    private func failure(_ kind: String, message: String = "", command: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["kind": .string(kind), "message": .string(message)]
        if let command { object["command"] = .string(command) }
        return .object(object)
    }

    /// Every string the rendered card carries: text, titles, action payloads.
    private func strings(_ node: UINode) throws -> [String] {
        func walk(_ value: Any) -> [String] {
            if let text = value as? String { return [text] }
            if let array = value as? [Any] { return array.flatMap(walk) }
            if let object = value as? [String: Any] {
                if object["hidden"] as? Bool == true { return [] }
                return object.values.flatMap(walk)
            }
            return []
        }
        return walk(try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)))
    }

    private func alert(_ output: WorkflowEngine.Output, _ id: String) -> WorkflowEngine.AlertSample? {
        output.alerts.first { $0.id == id }
    }

    // MARK: Kubernetes

    private let pods: JSONValue = .array([
        .object([
            "name": .string("api-1"), "ns": .string("default"), "phase": .string("Running"),
            "terminating": .bool(false), "ready": .bool(true), "restarts": .number(0),
            "reason": .string(""), "node": .string("n1"), "created": .string("2026-01-01T00:00:00Z"),
        ]),
    ])

    func testKubernetesLapsedCredentialsAskForASignInNotStderr() throws {
        let stderr = "E1112 memcache.go:265] Unhandled Error: getting credentials: exec: executable aws failed with exit code 255"
        let output = try evaluate(
            "kubernetes", sources: ["context": .string("prod"), "pods": .null],
            errors: ["pods": failure("auth", message: stderr)]
        )
        let shown = try strings(output.viewTree)
        XCTAssertTrue(shown.contains("Sign in to the cluster again"), "\(shown)")
        XCTAssertTrue(shown.contains("aws sso login"), "copyText of the sign-in command")
        XCTAssertFalse(shown.contains("Running"), "no zero counts for a failed read")
        XCTAssertEqual(output.statusLabel, "—")
        XCTAssertNil(alert(output, "notReady")?.active, "a failed read is no reading")
    }

    func testKubernetesMissingKubectlLinksToTheInstall() throws {
        let output = try evaluate(
            "kubernetes", sources: ["context": .null, "pods": .null],
            errors: ["context": failure("notFound", command: "kubectl"),
                     "pods": failure("notFound", command: "kubectl")]
        )
        let shown = try strings(output.viewTree)
        XCTAssertTrue(shown.contains("kubectl isn’t installed"))
        XCTAssertTrue(shown.contains { $0.hasPrefix("https://kubernetes.io/") })
    }

    func testKubernetesReadsPodsAndShowsADashWithNone() throws {
        let output = try evaluate("kubernetes", sources: ["context": .string("prod"), "pods": pods])
        XCTAssertEqual(output.statusLabel, "1/1")
        XCTAssertEqual(alert(output, "notReady")?.active, false)

        let empty = try evaluate("kubernetes", sources: ["context": .string("prod"), "pods": .array([])])
        XCTAssertEqual(empty.statusLabel, "—", "0/0 reads as nothing to count")

        let all = try evaluate("kubernetes", sources: ["context": .string("prod"), "pods": pods],
                               settings: ["allNamespaces": .bool(true), "context": .string("staging")])
        let shown = try strings(all.viewTree)
        XCTAssertTrue(shown.contains("All namespaces"))
        XCTAssertTrue(shown.contains("staging"), "a set context is the one shown")
    }

    func testKubernetesCommandAlwaysMatchesItsAllowlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try Manifest.decode(
            from: Data(contentsOf: root.appendingPathComponent("widgets/kubernetes/widget.json"))
        )
        let widget = try widget("kubernetes")
        for settings: [String: JSONValue] in [
            [:], ["allNamespaces": .bool(true)], ["context": .string("prod"), "namespace": .string("kube-system")],
        ] {
            var merged = widget.defaults
            for (key, value) in settings { merged[key] = value }
            let params = try WorkflowEngine.resolvedSourceParams(widget.definition, settings: .object(merged))
            for id in ["context", "pods"] {
                let command = params[id]?.objectValue?["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
                XCTAssertNotNil(ExecAllowlist.match(command: command, permissions: manifest.permissions?.exec),
                                "\(id) \(settings): \(command.prefix(8))")
            }
        }
    }

    // MARK: GitHub Actions

    func testGitHubActionsAsksForARepositoryByDefault() throws {
        let output = try evaluate("github-actions", sources: ["runs": .null, "branch": .null],
                                  errors: ["runs": failure("exit"), "branch": failure("exit")])
        let shown = try strings(output.viewTree)
        XCTAssertTrue(shown.contains("Set a repository in Settings"), "\(shown)")
        XCTAssertFalse(shown.contains { $0.contains("Open330/barshelf") })
        XCTAssertEqual(output.statusLabel, "—")
    }

    func testGitHubActionsNamesSignInAndMissingGh() throws {
        let repo: [String: JSONValue] = ["repo": .string("cli/cli")]
        let auth = try evaluate(
            "github-actions", sources: ["runs": .null, "branch": .null],
            errors: ["runs": failure("auth", message: "To get started with GitHub CLI, please run:  gh auth login")],
            settings: repo
        )
        let authShown = try strings(auth.viewTree)
        XCTAssertTrue(authShown.contains("Sign in to GitHub CLI"))
        XCTAssertTrue(authShown.contains("gh auth login"))
        XCTAssertFalse(authShown.contains { $0.contains("exited with code") })
        XCTAssertNil(alert(auth, "failing")?.active)
        XCTAssertNil(alert(auth, "recovered")?.active)

        let missing = try evaluate(
            "github-actions", sources: ["runs": .null, "branch": .null],
            errors: ["runs": failure("notFound", command: "gh"), "branch": failure("notFound", command: "gh")],
            settings: repo
        )
        XCTAssertTrue(try strings(missing.viewTree).contains("https://cli.github.com"))
    }

    func testGitHubActionsAlertsFollowTheToggle() throws {
        let failed: JSONValue = .array([.object([
            "databaseId": .number(1), "name": .string("CI"), "displayTitle": .string("Fix"),
            "conclusion": .string("failure"), "headBranch": .string("main"),
            "createdAt": .string("2026-01-01T00:00:00Z"), "url": .string("https://github.com/cli/cli/actions/runs/1"),
        ])])
        let on = try evaluate("github-actions", sources: ["runs": failed, "branch": failed],
                              settings: ["repo": .string("cli/cli")])
        XCTAssertEqual(alert(on, "failing")?.active, true)
        let off = try evaluate("github-actions", sources: ["runs": failed, "branch": failed],
                               settings: ["repo": .string("cli/cli"), "alertOnFailure": .bool(false)])
        XCTAssertNil(alert(off, "failing")?.active)
    }

    // MARK: Site Monitor

    private func site(exit: Int, code: String = "000", network: JSONValue) throws -> WorkflowEngine.Output {
        try evaluate("site-monitor", sources: [
            "check": .object(["code": .string(code), "time": .string("0.000"), "exit": .number(Double(exit))]),
            "net": .object(["network": network]),
        ])
    }

    func testSiteMonitorIsNotDownWhileTheMacIsOffline() throws {
        let noInterface = try site(exit: 6, network: .object(["available": .bool(false), "address": .null]))
        XCTAssertNil(alert(noInterface, "down")?.active, "offline must not fire the down alert")
        XCTAssertNil(alert(noInterface, "recovered")?.active)
        XCTAssertEqual(noInterface.statusLabel, "—")
        XCTAssertTrue(try strings(noInterface.viewTree).contains("You’re offline"))

        let linkLocal = try site(exit: 7, network: .object(["available": .bool(true), "address": .string("fe80::1c2b:3d4e")]))
        XCTAssertNil(alert(linkLocal, "down")?.active, "no routable address is offline too")
    }

    func testSiteMonitorStillReportsARealOutage() throws {
        let online: JSONValue = .object(["available": .bool(true), "address": .string("192.168.1.20")])
        let dns = try site(exit: 6, network: online)
        XCTAssertEqual(alert(dns, "down")?.active, true, "the site's own DNS failing is down")
        let http = try site(exit: 0, code: "503", network: online)
        XCTAssertEqual(alert(http, "down")?.active, true)
        XCTAssertNil(alert(http, "slow")?.active, "the slow alert is opt-in")
    }

    // MARK: Downloads

    private func download(_ name: String, modifiedAt: Double) -> JSONValue {
        .object(["id": .string("/d/\(name)"), "path": .string("/d/\(name)"), "name": .string(name),
                 "modifiedAt": .number(modifiedAt), "size": .number(1), "isDirectory": .bool(false),
                 "ext": .string("")])
    }

    func testDownloadsCountsNewFilesUntilTheUserMarksThemSeen() throws {
        let checkedAt = Date().timeIntervalSince1970 * 1000 - 3_600_000
        let files: JSONValue = .object(["items": .array([
            download("new.zip", modifiedAt: checkedAt + 60_000),
            download("old.pdf", modifiedAt: checkedAt - 60_000),
        ]), "path": .string("/d")])
        let storage: [String: JSONValue] = ["checkedAt": .number(checkedAt)]

        let opened = try evaluate("downloads-new", sources: ["files": files], storage: storage)
        XCTAssertEqual(opened.statusLabel, "1")
        XCTAssertEqual(opened.writes.first { $0.key == "checkedAt" }?.value, .number(checkedAt),
                       "opening or a folder change keeps the baseline")

        let requested = try evaluate("downloads-new", sources: ["files": files], storage: storage, requested: true)
        let moved = try XCTUnwrap(requested.writes.first { $0.key == "checkedAt" }?.value.numberValue)
        XCTAssertGreaterThan(moved, checkedAt, "Mark as Seen moves the baseline")
    }

    func testDownloadsCapAndMissingFolder() throws {
        let items = (0..<500).map { download("f\($0)", modifiedAt: Double($0)) }
        let full = try evaluate("downloads-new", sources: ["files": .object(["items": .array(items)])],
                                storage: ["checkedAt": .number(1e15)])
        XCTAssertTrue(try strings(full.viewTree).contains("500+ files"))

        let missing = try evaluate("downloads-new", sources: ["files": .null],
                                   errors: ["files": failure("notFound")],
                                   storage: ["checkedAt": .number(42)])
        XCTAssertTrue(try strings(missing.viewTree).contains("Folder not found"))
        XCTAssertEqual(missing.writes.first { $0.key == "checkedAt" }?.value, .number(42))
    }

    // MARK: Recent Files, Homebrew, Docker

    func testRecentFilesGridSaysAMissingFolderIsMissing() throws {
        let output = try evaluate("recent-files-grid", sources: ["files": .null],
                                  errors: ["files": failure("notFound")])
        XCTAssertTrue(try strings(output.viewTree).contains("Folder not found"))
    }

    func testHomebrewUpdateAlertIsOptIn() throws {
        let brew: JSONValue = .object([
            "formulae": .array([.object(["name": .string("git"), "installed_versions": .array([.string("2.0")]),
                                         "current_version": .string("2.1"), "pinned": .bool(false)])]),
            "casks": .array([]),
        ])
        XCTAssertNil(alert(try evaluate("homebrew-updates", sources: ["brew": brew]), "updates")?.active)
        let on = try evaluate("homebrew-updates", sources: ["brew": brew], settings: ["alertOnUpdates": .bool(true)])
        XCTAssertEqual(alert(on, "updates")?.active, true)
        let failed = try evaluate("homebrew-updates", sources: ["brew": .object(["error": .string("failed")])],
                                  settings: ["alertOnUpdates": .bool(true)])
        XCTAssertNil(alert(failed, "updates")?.active, "a failed brew run is no reading")
        XCTAssertEqual(failed.statusLabel, "—")
    }

    func testDockerTintsAnUnhealthyContainer() throws {
        let docker: JSONValue = .object(["installed": .bool(true), "running": .bool(true), "containers": .array([
            .object(["ID": .string("a1"), "Names": .string("db"), "Image": .string("postgres"),
                     "Status": .string("Up 2 hours (unhealthy)"), "State": .string("running"), "Ports": .string("")]),
        ])])
        let output = try evaluate("docker", sources: ["docker": docker])
        XCTAssertEqual(output.statusTint, "warning")
        XCTAssertTrue(try strings(output.viewTree).contains("1 running · 1 unhealthy"))

        let down = try evaluate("docker", sources: ["docker": .object([
            "installed": .bool(true), "running": .bool(false), "containers": .array([]),
        ])])
        let shown = try strings(down.viewTree)
        XCTAssertTrue(shown.contains("com.docker.docker"))
        XCTAssertTrue(shown.contains("dev.kdrag0n.MacVirt"))
    }
}
