import XCTest
@testable import MenubucketCore

/// Opt-in harness for widget authors: runs one workflow widget's real
/// sources on this Mac (commands, HTTPS, files, literal values) the way the
/// app does, evaluates the workflow, and prints what the card and the menu
/// bar would show. Nothing is installed or approved; commands still have to
/// be covered by the manifest's exec allowlist.
///
///     BARSHELF_PROBE_DIR=widgets/system swift test --filter WidgetProbe
///     BARSHELF_PROBE_SETTINGS='{"city":"Seoul"}'   # optional overrides
///     BARSHELF_PROBE_REQUESTED=1                   # as if the user pressed Refresh
///
/// `system` sources are not run here (they need the app's samplers).
final class WidgetProbe: XCTestCase {
    func testProbe() async throws {
        guard let path = ProcessInfo.processInfo.environment["BARSHELF_PROBE_DIR"] else {
            throw XCTSkip("set BARSHELF_PROBE_DIR to a workflow widget directory")
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        let manifest = try Manifest.decode(from: Data(contentsOf: directory.appendingPathComponent("widget.json")))
        let workflowURL = directory.appendingPathComponent(manifest.entry.main ?? "workflow.json")
        let definition = try WorkflowDefinition.decode(from: Data(contentsOf: workflowURL))
        var settings = manifest.settingsDefaults().objectValue ?? [:]
        if let raw = ProcessInfo.processInfo.environment["BARSHELF_PROBE_SETTINGS"],
           case let .object(overrides) = try JSONValue.parse(Data(raw.utf8)) {
            for (key, value) in overrides { settings[key] = value }
        }
        let requested = ProcessInfo.processInfo.environment["BARSHELF_PROBE_REQUESTED"] == "1"
        let widget: JSONValue = .object(["locale": .string("en"), "size": .string(manifest.bucket?.size ?? "M"),
                                         "visible": .bool(true), "requested": .bool(requested)])
        let params = try WorkflowEngine.resolvedSourceParams(definition, settings: .object(settings), widget: widget)

        var sources: [String: JSONValue] = [:]
        for (id, source) in definition.sources.sorted(by: { $0.key < $1.key }) {
            let value = params[id] ?? .object([:])
            do {
                switch source.use {
                case "exec":
                    let command = value.objectValue?["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    guard let permission = ExecAllowlist.match(command: command, permissions: manifest.permissions?.exec) else {
                        print("PROBE source \(id): BLOCKED, not in permissions.exec: \(command)")
                        continue
                    }
                    let data: Data = try await withCheckedThrowingContinuation { done in
                        ExecService().run(command: command, discover: value.objectValue?["discover"]?.arrayValue?.compactMap(\.stringValue),
                                          timeoutMs: value.objectValue?["timeoutMs"]?.numberValue.map(Int.init) ?? 15_000,
                                          workingDirectory: directory,
                                          stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes) { done.resume(with: $0) }
                    }
                    sources[id] = value.objectValue?["parse"]?.stringValue == "text"
                        ? .string(String(decoding: data, as: UTF8.self)) : try JSONValue.parse(data)
                case "http":
                    sources[id] = try await HttpSource.fetch(HttpSource.Params(from: value))
                case "fs.json":
                    sources[id] = try FileSource.readJSON(FileSource.JSONFileParams(from: value),
                                                          authorizedBy: manifest.permissions?.readPaths ?? [])
                case "fs.directory":
                    sources[id] = try FileSource.list(FileSource.Params(from: value))
                case "value":
                    sources[id] = value
                default:
                    print("PROBE source \(id): skipped (\(source.use) runs only in the app)")
                }
                print("PROBE source \(id): ok \(String(describing: sources[id]).prefix(300))")
            } catch {
                print("PROBE source \(id): ERROR \(error.localizedDescription)")
            }
        }

        let output = try WorkflowEngine.evaluate(definition, sources: sources, settings: .object(settings), widget: widget)
        print("PROBE status label: \(output.statusLabel ?? "-")  tooltip: \(output.statusTooltip ?? "-")")
        for metric in output.statusMetrics ?? [] { print("PROBE metric: \(metric.label ?? "") \(metric.value)") }
        print("PROBE card text: \(Self.texts(output.viewTree).joined(separator: " | ").prefix(1200))")
        for alert in output.alerts { print("PROBE alert \(alert.id): \(alert.active.map { "\($0)" } ?? "no reading") — \(alert.title)") }
    }

    private static func texts(_ node: UINode) -> [String] {
        var out: [String] = []
        if let text = node.text, !text.isEmpty { out.append(text) }
        for child in node.children ?? [] { out += texts(child) }
        return out
    }
}
