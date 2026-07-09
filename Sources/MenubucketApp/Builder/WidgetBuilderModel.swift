import AppKit
import Foundation
import MenubucketCore

/// Wizard state for the widget builder. Steps: source → display → details.
/// The model owns the "test run" (executes the source once, detects JSON,
/// exposes field keys) and the live preview (runs the real WorkflowEngine on
/// the scaffolded workflow), so the preview is what the widget will actually
/// render — not a mock.
@MainActor
final class WidgetBuilderModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case source, display, details
        var title: String {
            switch self {
            case .source: return "Source"
            case .display: return "Display"
            case .details: return "Details"
            }
        }
    }

    enum SourceKind: String, CaseIterable, Identifiable {
        case command, folder, staticText
        var id: String { rawValue }
        var label: String {
            switch self {
            case .command: return "Run a command"
            case .folder: return "Watch a folder"
            case .staticText: return "Static text"
            }
        }
        var symbol: String {
            switch self {
            case .command: return "terminal"
            case .folder: return "folder"
            case .staticText: return "text.alignleft"
            }
        }
    }

    struct CommandTemplate: Identifiable, Equatable {
        let id: String
        let title: String
        let command: String
        let suggestedName: String
        let suggestedIcon: String
    }

    static let commandTemplates: [CommandTemplate] = [
        .init(
            id: "github-actions",
            title: "GitHub Actions runs",
            command: "gh run list --limit 5 --json name,status,conclusion",
            suggestedName: "GitHub Actions",
            suggestedIcon: "bolt"
        ),
        .init(
            id: "kubernetes-pods",
            title: "Kubernetes pods",
            command: "kubectl get pods -o json | jq '[.items[] | {name: .metadata.name, phase: .status.phase}]'",
            suggestedName: "Kubernetes Pods",
            suggestedIcon: "network"
        ),
        .init(
            id: "disk-usage",
            title: "Disk usage",
            command: #"df -h / | tail -1 | awk '{print "{\"used\":\""$3"\",\"free\":\""$4"\",\"pct\":\""$5"\"}"}'"#,
            suggestedName: "Disk Usage",
            suggestedIcon: "gauge"
        ),
        .init(
            id: "homebrew-outdated",
            title: "Homebrew outdated",
            command: "brew outdated --json=v2 | jq '[.formulae[] | {name, current: .installed_versions[0], latest: .current_version}]'",
            suggestedName: "Homebrew Outdated",
            suggestedIcon: "cube.box"
        ),
        .init(
            id: "docker-containers",
            title: "Docker containers",
            command: "docker ps --format '{{json .}}' | jq -s '[.[] | {name: .Names, status: .Status}]'",
            suggestedName: "Docker Containers",
            suggestedIcon: "cube.box"
        ),
        .init(
            id: "recent-git-commits",
            title: "Recent git commits",
            command: #"git -C ~/your/repo log -5 --pretty=format:'{"hash":"%h","msg":"%s"}' | jq -s ."#,
            suggestedName: "Recent Commits",
            suggestedIcon: "clock"
        ),
    ]

    enum DisplayKind: String, CaseIterable, Identifiable {
        case list, table, value, text
        var id: String { rawValue }
        var label: String {
            switch self {
            case .list: return "List"
            case .table: return "Table"
            case .value: return "Single value"
            case .text: return "Plain text"
            }
        }
    }

    @Published var step: Step = .source

    // Source
    @Published var sourceKind: SourceKind = .command
    @Published var commandText = ""
    @Published var folderPath = "~/Downloads"
    @Published var folderLimit = 12
    @Published var staticContent = "Hello from BarShelf"

    // Test-run results (command source)
    @Published var testRunning = false
    @Published var testOutput = ""
    @Published var testError: String?
    /// Non-nil when stdout parsed as JSON — drives field pickers.
    @Published var detectedIsJSONArray = false
    @Published var detectedFields: [String] = []
    private var lastJSON: JSONValue?

    // Display
    @Published var displayKind: DisplayKind = .list
    @Published var listField = ""
    @Published var valuePath = ""
    @Published var valueCaption = ""
    @Published var tableColumns: [WidgetBuilderScaffold.Column] = []

    // Details
    @Published var name = ""
    @Published var icon = "square.grid.2x2"
    @Published var group = "My Widgets"
    @Published var size = "M"
    /// nil → onOpen only; otherwise interval seconds.
    @Published var refreshSeconds: Int? = nil

    // Result
    @Published var createdPath: URL?
    @Published var createError: String?

    let existingGroups: [String]
    var onClose: (() -> Void)?
    var onCreated: (() -> Void)?

    private let exec = ExecService()
    private var userEditedName = false
    private var userChoseIcon = false

    init(existingGroups: [String]) {
        self.existingGroups = existingGroups
        self.group = existingGroups.first ?? "My Widgets"
    }

    // MARK: - Step gating

    var canAdvanceFromSource: Bool {
        switch sourceKind {
        case .command: return !commandText.trimmingCharacters(in: .whitespaces).isEmpty
        case .folder: return !folderPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .staticText: return !staticContent.isEmpty
        }
    }

    /// Displays valid for the current source: a plain-text command or static
    /// text can only render as text/value; folder is always a list.
    var availableDisplays: [DisplayKind] {
        switch sourceKind {
        case .folder:
            return [.list]
        case .staticText:
            return [.text]
        case .command:
            return detectedIsJSONArray
                ? [.list, .table, .value, .text]
                : (lastJSON != nil ? [.value, .text] : [.text])
        }
    }

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Details prefill

    func applyCommandTemplate(_ template: CommandTemplate) {
        commandText = template.command
        clearCommandTestState(clearFieldMappings: true)
        if !userEditedName {
            name = template.suggestedName
        }
        if !userChoseIcon {
            icon = template.suggestedIcon
        }
    }

    func setName(_ value: String) {
        userEditedName = true
        name = value
    }

    func setIcon(_ value: String) {
        userChoseIcon = true
        icon = value
    }

    // MARK: - Command test run

    func runTest() {
        let argv = Self.tokenize(commandText)
        guard let first = argv.first, !first.isEmpty else { return }
        testRunning = true
        clearCommandTestState()

        Task {
            let result = await exec.run(
                command: argv,
                discover: [first, "PATH"],
                timeoutMs: 10_000,
                workingDirectory: nil
            )
            await MainActor.run {
                self.testRunning = false
                switch result {
                case let .failure(error):
                    self.testError = error.localizedDescription
                case let .success(data):
                    let text = String(data: data, encoding: .utf8) ?? ""
                    self.testOutput = String(text.prefix(4_000))
                    self.analyzeJSON(data)
                }
            }
        }
    }

    private func clearCommandTestState(clearFieldMappings: Bool = false) {
        testError = nil
        testOutput = ""
        lastJSON = nil
        detectedFields = []
        detectedIsJSONArray = false
        if clearFieldMappings {
            listField = ""
            valuePath = ""
            tableColumns = []
        }
    }

    private func analyzeJSON(_ data: Data) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return  // plain text
        }
        lastJSON = json
        switch json {
        case let .array(items):
            detectedIsJSONArray = true
            // Union of keys across the first few objects.
            var keys: [String] = []
            var seen: Set<String> = []
            for item in items.prefix(5) {
                if case let .object(obj) = item {
                    for key in obj.keys.sorted() where seen.insert(key).inserted {
                        keys.append(key)
                    }
                }
            }
            detectedFields = keys
            if listField.isEmpty { listField = keys.first ?? "" }
            if tableColumns.isEmpty {
                tableColumns = keys.prefix(2).map {
                    WidgetBuilderScaffold.Column(title: $0.capitalized, field: $0)
                }
            }
        case let .object(obj):
            detectedIsJSONArray = false
            detectedFields = obj.keys.sorted()
            if valuePath.isEmpty { valuePath = detectedFields.first ?? "" }
        default:
            detectedIsJSONArray = false
        }
    }

    var isCommandJSON: Bool { lastJSON != nil }

    // MARK: - Spec assembly

    func makeSpec() -> WidgetBuilderScaffold.Spec {
        let source: WidgetBuilderScaffold.Source
        switch sourceKind {
        case .command:
            source = .command(argv: Self.tokenize(commandText), json: isCommandJSON)
        case .folder:
            source = .folder(
                path: (folderPath as NSString).expandingTildeInPath,
                limit: max(1, folderLimit)
            )
        case .staticText:
            source = .staticText(staticContent)
        }

        let display: WidgetBuilderScaffold.Display
        switch effectiveDisplay {
        case .list:
            display = .list(field: sourceKind == .folder ? nil : nonEmpty(listField))
        case .table:
            display = .table(columns: tableColumns.filter { !$0.field.isEmpty })
        case .value:
            display = .value(valuePath: listOrValuePath(), caption: nonEmpty(valueCaption))
        case .text:
            display = .text
        }

        return WidgetBuilderScaffold.Spec(
            name: name.trimmingCharacters(in: .whitespaces),
            icon: icon,
            group: group.trimmingCharacters(in: .whitespaces).isEmpty ? "My Widgets" : group,
            size: size,
            refreshIntervalSec: refreshSeconds,
            source: source,
            display: display
        )
    }

    /// The chosen display, clamped to what the source supports.
    var effectiveDisplay: DisplayKind {
        availableDisplays.contains(displayKind) ? displayKind : (availableDisplays.first ?? .text)
    }

    private func listOrValuePath() -> String { valuePath }
    private func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // MARK: - Live preview

    enum Preview {
        case tree(UINode)
        case failure(String)
    }

    /// Runs the actual scaffold → WorkflowEngine pipeline against the test-run
    /// data (or a synthesized sample) and returns a UINode to render, or an
    /// error message.
    func previewTree() -> Preview {
        do {
            let files = try WidgetBuilderScaffold.files(for: makeSpec())
            let workflow = try WorkflowDefinition.decode(
                from: Data(files["workflow.json"]!.utf8)
            )
            let sources = previewSources()
            let settings: JSONValue = sourceKind == .folder
                ? .object(["folder": .string((folderPath as NSString).expandingTildeInPath)])
                : .object([:])
            let output = try WorkflowEngine.evaluate(
                workflow, sources: sources, settings: settings
            )
            return .tree(output.viewTree)
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func previewSources() -> [String: JSONValue] {
        switch sourceKind {
        case .command:
            if let json = lastJSON { return ["data": json] }
            return ["data": .string(testOutput.isEmpty ? "(run the command to preview)" : testOutput)]
        case .folder:
            // Live directory listing so the preview shows real files.
            if let params = try? FileSource.Params(from: .object([
                "path": .string((folderPath as NSString).expandingTildeInPath),
                "limit": .number(Double(folderLimit)),
            ])), let listing = try? FileSource.list(params) {
                return ["files": listing]
            }
            return ["files": .object(["items": .array([])])]
        case .staticText:
            return [:]
        }
    }

    // MARK: - Create

    func create() {
        let spec = makeSpec()
        do {
            let files = try WidgetBuilderScaffold.files(for: spec)
            let dir = HeadlessInstaller.defaultWidgetsDirectory
                .appendingPathComponent(spec.resolvedID, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, contents) in files {
                try contents.write(
                    to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8
                )
            }
            createdPath = dir
            createError = nil
            onCreated?()  // triggers WidgetRuntime rescan
        } catch {
            createError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func revealCreated() {
        guard let createdPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([createdPath])
    }

    // MARK: - Command tokenization (whitespace, honoring simple quotes)

    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in input.trimmingCharacters(in: .whitespaces) {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
