import Foundation

/// Generates widget bundle files (`widget.json` + `workflow.json`) from a
/// builder specification. The builder UI (BarShelf's Shortcuts-style wizard)
/// composes a `Spec`; this type turns it into files that pass `barshelf validate`
/// and evaluate through `WorkflowEngine` — no hand-written JSON.
///
/// Every builder widget is a **workflow** (declarative, no user code): command,
/// HTTP JSON, pasted JSON, folder, and text sources become workflow primitives.
public enum WidgetBuilderScaffold {
    // MARK: Spec

    public enum Source: Equatable {
        /// `argv` run as an exec source. `json == true` parses stdout as JSON
        /// (list/table/value displays); otherwise stdout is a plain string.
        /// A multi-line shell script is just `["/bin/sh", "-c", script]`.
        case command(argv: [String], json: Bool)
        /// `http` JSON fetch over HTTPS, with optional request headers (auth).
        case httpJSON(url: String, headers: [String: String] = [:])
        /// Fixed JSON pasted into the builder. Stored as a literal `value` source.
        case staticJSON(JSONValue)
        /// `fs.directory` over `path` (user-editable via a `folder` setting).
        case folder(path: String, limit: Int)
        /// Fixed text — a view-only workflow, no I/O, no permissions.
        case staticText(String)
    }

    public enum Display: Equatable {
        /// One text per array item, from `field` (e.g. `"name"`); nil → the
        /// item itself stringified (arrays of scalars).
        case list(field: String?)
        /// One row per array item; `columns` are (header, field) pairs.
        case table(columns: [Column])
        /// A single prominent value from `valuePath` in an object source.
        case value(valuePath: String, caption: String?)
        /// A numeric `valuePath` rendered as a labeled progress bar. `maxValue`
        /// scales the fraction (default 100 → percentage).
        case meter(valuePath: String, maxValue: Double, label: String?)
        /// Raw source text (command stdout / static text) in one block.
        case text
    }

    public struct Column: Equatable {
        public var title: String
        public var field: String
        public init(title: String, field: String) {
            self.title = title
            self.field = field
        }
    }

    // MARK: Refine (filter / sort / limit) + row action

    /// Keep only rows whose `field` equals (or, when `isNot`, differs from)
    /// `value`. Compiles to the engine's `filter` transform.
    public struct Filter: Equatable {
        public var field: String
        public var isNot: Bool
        public var value: JSONValue
        public init(field: String, isNot: Bool = false, value: JSONValue) {
            self.field = field
            self.isNot = isNot
            self.value = value
        }
    }

    /// Order rows by `field`. Compiles to the engine's `sort` transform.
    public struct SortBy: Equatable {
        public var field: String
        public var descending: Bool
        public init(field: String, descending: Bool = false) {
            self.field = field
            self.descending = descending
        }
    }

    /// Optional post-source refinement for array (list/table) displays. Each
    /// present stage compiles to one transform, chained filter → sort → limit.
    public struct Refine: Equatable {
        public var filter: Filter?
        public var sort: SortBy?
        public var limit: Int?
        public init(filter: Filter? = nil, sort: SortBy? = nil, limit: Int? = nil) {
            self.filter = filter
            self.sort = sort
            self.limit = limit
        }
        public var isEmpty: Bool {
            (filter?.field.isEmpty ?? true) && (sort?.field.isEmpty ?? true) && (limit ?? 0) <= 0
        }
    }

    /// What happens when a rendered row is clicked (list/table displays).
    public enum RowAction: Equatable {
        case none
        /// Copy `field`'s value to the clipboard.
        case copy(field: String)
        /// Open `field`'s value as a URL.
        case openURL(field: String)
        /// Open `field`'s value as a file path.
        case openFile(field: String)
    }

    public struct Spec: Equatable {
        public var name: String
        public var icon: String
        public var group: String
        public var size: String          // "XS" | "S" | "M" | "L"
        public var refreshIntervalSec: Int?  // nil → onOpen only
        public var source: Source
        public var display: Display
        /// Optional filter/sort/limit applied to array (list/table) displays.
        public var refine: Refine?
        /// Optional per-row click action for list/table displays.
        public var rowAction: RowAction
        /// Render a `folder` source as a thumbnail grid instead of a row list.
        public var folderGrid: Bool
        public var appearance: WidgetAppearance?
        /// Override the derived id (defaults to `dev.barshelf.user.<slug>`).
        public var id: String?

        public init(
            name: String,
            icon: String = "square.grid.2x2",
            group: String = "My Widgets",
            size: String = "M",
            refreshIntervalSec: Int? = nil,
            source: Source,
            display: Display,
            refine: Refine? = nil,
            rowAction: RowAction = .none,
            folderGrid: Bool = false,
            appearance: WidgetAppearance? = nil,
            id: String? = nil
        ) {
            self.name = name
            self.icon = icon
            self.group = group
            self.size = size
            self.refreshIntervalSec = refreshIntervalSec
            self.source = source
            self.display = display
            self.refine = refine
            self.rowAction = rowAction
            self.folderGrid = folderGrid
            self.appearance = appearance
            self.id = id
        }

        public var resolvedID: String {
            id ?? "dev.barshelf.user.\(WidgetBuilderScaffold.slug(from: name))"
        }
    }

    public enum ScaffoldError: Error, LocalizedError, Equatable {
        case emptyName
        case emptyCommand
        case invalidHTTPURL(String)
        case displayNeedsArraySource
        case noColumns

        public var errorDescription: String? {
            switch self {
            case .emptyName: return "widget name is empty"
            case .emptyCommand: return "command is empty"
            case let .invalidHTTPURL(url):
                return "http JSON source needs a valid https URL (got \(url))"
            case .displayNeedsArraySource:
                return "list/table displays need a command (JSON) or folder source"
            case .noColumns: return "table display needs at least one column"
            }
        }
    }

    // MARK: Generation

    /// Returns the bundle files keyed by relative path.
    /// Always `["widget.json", "workflow.json"]`.
    public static func files(for spec: Spec) throws -> [String: String] {
        let manifest = try manifestObject(for: spec)
        let workflow = try workflowObject(for: spec)
        return [
            "widget.json": try encode(manifest),
            "workflow.json": try encode(workflow),
        ]
    }

    public static func slug(from name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "widget" : trimmed
    }

    // MARK: Manifest

    private static func manifestObject(for spec: Spec) throws -> [String: Any] {
        guard !spec.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ScaffoldError.emptyName
        }

        var manifest: [String: Any] = [
            "$schema": "https://barshelf.dev/schema/widget-0.1.json",
            "schemaVersion": 1,
            "id": spec.resolvedID,
            "name": spec.name,
            "version": "0.1.0",
            "icon": spec.icon,
            "bucket": ["group": spec.group, "order": 100, "size": spec.size],
            "entry": ["kind": "workflow", "main": "workflow.json"],
        ]

        var refresh: [String: Any] = ["onOpen": true, "staleAfterSec": 300]
        if let interval = spec.refreshIntervalSec {
            refresh["interval"] = interval
        } else {
            refresh["interval"] = NSNull()
        }
        manifest["refresh"] = refresh
        if let appearance = spec.appearance,
           let object = appearanceObject(appearance) {
            manifest["appearance"] = object
        }

        // Permissions mirror the selected source. These are what the first-run
        // approval card shows the user.
        switch spec.source {
        case let .command(argv, _):
            guard let executable = argv.first, !executable.isEmpty else {
                throw ScaffoldError.emptyCommand
            }
            let args = Array(argv.dropFirst())
            manifest["permissions"] = [
                "exec": [[
                    "command": executable,
                    "allowedArgs": [args],
                    "maxOutputBytes": 1_048_576,
                    "sensitiveOutput": false,
                ]],
            ]
        case let .httpJSON(url, _):
            let host = try networkHost(from: url)
            manifest["permissions"] = ["network": [host]]
        case .staticJSON:
            break
        case .folder(let path, _):
            manifest["permissions"] = ["readPaths": [path]]
            manifest["settings"] = [[
                "key": "folder",
                "title": "Folder",
                "type": "directory",
                "default": path,
            ]]
        case .staticText:
            break
        }

        return manifest
    }

    private static func appearanceObject(_ appearance: WidgetAppearance) -> [String: Any]? {
        var object: [String: Any] = [:]
        if let accent = appearance.accent?.trimmingCharacters(in: .whitespaces),
           !accent.isEmpty {
            object["accent"] = accent
        }
        if let density = appearance.density {
            object["density"] = density.rawValue
        }
        if let cardStyle = appearance.cardStyle {
            object["cardStyle"] = cardStyle.rawValue
        }
        if let showHeader = appearance.showHeader {
            object["showHeader"] = showHeader
        }
        return object.isEmpty ? nil : object
    }

    // MARK: Workflow

    private static func workflowObject(for spec: Spec) throws -> [String: Any] {
        var workflow: [String: Any] = ["schemaVersion": 1, "kind": "workflow"]
        var sources: [String: Any] = [:]
        var transforms: [String: Any] = [:]

        let header = headerNode(spec.name, icon: spec.icon)

        let bodyNode: [String: Any]
        switch spec.source {
        case let .command(argv, json):
            sources["data"] = [
                "use": "exec",
                "with": [
                    "command": argv,
                    "parse": json ? "json" : "text",
                ],
            ]
            let (refineTransforms, arrayPath) = refineChain(spec.refine, base: "$.sources.data")
            transforms.merge(refineTransforms) { _, new in new }
            bodyNode = try body(
                display: spec.display, arrayPath: arrayPath,
                objectPath: "sources.data", rowAction: spec.rowAction
            )

        case let .httpJSON(url, headers):
            var with: [String: Any] = ["url": url]
            if !headers.isEmpty { with["headers"] = headers }
            sources["data"] = ["use": "http", "with": with]
            let (refineTransforms, arrayPath) = refineChain(spec.refine, base: "$.sources.data")
            transforms.merge(refineTransforms) { _, new in new }
            bodyNode = try body(
                display: spec.display, arrayPath: arrayPath,
                objectPath: "sources.data", rowAction: spec.rowAction
            )

        case let .staticJSON(value):
            sources["data"] = [
                "use": "value",
                "with": jsonObject(value),
            ]
            let (refineTransforms, arrayPath) = refineChain(spec.refine, base: "$.sources.data")
            transforms.merge(refineTransforms) { _, new in new }
            bodyNode = try body(
                display: spec.display, arrayPath: arrayPath,
                objectPath: "sources.data", rowAction: spec.rowAction
            )

        case let .folder(path, limit):
            sources["files"] = [
                "use": "fs.directory",
                "with": [
                    "path": "${settings.folder}",
                    "watch": true,
                    "skipHidden": true,
                    "sortBy": "modifiedAt",
                    "sortDirection": "descending",
                    "limit": limit,
                ],
            ]
            _ = path  // baked as the settings default in the manifest
            bodyNode = spec.folderGrid ? folderGridNode() : folderListNode()

        case let .staticText(content):
            bodyNode = ["type": "text", "role": "body", "text": content]
        }

        workflow["sources"] = sources
        if !transforms.isEmpty {
            workflow["transforms"] = transforms
        }
        workflow["view"] = [
            "type": "vstack",
            "spacing": 0,
            "children": [
                header,
                ["type": "divider"],
                ["type": "vstack", "spacing": 6, "padding": 10, "children": [bodyNode]],
            ],
        ]
        return workflow
    }

    private static func headerNode(_ title: String, icon: String) -> [String: Any] {
        [
            "type": "hstack",
            "spacing": 8,
            "padding": 10,
            "children": [
                ["type": "image", "source": ["kind": "sfSymbol", "name": icon], "size": 14, "tint": "secondary"],
                ["type": "text", "role": "title", "text": title, "lineLimit": 1],
            ],
        ]
    }

    private static func body(
        display: Display, arrayPath: String, objectPath: String,
        rowAction: RowAction = .none
    ) throws -> [String: Any] {
        switch display {
        case let .list(field):
            // string(...) keeps numeric/bool fields renderable in text nodes.
            let text = field.map { "${string(row.\($0))}" } ?? "${string(row)}"
            let rowID = field.map { "row-${string(row.\($0))}" } ?? "row"
            var template: [String: Any] = [
                "type": "hstack",
                "id": rowID,
                "children": [["type": "text", "role": "body", "text": text, "lineLimit": 1]],
            ]
            if let action = actionObject(rowAction) { template["action"] = action }
            return [
                "type": "list",
                "spacing": 2,
                "items": [
                    "forEach": arrayPath,
                    "as": "row",
                    "template": template,
                ],
            ]

        case let .table(columns):
            guard !columns.isEmpty else { throw ScaffoldError.noColumns }
            var cells: [[String: Any]] = []
            for (index, col) in columns.enumerated() {
                if index > 0 { cells.append(["type": "spacer"]) }
                cells.append([
                    "type": "text",
                    "role": index == 0 ? "body" : "caption",
                    "text": "${string(row.\(col.field))}",
                    "lineLimit": 1,
                ])
            }
            let rowID = "row-${string(row.\(columns[0].field))}"
            var template: [String: Any] = ["type": "hstack", "id": rowID, "children": cells]
            if let action = actionObject(rowAction) { template["action"] = action }
            return [
                "type": "list",
                "spacing": 2,
                "items": [
                    "forEach": arrayPath,
                    "as": "row",
                    "template": template,
                ],
            ]

        case let .value(valuePath, caption):
            var children: [[String: Any]] = [
                ["type": "text", "role": "title", "text": "${string(\(objectPath).\(valuePath))}", "monospacedDigit": true],
            ]
            if let caption {
                children.append(["type": "text", "role": "caption", "text": caption])
            }
            return ["type": "vstack", "spacing": 2, "children": children]

        case let .meter(valuePath, maxValue, label):
            let path = "\(objectPath).\(valuePath)"
            let maxLiteral = numberLiteral(maxValue <= 0 ? 100 : maxValue)
            let suffix = maxValue == 100 ? "%" : ""
            return [
                "type": "vstack",
                "spacing": 4,
                "children": [
                    [
                        "type": "hstack",
                        "children": [
                            ["type": "text", "role": "caption", "text": label ?? valuePath, "lineLimit": 1],
                            ["type": "spacer"],
                            [
                                "type": "text", "role": "caption", "monospacedDigit": true,
                                "text": "${string(round(number(\(path)), 0))}\(suffix)",
                            ],
                        ],
                    ],
                    [
                        "type": "progress",
                        "style": "linear",
                        "tint": "accent",
                        "value": "${div(number(\(path)), \(maxLiteral))}",
                    ],
                ],
            ]

        case .text:
            return ["type": "text", "role": "body", "text": "${string(\(objectPath))}"]
        }
    }

    private static func folderGridNode() -> [String: Any] {
        [
            "type": "grid",
            "spacing": 10,
            "padding": 6,
            "size": 70,
            "items": [
                "forEach": "$.sources.files.items",
                "as": "file",
                "template": [
                    "type": "vstack",
                    "spacing": 4,
                    "id": "tile-${file.path}",
                    "drag": ["filePath": "${file.path}"],
                    "action": ["type": "openFile", "path": "${file.path}"],
                    "children": [
                        ["type": "image", "source": ["kind": "fileThumbnail", "path": "${file.path}", "modifiedAt": "${file.modifiedAt}"], "size": 48],
                        ["type": "text", "role": "caption", "text": "${file.name}", "lineLimit": 1],
                    ],
                ],
            ],
        ]
    }

    private static func folderListNode() -> [String: Any] {
        [
            "type": "list",
            "spacing": 2,
            "items": [
                "forEach": "$.sources.files.items",
                "as": "file",
                "template": [
                    "type": "hstack",
                    "id": "file-${file.path}",
                    "spacing": 8,
                    "drag": ["filePath": "${file.path}"],
                    "action": ["type": "openFile", "path": "${file.path}"],
                    "children": [
                        ["type": "image", "source": ["kind": "fileThumbnail", "path": "${file.path}", "modifiedAt": "${file.modifiedAt}"], "size": 22],
                        ["type": "vstack", "spacing": 2, "widthFill": true, "children": [
                            ["type": "text", "role": "body", "text": "${file.name}", "lineLimit": 1],
                            ["type": "text", "role": "caption", "foreground": "tertiary", "text": "${date.relative(file.modifiedAt)}"],
                        ]],
                    ],
                ],
            ],
        ]
    }

    /// Compiles a `Refine` into a chained `filter → sort → limit` transform set
    /// and returns the path of the final array to feed the display's `forEach`.
    /// Empty/absent stages are skipped; with no refinement the base path is used.
    static func refineChain(_ refine: Refine?, base: String) -> (transforms: [String: Any], arrayPath: String) {
        guard let refine, !refine.isEmpty else { return ([:], base) }
        var transforms: [String: Any] = [:]
        var current = base

        if let filter = refine.filter, !filter.field.isEmpty {
            let matchKey = filter.isNot ? "notEquals" : "equals"
            transforms["refined_filter"] = [
                "use": "filter",
                "from": current,
                "with": ["field": filter.field, matchKey: jsonObject(filter.value)],
            ]
            current = "$.transforms.refined_filter"
        }
        if let sort = refine.sort, !sort.field.isEmpty {
            transforms["refined_sort"] = [
                "use": "sort",
                "from": current,
                "with": ["by": sort.field, "direction": sort.descending ? "descending" : "ascending"],
            ]
            current = "$.transforms.refined_sort"
        }
        if let limit = refine.limit, limit > 0 {
            transforms["refined_limit"] = [
                "use": "limit",
                "from": current,
                "with": ["count": limit],
            ]
            current = "$.transforms.refined_limit"
        }
        return (transforms, current)
    }

    /// Builds a row-click `action` node, or nil for `.none`.
    static func actionObject(_ action: RowAction) -> [String: Any]? {
        switch action {
        case .none:
            return nil
        case let .copy(field):
            return ["type": "copyText", "value": "${string(row.\(field))}", "toast": "Copied"]
        case let .openURL(field):
            return ["type": "openURL", "url": "${string(row.\(field))}"]
        case let .openFile(field):
            return ["type": "openFile", "path": "${string(row.\(field))}"]
        }
    }

    private static func networkHost(from urlString: String) throws -> String {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty
        else {
            throw ScaffoldError.invalidHTTPURL(urlString)
        }
        return host
    }

    /// Formats a Double for embedding in an expression string (`100`, not `100.0`).
    private static func numberLiteral(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }

    private static func jsonObject(_ value: JSONValue) -> Any {
        switch value {
        case let .string(text):
            return text
        case let .number(number):
            return number
        case let .bool(flag):
            return flag
        case .null:
            return NSNull()
        case let .array(items):
            return items.map(jsonObject)
        case let .object(object):
            return object.mapValues(jsonObject)
        }
    }

    // MARK: Encoding

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }
}
