import Foundation

/// Generates widget bundle files (`widget.json` + `workflow.json`) from a
/// builder specification. The builder UI (BarShelf's Shortcuts-style wizard)
/// composes a `Spec`; this type turns it into files that pass `mbk validate`
/// and evaluate through `WorkflowEngine` — no hand-written JSON.
///
/// Every builder widget is a **workflow** (declarative, no user code): a
/// command source becomes a workflow `exec` source, a folder source becomes
/// `fs.directory`, static text becomes a view-only workflow.
public enum WidgetBuilderScaffold {
    // MARK: Spec

    public enum Source: Equatable {
        /// `argv` run as an exec source. `json == true` parses stdout as JSON
        /// (list/table/value displays); otherwise stdout is a plain string.
        case command(argv: [String], json: Bool)
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

    public struct Spec: Equatable {
        public var name: String
        public var icon: String
        public var group: String
        public var size: String          // "XS" | "S" | "M" | "L"
        public var refreshIntervalSec: Int?  // nil → onOpen only
        public var source: Source
        public var display: Display
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
            id: String? = nil
        ) {
            self.name = name
            self.icon = icon
            self.group = group
            self.size = size
            self.refreshIntervalSec = refreshIntervalSec
            self.source = source
            self.display = display
            self.id = id
        }

        public var resolvedID: String {
            id ?? "dev.barshelf.user.\(WidgetBuilderScaffold.slug(from: name))"
        }
    }

    public enum ScaffoldError: Error, LocalizedError, Equatable {
        case emptyName
        case emptyCommand
        case displayNeedsArraySource
        case noColumns

        public var errorDescription: String? {
            switch self {
            case .emptyName: return "widget name is empty"
            case .emptyCommand: return "command is empty"
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

        // Permissions: only a command source needs an exec allowlist entry —
        // that entry is what the first-run approval card shows the user.
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

    // MARK: Workflow

    private static func workflowObject(for spec: Spec) throws -> [String: Any] {
        var workflow: [String: Any] = ["schemaVersion": 1, "kind": "workflow"]
        var sources: [String: Any] = [:]

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
            bodyNode = try body(display: spec.display, arrayPath: "$.sources.data", objectPath: "sources.data")

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
            bodyNode = folderListNode()

        case let .staticText(content):
            bodyNode = ["type": "text", "role": "body", "text": content]
        }

        workflow["sources"] = sources
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
        display: Display, arrayPath: String, objectPath: String
    ) throws -> [String: Any] {
        switch display {
        case let .list(field):
            // string(...) keeps numeric/bool fields renderable in text nodes.
            let text = field.map { "${string(row.\($0))}" } ?? "${string(row)}"
            let rowID = field.map { "row-${string(row.\($0))}" } ?? "row"
            return [
                "type": "list",
                "spacing": 2,
                "items": [
                    "forEach": arrayPath,
                    "as": "row",
                    "template": [
                        "type": "hstack",
                        "id": rowID,
                        "children": [["type": "text", "role": "body", "text": text, "lineLimit": 1]],
                    ],
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
            return [
                "type": "list",
                "spacing": 2,
                "items": [
                    "forEach": arrayPath,
                    "as": "row",
                    "template": ["type": "hstack", "id": rowID, "children": cells],
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

        case .text:
            return ["type": "text", "role": "body", "text": "${string(\(objectPath))}"]
        }
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

    // MARK: Encoding

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }
}
