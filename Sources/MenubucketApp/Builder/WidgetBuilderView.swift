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
        (String(localized: "On open", comment: "Widget refresh interval: only when the popup opens"), 0),
        ("1s", 1),
        ("5s", 5),
        ("15s", 15),
        ("30s", 30),
        ("1m", 60),
        ("5m", 300),
        ("15m", 900),
    ]
    @State private var confirmingCancel = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CompactPageHeader(tab: .create)
                stepIndicator
            }
            .padding(.horizontal, Spacing.m)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.xs)
            .frame(maxWidth: model.step == .source ? SettingsMetrics.contentWidth : .infinity)
            .frame(maxWidth: .infinity)
            Divider()
            HStack(spacing: 0) {
                if model.step == .source {
                    // The settings pages' readable column.
                    controls
                        .frame(maxWidth: SettingsMetrics.contentWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                } else {
                    controls
                        .frame(maxWidth: 320, alignment: .leading)
                    Divider()
                    preview
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            footer
        }
        .confirmationDialog("Discard this widget?", isPresented: $confirmingCancel) {
            Button("Discard", role: .destructive) { model.onClose?() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("What you've set up so far is not saved.")
        }
    }

    private func cancel() {
        if model.hasDraft { confirmingCancel = true } else { model.onClose?() }
    }

    // MARK: Step indicator

    /// Numbered steps joined by a line, the done ones checked: a stepper,
    /// not a row of radio buttons.
    private var stepIndicator: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(WidgetBuilderModel.Step.allCases, id: \.self) { step in
                let done = step.rawValue < model.step.rawValue
                let current = step == model.step
                if step.rawValue > 0 {
                    Capsule()
                        .fill(done || current ? Color.accentColor : Fill.track)
                        .frame(width: Spacing.l, height: Spacing.hair)
                        .accessibilityHidden(true)
                }
                HStack(spacing: Spacing.stack) {
                    ZStack {
                        Circle()
                            .fill(current || done ? Color.accentColor : Fill.track)
                        if done {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(current || done ? Color.white : Color.secondary)
                    .frame(width: ControlMetrics.smallHeight - Spacing.xxs, height: ControlMetrics.smallHeight - Spacing.xxs)
                    Text(step.title)
                        .font(.callout.weight(current ? .semibold : .regular))
                        .foregroundStyle(current ? .primary : .secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Step \(step.rawValue + 1) of \(WidgetBuilderModel.Step.allCases.count): \(step.title)"))
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s + Spacing.hair) {
                switch model.step {
                case .source: sourceStep
                case .display: displayStep
                case .details: detailsStep
                }
            }
            .padding(Spacing.m)
        }
    }

    // MARK: Step 1 — source

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Where does this widget's data come from?")
                .font(.headline)
            ForEach(WidgetBuilderModel.SourceKind.allCases) { kind in
                sourceCard(kind)
            }
            Divider().padding(.vertical, Spacing.xxs)
            switch model.sourceKind {
            case .command:
                Text("Templates").font(.caption).foregroundStyle(.secondary)
                commandTemplatePicker
                Text("Command").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. gh run list --json name,status", text: $model.commandText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                HStack {
                    Button(model.testRunning ? "Running…" : "Test run") { model.runTest() }
                        .disabled(model.testRunning || model.commandText.isEmpty)
                    Button("Use sample JSON") { model.useSampleJSON() }
                    if model.detectedIsJSONArray {
                        Label("JSON array detected", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(StatusTone.success.color)
                    } else if model.isCommandJSON {
                        Label("JSON object", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(StatusTone.success.color)
                    } else if !model.testOutput.isEmpty && model.testError == nil {
                        // Ran fine but not JSON — say so instead of leaving the
                        // user guessing why the field pickers are empty.
                        Label("Plain text — renders as text", systemImage: "text.alignleft")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let err = model.testError {
                    ExplainedErrorView(error: err, context: .test)
                } else if !model.testOutput.isEmpty {
                    ScrollView {
                        Text(model.testOutput)
                            .font(.subheadline.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                }
            case .shellScript:
                Text("Shell script").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.scriptText)
                    .font(.callout.monospaced())
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Fill.hairline))
                Text("Runs with /bin/sh -c — pipe, jq, awk, chained commands. Emit JSON for list / table / value / meter displays.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.testRunning ? "Running…" : "Test run") { model.runTest() }
                        .disabled(model.testRunning || !model.canAdvanceFromSource)
                    Button("Use sample JSON") { model.useSampleJSON() }
                    if model.detectedIsJSONArray {
                        Label("JSON array detected", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(StatusTone.success.color)
                    } else if model.isCommandJSON {
                        Label("JSON object", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(StatusTone.success.color)
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
                    .font(.callout.monospaced())
                headerEditor
                HStack {
                    Button(model.testRunning ? "Fetching…" : "Fetch preview") {
                        model.fetchHTTPPreview()
                    }
                    .disabled(model.testRunning || !model.canAdvanceFromSource)
                    Button("Use sample JSON") { model.useSampleJSON() }
                    if model.hasStructuredJSON {
                        Label("JSON ready", systemImage: "curlybraces")
                            .font(.caption).foregroundStyle(StatusTone.success.color)
                    }
                }
                previewOutputBlock
            case .pastedJSON:
                Text("JSON").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { model.pastedJSONText },
                    set: { model.setPastedJSON($0) }
                ))
                .font(.callout.monospaced())
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Fill.hairline))
                HStack {
                    Button("Use sample JSON") { model.useSampleJSON() }
                    if let error = model.pastedJSONError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(StatusTone.warning.color)
                    } else {
                        Label("JSON ready", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(StatusTone.success.color)
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
                    .font(.callout)
            case .staticText:
                Text("Text").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.staticContent)
                    .font(.callout)
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Fill.hairline))
            }
        }
    }

    /// Editable list of HTTP request headers (auth etc.) for the HTTP source.
    private var headerEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            HStack {
                Text("Headers (optional)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.httpHeaders.append(.init()) } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless).font(.caption)
            }
            ForEach(Array(model.httpHeaders.enumerated()), id: \.element.id) { index, _ in
                HStack(spacing: Spacing.stack) {
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
            if !model.httpHeaders.isEmpty {
                Label(
                    "Header values are saved as plain text with the widget. Do not paste API tokens or passwords.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption2)
                .foregroundStyle(StatusTone.warning.color)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var previewOutputBlock: some View {
        if let err = model.testError {
            ExplainedErrorView(error: err, context: .test)
        } else if !model.testOutput.isEmpty {
            ScrollView {
                Text(model.testOutput)
                    .font(.subheadline.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
    }

    private func sourceCard(_ kind: WidgetBuilderModel.SourceKind) -> some View {
        Button {
            model.selectSource(kind)
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: kind.symbol).frame(width: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(kind.label).font(.callout)
                    Text(kind.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if model.sourceKind == kind {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .padding(Spacing.xs + Spacing.hair)
            .background(model.sourceKind == kind ? Color.accentColor.opacity(Fill.Wash.medium) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control + Spacing.hair))
            .overlay(RoundedRectangle(cornerRadius: Radius.control + Spacing.hair).strokeBorder(Fill.hairline))
        }
        .buttonStyle(.plain)
    }

    private var commandTemplatePicker: some View {
        LazyVGrid(
            // Three even columns: the six templates fill two rows, with no
            // chip left alone on a row of its own.
            columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: 3),
            alignment: .leading,
            spacing: Spacing.xs
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
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } icon: {
                Image(systemName: template.suggestedIcon)
                    .font(.subheadline.weight(.semibold))
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected
                    ? Color.accentColor.opacity(Fill.Wash.strong)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Fill.hairline)
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
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("How should it look?").font(.headline)
            Picker("Display", selection: $model.displayKind) {
                ForEach(model.availableDisplays) { d in Text(d.label).tag(d) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Divider().padding(.vertical, Spacing.hair)

            switch model.effectiveDisplay {
            case .list where model.usesStructuredSource && !model.detectedFields.isEmpty:
                fieldPicker("Show field", selection: $model.listField)
                optionalFieldRow("Secondary line", selection: $model.listSecondaryField)
                optionalFieldRow("Trailing value", selection: $model.listTrailingField)
                Text("Secondary shows under the title; trailing is right-aligned (e.g. a status).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: Spacing.xs + Spacing.hair) {
            Divider().padding(.vertical, Spacing.hair)
            Text("Refine (optional)").font(.headline)

            Toggle("Only keep rows that match", isOn: $model.filterEnabled)
                .toggleStyle(.switch)
                // A switch drops its title from accessibility; name it.
                .accessibilityLabel(Text("Only keep rows that match"))
                .onChange(of: model.filterEnabled) { _, on in
                    if on, model.filterField.isEmpty {
                        model.filterField = model.detectedFields.first ?? ""
                    }
                }
            if model.filterEnabled {
                HStack(spacing: Spacing.stack) {
                    refineField($model.filterField)
                    Picker("Match", selection: $model.filterIsNot) {
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
                // A switch drops its title from accessibility; name it.
                .accessibilityLabel(Text("Sort rows"))
                .onChange(of: model.sortEnabled) { _, on in
                    if on, model.sortField.isEmpty {
                        model.sortField = model.detectedFields.first ?? ""
                    }
                }
            if model.sortEnabled {
                HStack(spacing: Spacing.stack) {
                    refineField($model.sortField)
                    Picker("Sort order", selection: $model.sortDescending) {
                        Text("Asc").tag(false)
                        Text("Desc").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 112)
                }
            }

            Toggle("Limit number of rows", isOn: $model.limitEnabled)
                .toggleStyle(.switch)
                // A switch drops its title from accessibility; name it.
                .accessibilityLabel(Text("Limit number of rows"))
            if model.limitEnabled {
                Stepper("Show at most \(model.limitCount)", value: $model.limitCount, in: 1...100)
                    .font(.callout)
            }

            Divider().padding(.vertical, Spacing.hair)
            Text("When a row is clicked").font(.callout)
            Text("What clicking one of the widget's rows does.")
                .font(.caption).foregroundStyle(.secondary)
            // What the widget does: a radio group (`Components.swift`, choices).
            Picker("When a row is clicked", selection: $model.rowActionKind) {
                ForEach(WidgetBuilderModel.RowActionKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: model.rowActionKind) { _, kind in
                if kind != .none, model.rowActionField.isEmpty {
                    model.rowActionField = model.detectedFields.first ?? ""
                }
            }
            if model.rowActionKind != .none {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
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
                Picker("Field", selection: selection) {
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
            return String(localized: "Files render as a thumbnail grid — drag out to Finder or click to open.")
        case .list where model.sourceKind == .folder:
            return String(localized: "Files render as rows with a thumbnail, name, and modified time.")
        case .list where model.sourceKind == .httpJSON,
             .table where model.sourceKind == .httpJSON,
             .value where model.sourceKind == .httpJSON:
            return String(localized: "Fetch the endpoint once to map fields from its JSON response.")
        case .list where model.sourceKind == .pastedJSON,
             .table where model.sourceKind == .pastedJSON,
             .value where model.sourceKind == .pastedJSON:
            return String(localized: "Paste valid JSON in step 1 to map fields.")
        case .text:
            return String(localized: "The raw source output is shown as text.")
        default:
            return String(localized: "Run the command in step 1 to map fields.")
        }
    }

    /// A labeled, optional field selector ("—" clears it). Used for the list
    /// row's secondary/trailing fields.
    private func optionalFieldRow(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            refineField(selection)
        }
    }

    private func fieldPicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title).font(.callout)
            if model.detectedFields.isEmpty {
                TextField("Field path, e.g. name", text: selection)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker(title, selection: selection) {
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
        VStack(alignment: .leading, spacing: Spacing.stack) {
            Text("Columns").font(.callout)
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
        VStack(alignment: .leading, spacing: Spacing.xs + Spacing.hair) {
            ForEach(Array(model.meters.enumerated()), id: \.element.id) { index, _ in
                VStack(alignment: .leading, spacing: Spacing.stack) {
                    HStack {
                        Text("Meter \(index + 1)").font(.callout.weight(.medium))
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
                    HStack(spacing: Spacing.stack) {
                        Text("Field").font(.callout).frame(width: 36, alignment: .leading)
                        refineField(Binding(
                            get: { model.meters[index].field },
                            set: { model.meters[index].field = $0 }
                        ))
                        Text("Max").font(.callout)
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
                .padding(Spacing.xs)
                .background(RoundedRectangle(cornerRadius: Radius.control + Spacing.hair).fill(Fill.card))
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
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Name & placement").font(.headline)
            TextField("Widget name", text: Binding(
                get: { model.name },
                set: { model.setName($0) }
            )).textFieldStyle(.roundedBorder)

            Text("Icon").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 6), spacing: Spacing.stack) {
                ForEach(iconChoices, id: \.self) { symbol in
                    Button { model.setIcon(symbol) } label: {
                        Image(systemName: symbol)
                            .frame(width: 30, height: 30)
                            .background(model.icon == symbol ? Color.accentColor.opacity(Fill.Wash.strong) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Icon \(symbol)")
                        .accessibilityAddTraits(
                            model.icon == symbol ? [.isSelected] : []
                        )
                }
            }
            HStack(spacing: Spacing.stack) {
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
                Text("Page").font(.callout)
                Spacer()
                if addingPanel {
                    TextField("New page name", text: $model.group)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                    Button {
                        if model.group.trimmingCharacters(in: .whitespaces).isEmpty {
                            model.group = model.existingGroups.first ?? "My Widgets"
                        }
                        addingPanel = false
                    } label: { Image(systemName: "checkmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Confirm new page name")
                } else {
                    Picker("Page", selection: panelSelection) {
                        ForEach(model.existingGroups, id: \.self) { Text($0).tag($0) }
                        if !model.existingGroups.contains(model.group) {
                            Text(model.group).tag(model.group)
                        }
                        Divider()
                        Label("New Page…", systemImage: "plus").tag(Self.newPanelSentinel)
                    }.labelsHidden().frame(width: 170)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack {
                    Text("Size").font(.callout)
                    Picker("Size", selection: $model.size) {
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
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("Refresh").font(.callout)
                        Picker("Refresh", selection: Binding(
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
                        Text("Custom (seconds)").font(.callout)
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
                    .foregroundStyle(StatusTone.success.color).font(.callout)
                HStack(spacing: Spacing.xs) {
                    if let id = model.createdWidgetID {
                        Button("Show in Popup") { WidgetInstaller.shared.onReveal?(id) }
                            .buttonStyle(.glass(.secondary))
                            .controlSize(.small)
                    }
                    Button("Show in Finder") { model.revealCreated() }
                        .buttonStyle(.glass(.secondary))
                        .controlSize(.small)
                }
            }
            if let err = model.createError {
                Label {
                    Text(err)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption).foregroundStyle(StatusTone.critical.color)
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
        VStack(alignment: .leading, spacing: Spacing.xs + Spacing.hair) {
            Divider().padding(.vertical, Spacing.hair)
            Text("Appearance").font(.headline)
            Text("Accent").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: Spacing.stack) {
                ForEach(AccentPalette.swatches) { swatch in
                    AccentSwatchButton(swatch: swatch, isSelected: AccentPalette.matches(swatch.value, model.appearanceAccent)) {
                        model.appearanceAccent = swatch.value
                    }
                }
            }

            HStack {
                Text("Density").font(.callout)
                Picker("Density", selection: $model.appearanceDensity) {
                    Text("Regular").tag(WidgetAppearance.Density.regular)
                    Text("Compact").tag(WidgetAppearance.Density.compact)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            Toggle("Show header", isOn: $model.appearanceShowHeader)
                .toggleStyle(.switch)
                // A switch drops its title from accessibility; name it.
                .accessibilityLabel(Text("Show header"))
        }
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
                    .padding(.horizontal, Spacing.stack)
                    .padding(.vertical, Spacing.hair)
                    .background(Capsule().fill(Fill.hover))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.xs + Spacing.hair)
            Divider()
            Group {
                switch model.previewTree() {
                case let .tree(node):
                    ScrollView {
                        previewCard(node)
                            .padding(Spacing.m + Spacing.hair)
                    }
                case let .failure(message):
                    VStack(spacing: Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(StatusTone.warning.color)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// Drawn the way the popup draws a card: a flat section with the card
    /// header (icon and name) when it is on —
    /// so what the preview shows is what lands on the shelf.
    private func previewCard(_ node: UINode) -> some View {
        let appearance = model.previewAppearance
        let accent = appearance.accentColor ?? .accentColor
        let inset: CGFloat = Spacing.s
        return VStack(alignment: .leading, spacing: Spacing.stack) {
            if appearance.showsHeader {
                HStack(spacing: Spacing.stack) {
                    Image(systemName: model.icon)
                        .font(.caption)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text(model.previewTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.xxs)
                    Text("Updated just now")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ViewTreeRenderer(node: node)
                .environment(\.widgetAppearance, appearance)
        }
        .padding(.horizontal, inset + 2)
        .padding(.vertical, Spacing.xs + Spacing.hair)
        .frame(maxWidth: .infinity, minHeight: model.previewMinHeight, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.xs) {
            if model.step != .source {
                Button("Back") { model.step = WidgetBuilderModel.Step(rawValue: model.step.rawValue - 1)! }
                    .buttonStyle(.glass(.plain))
                    .keyboardShortcut("[", modifiers: .command)
                    .hoverHint("Back", key: "⌘[")
            }
            Spacer()
            if model.createdPath == nil {
                // Esc, and a question first when there is something to lose.
                Button("Cancel", action: cancel)
                    .buttonStyle(.glass(.plain))
                    .keyboardShortcut(.cancelAction)
            }
            Group {
                switch model.step {
                // "Continue", as onboarding says it, with the key it answers to.
                case .source:
                    Button { model.step = .display } label: { ShortcutLabel("Continue", key: "↵") }
                        .keyboardShortcut(.defaultAction).disabled(!model.canAdvanceFromSource)
                case .display:
                    Button { model.step = .details } label: { ShortcutLabel("Continue", key: "↵") }
                        .keyboardShortcut(.defaultAction)
                case .details:
                    if model.createdPath == nil {
                        Button { model.create() } label: { ShortcutLabel("Create", key: "↵") }
                            .keyboardShortcut(.defaultAction).disabled(!model.canCreate)
                    } else {
                        Button { model.onClose?() } label: { ShortcutLabel("Done", key: "↵") }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .buttonStyle(.glass(.primary))
        }
        .padding(Spacing.s)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { model.folderPath = url.path }
    }
}
