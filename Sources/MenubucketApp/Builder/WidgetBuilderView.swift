import MenubucketCore
import SwiftUI

/// Shortcuts-style 3-step widget builder. Left: the current step's controls.
/// Right (steps 2–3): a live preview rendered by the real WorkflowEngine +
/// ViewTreeRenderer, so what you see is what the widget will show.
struct WidgetBuilderView: View {
    @ObservedObject var model: WidgetBuilderModel

    private let iconChoices = [
        "square.grid.2x2", "terminal", "folder", "gauge", "chart.bar",
        "bell", "calendar", "clock", "bolt", "cube.box", "network", "tag",
    ]
    private let sizes = ["S", "M", "L"]

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            Divider()
            HStack(spacing: 0) {
                controls
                    .frame(maxWidth: model.step == .source ? .infinity : 320, alignment: .leading)
                if model.step != .source {
                    Divider()
                    preview
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            footer
        }
    }

    // MARK: Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 16) {
            ForEach(WidgetBuilderModel.Step.allCases, id: \.self) { step in
                HStack(spacing: 6) {
                    Image(systemName: step.rawValue < model.step.rawValue
                        ? "checkmark.circle.fill"
                        : (step == model.step ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(step == model.step ? Color.accentColor : .secondary)
                    Text(step.title)
                        .font(.system(size: 12, weight: step == model.step ? .semibold : .regular))
                        .foregroundStyle(step == model.step ? .primary : .secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch model.step {
                case .source: sourceStep
                case .display: displayStep
                case .details: detailsStep
                }
            }
            .padding(16)
        }
    }

    // MARK: Step 1 — source

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where does this widget's data come from?")
                .font(.system(size: 13, weight: .semibold))
            ForEach(WidgetBuilderModel.SourceKind.allCases) { kind in
                sourceCard(kind)
            }
            Divider().padding(.vertical, 4)
            switch model.sourceKind {
            case .command:
                Text("Command").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. gh run list --json name,status", text: $model.commandText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                HStack {
                    Button(model.testRunning ? "Running…" : "Test run") { model.runTest() }
                        .disabled(model.testRunning || model.commandText.isEmpty)
                    if model.detectedIsJSONArray {
                        Label("JSON array detected", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(.green)
                    } else if model.isCommandJSON {
                        Label("JSON object", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(.green)
                    } else if !model.testOutput.isEmpty && model.testError == nil {
                        // Ran fine but not JSON — say so instead of leaving the
                        // user guessing why the field pickers are empty.
                        Label("Plain text — renders as text", systemImage: "text.alignleft")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let err = model.testError {
                    Label {
                        Text(err).lineLimit(3)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                } else if !model.testOutput.isEmpty {
                    ScrollView {
                        Text(model.testOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            case .folder:
                Text("Folder").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("~/Downloads", text: $model.folderPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFolder() }
                }
                Stepper("Max files: \(model.folderLimit)", value: $model.folderLimit, in: 4...48)
                    .font(.system(size: 12))
            case .staticText:
                Text("Text").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.staticContent)
                    .font(.system(size: 12))
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            }
        }
    }

    private func sourceCard(_ kind: WidgetBuilderModel.SourceKind) -> some View {
        Button {
            model.sourceKind = kind
        } label: {
            HStack {
                Image(systemName: kind.symbol).frame(width: 22)
                Text(kind.label).font(.system(size: 12))
                Spacer()
                if model.sourceKind == kind {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .padding(10)
            .background(model.sourceKind == kind ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 2 — display

    private var displayStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How should it look?").font(.system(size: 13, weight: .semibold))
            Picker("", selection: $model.displayKind) {
                ForEach(model.availableDisplays) { d in Text(d.label).tag(d) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Divider().padding(.vertical, 2)

            switch model.effectiveDisplay {
            case .list where model.sourceKind == .command && !model.detectedFields.isEmpty:
                fieldPicker("Show field", selection: $model.listField)
            case .table:
                tableColumnEditor
            case .value:
                fieldPicker("Value field", selection: $model.valuePath)
                TextField("Caption (optional)", text: $model.valueCaption)
                    .textFieldStyle(.roundedBorder)
            default:
                Text(displayHint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var displayHint: String {
        switch model.effectiveDisplay {
        case .list where model.sourceKind == .folder:
            return "Files render as rows with a thumbnail, name, and modified time."
        case .text:
            return "The raw source output is shown as text."
        default:
            return "Run the command in step 1 to map fields."
        }
    }

    private func fieldPicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Picker("", selection: selection) {
                ForEach(model.detectedFields, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 160)
        }
    }

    private var tableColumnEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Columns").font(.system(size: 12))
            if model.detectedFields.isEmpty {
                Label(
                    "Run a command that returns a JSON array in step 1 to pick columns.",
                    systemImage: "info.circle"
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(model.tableColumns.enumerated()), id: \.offset) { index, _ in
                HStack {
                    TextField("Header", text: Binding(
                        get: { model.tableColumns[index].title },
                        set: { model.tableColumns[index].title = $0 }
                    )).textFieldStyle(.roundedBorder).frame(width: 110)
                    Picker("", selection: Binding(
                        get: { model.tableColumns[index].field },
                        set: { model.tableColumns[index].field = $0 }
                    )) {
                        ForEach(model.detectedFields, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                    Button {
                        model.tableColumns.remove(at: index)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove column \(index + 1)")
                }
            }
            if model.tableColumns.count < 4, let first = model.detectedFields.first {
                Button {
                    model.tableColumns.append(.init(title: first.capitalized, field: first))
                } label: { Label("Add column", systemImage: "plus") }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    // MARK: Step 3 — details

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name & placement").font(.system(size: 13, weight: .semibold))
            TextField("Widget name", text: $model.name).textFieldStyle(.roundedBorder)

            Text("Icon").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 6), spacing: 6) {
                ForEach(iconChoices, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .frame(width: 30, height: 30)
                        .background(model.icon == symbol ? Color.accentColor.opacity(0.2) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { model.icon = symbol }
                        .accessibilityElement()
                        .accessibilityLabel("Icon \(symbol)")
                        .accessibilityAddTraits(
                            model.icon == symbol ? [.isButton, .isSelected] : .isButton
                        )
                }
            }

            HStack {
                Text("Bucket").font(.system(size: 12))
                Spacer()
                Picker("", selection: $model.group) {
                    ForEach(model.existingGroups, id: \.self) { Text($0).tag($0) }
                    if !model.existingGroups.contains(model.group) {
                        Text(model.group).tag(model.group)
                    }
                }.labelsHidden().frame(width: 150)
            }
            TextField("Or new bucket name", text: $model.group).textFieldStyle(.roundedBorder)

            HStack {
                Text("Size").font(.system(size: 12))
                Picker("", selection: $model.size) {
                    ForEach(sizes, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }

            HStack {
                Text("Refresh").font(.system(size: 12))
                Picker("", selection: Binding(
                    get: { model.refreshSeconds ?? 0 },
                    set: { model.refreshSeconds = $0 == 0 ? nil : $0 }
                )) {
                    Text("On open").tag(0)
                    Text("30s").tag(30)
                    Text("1m").tag(60)
                    Text("5m").tag(300)
                    Text("15m").tag(900)
                }.labelsHidden().frame(width: 150)
            }

            if let created = model.createdPath {
                Divider()
                Label("Created \(created.lastPathComponent)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.system(size: 12))
                Button("Reveal in Finder") { model.revealCreated() }.font(.caption)
            }
            if let err = model.createError {
                Label {
                    Text(err)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 0) {
            Text("Live preview").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            Divider()
            Group {
                switch model.previewTree() {
                case let .tree(node):
                    ScrollView { ViewTreeRenderer(node: node).padding(8) }
                case let .failure(message):
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.step != .source {
                Button("Back") { model.step = WidgetBuilderModel.Step(rawValue: model.step.rawValue - 1)! }
            }
            Spacer()
            Button("Cancel") { model.onClose?() }
            switch model.step {
            case .source:
                Button("Next") { model.step = .display }
                    .keyboardShortcut(.defaultAction).disabled(!model.canAdvanceFromSource)
            case .display:
                Button("Next") { model.step = .details }.keyboardShortcut(.defaultAction)
            case .details:
                if model.createdPath == nil {
                    Button("Create") { model.create() }
                        .keyboardShortcut(.defaultAction).disabled(!model.canCreate)
                } else {
                    Button("Done") { model.onClose?() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { model.folderPath = url.path }
    }
}
