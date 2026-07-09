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
        case command, shellScript, httpJSON, pastedJSON, folder, staticText
        var id: String { rawValue }
        var label: String {
            switch self {
            case .command: return "Run a command"
            case .shellScript: return "Shell script"
            case .httpJSON: return "HTTP JSON"
            case .pastedJSON: return "Paste JSON"
            case .folder: return "Watch a folder"
            case .staticText: return "Static text"
            }
        }
        var symbol: String {
            switch self {
            case .command: return "terminal"
            case .shellScript: return "chevron.left.forwardslash.chevron.right"
            case .httpJSON: return "network"
            case .pastedJSON: return "curlybraces"
            case .folder: return "folder"
            case .staticText: return "text.alignleft"
            }
        }
    }

    /// One HTTP request header (auth etc.) for the HTTP JSON source.
    struct HeaderPair: Identifiable, Equatable {
        let id = UUID()
        var key: String = ""
        var value: String = ""
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
        case list, table, value, meter, text
        var id: String { rawValue }
        var label: String {
            switch self {
            case .list: return "List"
            case .table: return "Table"
            case .value: return "Single value"
            case .meter: return "Meter"
            case .text: return "Plain text"
            }
        }
    }

    /// Per-row click action for list/table displays.
    enum RowActionKind: String, CaseIterable, Identifiable {
        case none, copy, openURL, openFile
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "Nothing"
            case .copy: return "Copy a field"
            case .openURL: return "Open a field as a URL"
            case .openFile: return "Open a field as a file"
            }
        }
        /// Label for the field being acted on.
        var fieldPrompt: String {
            switch self {
            case .none: return ""
            case .copy: return "Field to copy"
            case .openURL: return "URL field"
            case .openFile: return "File-path field"
            }
        }
    }

    @Published var step: Step = .source

    // Source
    @Published var sourceKind: SourceKind = .command
    @Published var commandText = ""
    @Published var scriptText = "# Any shell — pipe, jq, awk…\necho '{\"value\": 42}'"
    @Published var httpURL = "https://api.github.com/repos/Open330/barshelf"
    @Published var httpHeaders: [HeaderPair] = []
    @Published var pastedJSONText = """
    [
      { "name": "Deploy API", "status": "success", "age": "2m ago" },
      { "name": "Nightly checks", "status": "running", "age": "14m ago" }
    ]
    """
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
    @Published var meterMax: Double = 100
    @Published var meterLabel = ""
    @Published var tableColumns: [WidgetBuilderScaffold.Column] = []

    // Refine (list/table over a structured source)
    @Published var filterEnabled = false
    @Published var filterField = ""
    @Published var filterIsNot = false
    @Published var filterValue = ""
    @Published var sortEnabled = false
    @Published var sortField = ""
    @Published var sortDescending = false
    @Published var limitEnabled = false
    @Published var limitCount = 10
    @Published var rowActionKind: RowActionKind = .none
    @Published var rowActionField = ""

    // Details
    @Published var name = ""
    @Published var icon = "square.grid.2x2"
    @Published var group = "My Widgets"
    @Published var size = "M"
    /// nil → onOpen only; otherwise interval seconds.
    @Published var refreshSeconds: Int? = nil
    @Published var appearanceAccent: String?
    @Published var appearanceDensity: WidgetAppearance.Density = .regular
    @Published var appearanceCardStyle: WidgetAppearance.CardStyle = .plain
    @Published var appearanceShowHeader = true

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
        case .shellScript: return !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .httpJSON: return httpURLHost != nil
        case .pastedJSON: return parsedPastedJSON != nil
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
        case .command, .shellScript, .httpJSON, .pastedJSON:
            return [.list, .table, .value, .meter, .text]
        }
    }

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && canAdvanceFromSource
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

    func selectSource(_ kind: SourceKind) {
        let changed = sourceKind != kind
        sourceKind = kind
        if changed {
            clearCommandTestState(clearFieldMappings: true)
        }
        if !availableDisplays.contains(displayKind) {
            displayKind = availableDisplays.first ?? .text
        }
        if kind == .pastedJSON {
            analyzePastedJSON()
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
        let argv = testArgv
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

    func fetchHTTPPreview() {
        let params: HttpSource.Params
        do {
            var object: [String: JSONValue] = ["url": .string(httpURL)]
            let headers = headerDictionary
            if !headers.isEmpty {
                object["headers"] = .object(headers.mapValues { .string($0) })
            }
            params = try HttpSource.Params(from: .object(object))
        } catch {
            testError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return
        }

        testRunning = true
        clearCommandTestState()
        Task {
            do {
                let json = try await HttpSource.fetch(params)
                let data = try JSONEncoder().encode(json)
                await MainActor.run {
                    self.testRunning = false
                    self.testOutput = String(data: data, encoding: .utf8) ?? String(describing: json)
                    self.applyDetectedJSON(json)
                    self.testError = nil
                }
            } catch {
                await MainActor.run {
                    self.testRunning = false
                    self.testError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    func useSampleJSON() {
        let sample: JSONValue = .array([
            .object([
                "name": .string("Deploy API"),
                "status": .string("success"),
                "age": .string("2m ago"),
            ]),
            .object([
                "name": .string("Nightly checks"),
                "status": .string("running"),
                "age": .string("14m ago"),
            ]),
            .object([
                "name": .string("Docs publish"),
                "status": .string("queued"),
                "age": .string("1h ago"),
            ]),
        ])
        applyDetectedJSON(sample)
        if let data = try? JSONEncoder().encode(sample),
           let text = String(data: data, encoding: .utf8) {
            testOutput = text
            if sourceKind == .pastedJSON {
                pastedJSONText = text
            }
        }
        testError = nil
    }

    func setPastedJSON(_ value: String) {
        pastedJSONText = value
        analyzePastedJSON()
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
        applyDetectedJSON(json)
    }

    private func analyzePastedJSON() {
        guard let data = pastedJSONText.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            if sourceKind == .pastedJSON {
                lastJSON = nil
                detectedFields = []
                detectedIsJSONArray = false
            }
            return
        }
        applyDetectedJSON(json)
    }

    private func applyDetectedJSON(_ json: JSONValue) {
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
            if valuePath.isEmpty { valuePath = keys.first ?? "" }
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
            detectedFields = []
        }
    }

    var hasStructuredJSON: Bool { lastJSON != nil || parsedPastedJSON != nil }
    var isCommandJSON: Bool { lastJSON != nil }

    var usesStructuredSource: Bool {
        sourceKind == .command || sourceKind == .shellScript
            || sourceKind == .httpJSON || sourceKind == .pastedJSON
    }

    /// argv used for the source "test run" — a shell script runs under `/bin/sh -c`.
    private var testArgv: [String] {
        switch sourceKind {
        case .shellScript: return ["/bin/sh", "-c", scriptText]
        default: return Self.tokenize(commandText)
        }
    }

    /// Non-empty request headers keyed for the HTTP source.
    private var headerDictionary: [String: String] {
        var out: [String: String] = [:]
        for pair in httpHeaders {
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = pair.value }
        }
        return out
    }

    var parsedPastedJSON: JSONValue? {
        guard let data = pastedJSONText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    var pastedJSONError: String? {
        pastedJSONText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Paste JSON to continue."
            : (parsedPastedJSON == nil ? "JSON is not valid yet." : nil)
    }

    private var httpURLHost: String? {
        guard let url = URL(string: httpURL),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return host
    }

    // MARK: - Spec assembly

    func makeSpec(usePreviewDefaults: Bool = false) -> WidgetBuilderScaffold.Spec {
        let source: WidgetBuilderScaffold.Source
        switch sourceKind {
        case .command:
            let structuredDisplay = effectiveDisplay != .text
            source = .command(argv: Self.tokenize(commandText), json: isCommandJSON || structuredDisplay)
        case .shellScript:
            let structuredDisplay = effectiveDisplay != .text
            source = .command(
                argv: ["/bin/sh", "-c", scriptText],
                json: isCommandJSON || structuredDisplay
            )
        case .httpJSON:
            source = .httpJSON(
                url: httpURL.trimmingCharacters(in: .whitespacesAndNewlines),
                headers: headerDictionary
            )
        case .pastedJSON:
            source = .staticJSON(parsedPastedJSON ?? Self.placeholderJSON)
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
        case .meter:
            display = .meter(
                valuePath: valuePath.trimmingCharacters(in: .whitespaces),
                maxValue: meterMax > 0 ? meterMax : 100,
                label: nonEmpty(meterLabel)
            )
        case .text:
            display = .text
        }

        return WidgetBuilderScaffold.Spec(
            name: resolvedName(usePreviewDefaults: usePreviewDefaults),
            icon: icon,
            group: group.trimmingCharacters(in: .whitespaces).isEmpty ? "My Widgets" : group,
            size: size,
            refreshIntervalSec: refreshSeconds,
            source: source,
            display: display,
            refine: refineApplicable ? buildRefine() : nil,
            rowAction: refineApplicable ? buildRowAction() : .none,
            appearance: manifestAppearance
        )
    }

    /// Filter/sort/limit + row actions only apply to array (list/table)
    /// displays over a structured source.
    var refineApplicable: Bool {
        usesStructuredSource && (effectiveDisplay == .list || effectiveDisplay == .table)
    }

    private func buildRefine() -> WidgetBuilderScaffold.Refine? {
        var filter: WidgetBuilderScaffold.Filter?
        if filterEnabled, !filterField.trimmingCharacters(in: .whitespaces).isEmpty {
            filter = .init(field: filterField, isNot: filterIsNot, value: Self.coerce(filterValue))
        }
        var sort: WidgetBuilderScaffold.SortBy?
        if sortEnabled, !sortField.trimmingCharacters(in: .whitespaces).isEmpty {
            sort = .init(field: sortField, descending: sortDescending)
        }
        let limit = limitEnabled ? max(1, limitCount) : nil
        let refine = WidgetBuilderScaffold.Refine(filter: filter, sort: sort, limit: limit)
        return refine.isEmpty ? nil : refine
    }

    private func buildRowAction() -> WidgetBuilderScaffold.RowAction {
        let field = rowActionField.trimmingCharacters(in: .whitespaces)
        guard rowActionKind != .none, !field.isEmpty else { return .none }
        switch rowActionKind {
        case .none: return .none
        case .copy: return .copy(field: field)
        case .openURL: return .openURL(field: field)
        case .openFile: return .openFile(field: field)
        }
    }

    /// Coerce a typed filter value: bare numbers and true/false keep their JSON
    /// type so filtering numeric/bool fields works; everything else is a string.
    static func coerce(_ raw: String) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if trimmed.range(of: "^-?[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil,
           let number = Double(trimmed) {
            return .number(number)
        }
        return .string(raw)
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

    private func resolvedName(usePreviewDefaults: Bool) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return usePreviewDefaults ? suggestedPreviewName : trimmed
    }

    var previewTitle: String { resolvedName(usePreviewDefaults: true) }

    private var suggestedPreviewName: String {
        switch sourceKind {
        case .command: return "Command Widget"
        case .shellScript: return "Script Widget"
        case .httpJSON: return "HTTP JSON Widget"
        case .pastedJSON: return "Pasted JSON Widget"
        case .folder: return "Folder Widget"
        case .staticText: return "Text Widget"
        }
    }

    var sizeDescription: String {
        switch size.uppercased() {
        case "XS": return "XS - compact strip"
        case "S": return "S - short card"
        case "L": return "L - tall showcase"
        default: return "M - standard card"
        }
    }

    var previewMinHeight: CGFloat {
        switch size.uppercased() {
        case "XS": return 56
        case "S": return 78
        case "L": return 160
        default: return 110
        }
    }

    private static let placeholderJSON: JSONValue = .object([
        "message": .string("Paste valid JSON to preview"),
    ])

    var previewAppearance: WidgetAppearance {
        WidgetAppearance(
            accent: appearanceAccent,
            density: appearanceDensity,
            cardStyle: appearanceCardStyle,
            showHeader: appearanceShowHeader
        )
    }

    private var manifestAppearance: WidgetAppearance? {
        let appearance = WidgetAppearance(
            accent: appearanceAccent,
            density: appearanceDensity == .regular ? nil : appearanceDensity,
            cardStyle: appearanceCardStyle == .plain ? nil : appearanceCardStyle,
            showHeader: appearanceShowHeader ? nil : false
        )
        return appearance == WidgetAppearance() ? nil : appearance
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
            let files = try WidgetBuilderScaffold.files(for: makeSpec(usePreviewDefaults: true))
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
        case .command, .shellScript:
            if let json = lastJSON { return ["data": json] }
            return ["data": .string(testOutput.isEmpty ? "(run the command to preview)" : testOutput)]
        case .httpJSON:
            if let json = lastJSON { return ["data": json] }
            return ["data": .object([
                "status": .string("preview"),
                "url": .string(httpURL),
            ])]
        case .pastedJSON:
            return ["data": parsedPastedJSON ?? Self.placeholderJSON]
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
