import MenubucketCore
import SwiftUI

/// Shortcuts-style 3-step widget builder. Left: the current step's controls.
/// Right (steps 2–3): a live preview rendered by the real WorkflowEngine +
/// ViewTreeRenderer, so what you see is what the widget will show.
struct WidgetBuilderView: View {
    @ObservedObject var model: WidgetBuilderModel
    @State private var advancedExpanded = false
    /// Reveals the free-text field for naming a brand-new panel (issue #5: the
    /// input is no longer permanently on screen).
    @State private var addingPanel = false
    private static let newPanelSentinel = "\u{1}__new_panel__"

    private let iconChoices = [
        "square.grid.2x2", "terminal", "folder", "gauge", "chart.bar",
        "bell", "calendar", "clock", "bolt", "cube.box", "network", "tag",
    ]
    private let sizes = ["XS", "S", "M", "L"]
    private let refreshChoices = [
        ("On open", 0),
        ("1s", 1),
        ("5s", 5),
        ("15s", 15),
        ("30s", 30),
        ("1m", 60),
        ("5m", 300),
        ("15m", 900),
    ]
    private struct AccentChoice: Identifiable {
        let id: String
        let name: String
        let value: String?
        let color: Color
    }
    private let accentChoices: [AccentChoice] = [
        .init(id: "default", name: "Default", value: nil, color: .accentColor),
        .init(id: "blue", name: "Blue", value: "blue", color: .blue),
        .init(id: "green", name: "Green", value: "green", color: .green),
        .init(id: "orange", name: "Orange", value: "orange", color: .orange),
        .init(id: "purple", name: "Purple", value: "purple", color: .purple),
        .init(id: "pink", name: "Pink", value: "pink", color: .pink),
    ]

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
                Text("Templates").font(.caption).foregroundStyle(.secondary)
                commandTemplatePicker
                Text("Command").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. gh run list --json name,status", text: $model.commandText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                HStack {
                    Button(model.testRunning ? "Running…" : "Test run") { model.runTest() }
                        .disabled(model.testRunning || model.commandText.isEmpty)
                    Button("Use sample JSON") { model.useSampleJSON() }
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
            case .shellScript:
                Text("Shell script").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.scriptText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                Text("Runs with /bin/sh -c — pipe, jq, awk, chained commands. Emit JSON for list / table / value / meter displays.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.testRunning ? "Running…" : "Test run") { model.runTest() }
                        .disabled(model.testRunning || !model.canAdvanceFromSource)
                    Button("Use sample JSON") { model.useSampleJSON() }
                    if model.detectedIsJSONArray {
                        Label("JSON array detected", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(.green)
                    } else if model.isCommandJSON {
                        Label("JSON object", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(.green)
                    } else if !model.testOutput.isEmpty && model.testError == nil {
                        Label("Plain text — renders as text", systemImage: "text.alignleft")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                previewOutputBlock
            case .httpJSON:
                Text("HTTPS JSON endpoint").font(.caption).foregroundStyle(.secondary)
                TextField("https://api.example.com/status.json", text: $model.httpURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                headerEditor
                HStack {
                    Button(model.testRunning ? "Fetching…" : "Fetch preview") {
                        model.fetchHTTPPreview()
                    }
                    .disabled(model.testRunning || !model.canAdvanceFromSource)
                    Button("Use sample JSON") { model.useSampleJSON() }
                    if model.hasStructuredJSON {
                        Label("JSON ready", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                previewOutputBlock
            case .pastedJSON:
                Text("JSON").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { model.pastedJSONText },
                    set: { model.setPastedJSON($0) }
                ))
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                HStack {
                    Button("Use sample JSON") { model.useSampleJSON() }
                    if let error = model.pastedJSONError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Label("JSON ready", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
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

    /// Editable list of HTTP request headers (auth etc.) for the HTTP source.
    private var headerEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Headers (optional)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.httpHeaders.append(.init()) } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless).font(.caption)
            }
            ForEach(Array(model.httpHeaders.enumerated()), id: \.element.id) { index, _ in
                HStack(spacing: 6) {
                    TextField("Header", text: Binding(
                        get: { model.httpHeaders[index].key },
                        set: { model.httpHeaders[index].key = $0 }
                    )).textFieldStyle(.roundedBorder).frame(width: 130)
                    TextField("Value", text: Binding(
                        get: { model.httpHeaders[index].value },
                        set: { model.httpHeaders[index].value = $0 }
                    )).textFieldStyle(.roundedBorder)
                    Button { model.httpHeaders.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove header \(index + 1)")
                }
            }
        }
    }

    @ViewBuilder
    private var previewOutputBlock: some View {
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
    }

    private func sourceCard(_ kind: WidgetBuilderModel.SourceKind) -> some View {
        Button {
            model.selectSource(kind)
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

    private var commandTemplatePicker: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(WidgetBuilderModel.commandTemplates) { template in
                commandTemplateChip(template)
            }
        }
    }

    private func commandTemplateChip(_ template: WidgetBuilderModel.CommandTemplate) -> some View {
        let selected = model.commandText == template.command
        return Button {
            model.applyCommandTemplate(template)
        } label: {
            Label {
                Text(template.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } icon: {
                Image(systemName: template.suggestedIcon)
                    .font(.system(size: 11, weight: .semibold))
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected
                    ? Color.accentColor.opacity(0.16)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.22)
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(template.command)
        .accessibilityLabel("Use \(template.title) command template")
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
            case .list where model.usesStructuredSource && !model.detectedFields.isEmpty:
                fieldPicker("Show field", selection: $model.listField)
            case .table:
                tableColumnEditor
            case .value:
                fieldPicker("Value field", selection: $model.valuePath)
                TextField("Caption (optional)", text: $model.valueCaption)
                    .textFieldStyle(.roundedBorder)
            case .meter:
                meterEditor
            default:
                Text(displayHint).font(.caption).foregroundStyle(.secondary)
            }

            if model.refineApplicable {
                refineSection
            }
        }
    }

    // MARK: Refine (filter / sort / limit / row action)

    private var refineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 2)
            Text("Refine (optional)").font(.system(size: 13, weight: .semibold))

            Toggle("Only keep rows that match", isOn: $model.filterEnabled)
                .toggleStyle(.switch)
                .onChange(of: model.filterEnabled) { on in
                    if on, model.filterField.isEmpty {
                        model.filterField = model.detectedFields.first ?? ""
                    }
                }
            if model.filterEnabled {
                HStack(spacing: 6) {
                    refineField($model.filterField)
                    Picker("", selection: $model.filterIsNot) {
                        Text("is").tag(false)
                        Text("is not").tag(true)
                    }
                    .labelsHidden().frame(width: 78)
                    TextField("value", text: $model.filterValue)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Toggle("Sort rows", isOn: $model.sortEnabled)
                .toggleStyle(.switch)
                .onChange(of: model.sortEnabled) { on in
                    if on, model.sortField.isEmpty {
                        model.sortField = model.detectedFields.first ?? ""
                    }
                }
            if model.sortEnabled {
                HStack(spacing: 6) {
                    refineField($model.sortField)
                    Picker("", selection: $model.sortDescending) {
                        Text("Asc").tag(false)
                        Text("Desc").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 112)
                }
            }

            Toggle("Limit number of rows", isOn: $model.limitEnabled)
                .toggleStyle(.switch)
            if model.limitEnabled {
                Stepper("Show at most \(model.limitCount)", value: $model.limitCount, in: 1...100)
                    .font(.system(size: 12))
            }

            Divider().padding(.vertical, 2)
            Text("When a row is clicked").font(.system(size: 12))
            Picker("", selection: $model.rowActionKind) {
                ForEach(WidgetBuilderModel.RowActionKind.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 260, alignment: .leading)
            .onChange(of: model.rowActionKind) { kind in
                if kind != .none, model.rowActionField.isEmpty {
                    model.rowActionField = model.detectedFields.first ?? ""
                }
            }
            if model.rowActionKind != .none {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.rowActionKind.fieldPrompt)
                        .font(.caption).foregroundStyle(.secondary)
                    refineField($model.rowActionField)
                }
            }
        }
    }

    /// Compact field selector reused across refine rows: a menu of detected
    /// fields, or a free-text box when none were detected.
    private func refineField(_ selection: Binding<String>) -> some View {
        Group {
            if model.detectedFields.isEmpty {
                TextField("field", text: selection)
                    .textFieldStyle(.roundedBorder).frame(width: 130)
            } else {
                Picker("", selection: selection) {
                    Text("—").tag("")
                    if !model.detectedFields.contains(selection.wrappedValue),
                       !selection.wrappedValue.isEmpty {
                        Text(selection.wrappedValue).tag(selection.wrappedValue)
                    }
                    ForEach(model.detectedFields, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 130)
            }
        }
    }

    private var displayHint: String {
        switch model.effectiveDisplay {
        case .grid:
            return "Files render as a thumbnail grid — drag out to Finder or click to open."
        case .list where model.sourceKind == .folder:
            return "Files render as rows with a thumbnail, name, and modified time."
        case .list where model.sourceKind == .httpJSON,
             .table where model.sourceKind == .httpJSON,
             .value where model.sourceKind == .httpJSON:
            return "Fetch the endpoint once to map fields from its JSON response."
        case .list where model.sourceKind == .pastedJSON,
             .table where model.sourceKind == .pastedJSON,
             .value where model.sourceKind == .pastedJSON:
            return "Paste valid JSON in step 1 to map fields."
        case .text:
            return "The raw source output is shown as text."
        default:
            return "Run the command in step 1 to map fields."
        }
    }

    private func fieldPicker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12))
            if model.detectedFields.isEmpty {
                TextField("Field path, e.g. name", text: selection)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("", selection: selection) {
                    if !model.detectedFields.contains(selection.wrappedValue),
                       !selection.wrappedValue.isEmpty {
                        Text(selection.wrappedValue).tag(selection.wrappedValue)
                    }
                    ForEach(model.detectedFields, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                TextField("Or type a custom field path", text: selection)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var tableColumnEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Columns").font(.system(size: 12))
            if model.detectedFields.isEmpty {
                Label(
                    "Run a JSON command or use sample JSON to auto-fill fields. You can also type field paths manually.",
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
                    if model.detectedFields.isEmpty {
                        TextField("field", text: Binding(
                            get: { model.tableColumns[index].field },
                            set: { model.tableColumns[index].field = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: Binding(
                            get: { model.tableColumns[index].field },
                            set: { model.tableColumns[index].field = $0 }
                        )) {
                            if !model.detectedFields.contains(model.tableColumns[index].field),
                               !model.tableColumns[index].field.isEmpty {
                                Text(model.tableColumns[index].field).tag(model.tableColumns[index].field)
                            }
                            ForEach(model.detectedFields, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    }
                    Button {
                        model.tableColumns.remove(at: index)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove column \(index + 1)")
                }
            }
            if model.tableColumns.count < 4 {
                let first = model.detectedFields.first ?? "name"
                Button {
                    model.tableColumns.append(.init(title: first.capitalized, field: first))
                } label: { Label("Add column", systemImage: "plus") }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    // MARK: Meter editor (one or more meters, bar / ring)

    private var meterEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.meters.enumerated()), id: \.element.id) { index, _ in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Meter \(index + 1)").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.meters[index].style },
                            set: { model.meters[index].style = $0 }
                        )) {
                            ForEach(WidgetBuilderModel.MeterStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 104)
                        if model.meters.count > 1 {
                            Button {
                                model.meters.remove(at: index)
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove meter \(index + 1)")
                        }
                    }
                    HStack(spacing: 6) {
                        Text("Field").font(.system(size: 12)).frame(width: 36, alignment: .leading)
                        refineField(Binding(
                            get: { model.meters[index].field },
                            set: { model.meters[index].field = $0 }
                        ))
                        Text("Max").font(.system(size: 12))
                        TextField("100", value: Binding(
                            get: { model.meters[index].maxValue },
                            set: { model.meters[index].maxValue = $0 }
                        ), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                    TextField("Label (optional)", text: Binding(
                        get: { model.meters[index].label },
                        set: { model.meters[index].label = $0 }
                    )).textFieldStyle(.roundedBorder)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
            if model.meters.count < 6 {
                Button {
                    model.meters.append(.init())
                } label: { Label("Add meter", systemImage: "plus") }
                    .buttonStyle(.borderless).font(.caption)
            }
            Text("Each meter reads a numeric field and fills at its max (100 → percentage).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 3 — details

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name & placement").font(.system(size: 13, weight: .semibold))
            TextField("Widget name", text: Binding(
                get: { model.name },
                set: { model.setName($0) }
            )).textFieldStyle(.roundedBorder)

            Text("Icon").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 6), spacing: 6) {
                ForEach(iconChoices, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .frame(width: 30, height: 30)
                        .background(model.icon == symbol ? Color.accentColor.opacity(0.2) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { model.setIcon(symbol) }
                        .accessibilityElement()
                        .accessibilityLabel("Icon \(symbol)")
                        .accessibilityAddTraits(
                            model.icon == symbol ? [.isButton, .isSelected] : .isButton
                        )
                }
            }
            HStack(spacing: 6) {
                Text("Or SF Symbol").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. gauge.badge.plus", text: Binding(
                    get: { model.icon },
                    set: { model.setIcon($0) }
                )).textFieldStyle(.roundedBorder)
                Image(systemName: model.icon)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            HStack {
                Text("Panel").font(.system(size: 12))
                Spacer()
                if addingPanel {
                    TextField("New panel name", text: $model.group)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                    Button {
                        if model.group.trimmingCharacters(in: .whitespaces).isEmpty {
                            model.group = model.existingGroups.first ?? "My Widgets"
                        }
                        addingPanel = false
                    } label: { Image(systemName: "checkmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Confirm new panel name")
                } else {
                    Picker("", selection: panelSelection) {
                        ForEach(model.existingGroups, id: \.self) { Text($0).tag($0) }
                        if !model.existingGroups.contains(model.group) {
                            Text(model.group).tag(model.group)
                        }
                        Divider()
                        Label("New Panel…", systemImage: "plus").tag(Self.newPanelSentinel)
                    }.labelsHidden().frame(width: 170)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Size").font(.system(size: 12))
                    Picker("", selection: $model.size) {
                        ForEach(sizes, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 172)
                }
                Text(model.sizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Refresh").font(.system(size: 12))
                        Picker("", selection: Binding(
                            get: { model.refreshSeconds ?? 0 },
                            set: { model.refreshSeconds = $0 == 0 ? nil : $0 }
                        )) {
                            ForEach(refreshChoices.indices, id: \.self) { index in
                                Text(refreshChoices[index].0).tag(refreshChoices[index].1)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    HStack {
                        Text("Custom (seconds)").font(.system(size: 12))
                        TextField("e.g. 45", value: Binding(
                            get: { model.refreshSeconds ?? 0 },
                            set: { model.refreshSeconds = $0 <= 0 ? nil : $0 }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    }
                    Text("Short intervals are useful while testing; production widgets should usually stay at 30s or slower.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            appearanceSection

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

    /// Panel dropdown selection: picking "New Panel…" clears the name and
    /// reveals the text field instead of committing the sentinel value.
    private var panelSelection: Binding<String> {
        Binding(
            get: { model.group },
            set: { value in
                if value == Self.newPanelSentinel {
                    model.group = ""
                    addingPanel = true
                } else {
                    model.group = value
                }
            }
        )
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 2)
            Text("Appearance").font(.system(size: 13, weight: .semibold))
            Text("Accent").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(accentChoices) { choice in
                    accentSwatch(choice)
                }
            }

            HStack {
                Text("Density").font(.system(size: 12))
                Picker("", selection: $model.appearanceDensity) {
                    Text("Regular").tag(WidgetAppearance.Density.regular)
                    Text("Compact").tag(WidgetAppearance.Density.compact)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            HStack {
                Text("Card").font(.system(size: 12))
                Picker("", selection: $model.appearanceCardStyle) {
                    Text("Plain").tag(WidgetAppearance.CardStyle.plain)
                    Text("Tinted").tag(WidgetAppearance.CardStyle.tinted)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            Toggle("Show header", isOn: $model.appearanceShowHeader)
                .toggleStyle(.switch)
        }
    }

    private func accentSwatch(_ choice: AccentChoice) -> some View {
        let selected = model.appearanceAccent == choice.value
        return Button {
            model.appearanceAccent = choice.value
        } label: {
            ZStack {
                Circle()
                    .fill(choice.color)
                    .frame(width: 24, height: 24)
                if choice.value == nil {
                    Circle()
                        .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 3)
                        .frame(width: 10, height: 10)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(3)
            .background(selected ? Color.primary.opacity(0.08) : .clear)
            .clipShape(Circle())
            .overlay(Circle().stroke(selected ? Color.primary.opacity(0.28) : Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .help(choice.name)
        .accessibilityLabel("\(choice.name) accent")
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live preview").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.size)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            Divider()
            Group {
                switch model.previewTree() {
                case let .tree(node):
                    ScrollView {
                        previewCard(node)
                            .padding(18)
                    }
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

    private func previewCard(_ node: UINode) -> some View {
        let appearance = model.previewAppearance
        let accent = appearance.accentColor ?? .accentColor
        let inset: CGFloat = appearance.density == .compact ? 8 : 12
        // The name/icon header is part of the rendered tree (the scaffold emits
        // it when "Show header" is on), so the preview shows it exactly once —
        // no separate chrome header here.
        return VStack(alignment: .leading, spacing: 8) {
            ViewTreeRenderer(node: node)
                .environment(\.widgetAppearance, appearance)
        }
        .padding(inset)
        .frame(maxWidth: .infinity, minHeight: model.previewMinHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(appearance.cardStyle == .tinted ? accent.opacity(0.12) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
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
