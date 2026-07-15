import Foundation
import MenubucketCore

/// `barshelf new` — writes a minimal, valid widget package of the requested kind.
public enum WidgetScaffold {
    public enum Kind: String, CaseIterable, Sendable {
        case exec
        case workflow
        case script
    }

    public enum ScaffoldError: Error, LocalizedError, Equatable {
        case invalidName(String)
        case directoryNotEmpty(String)

        public var errorDescription: String? {
            switch self {
            case let .invalidName(name):
                return "invalid widget name \"\(name)\" — use letters/digits plus"
                    + " '-', '_', '.' (must start with a letter or digit)"
            case let .directoryNotEmpty(path):
                return "target directory is not empty: \(path)"
            }
        }
    }

    /// Creates `directory` (if needed) and writes the template files.
    /// Returns the files written, relative to `directory`.
    @discardableResult
    public static func create(
        name: String, kind: Kind, at directory: URL
    ) throws -> [String] {
        guard WidgetDiscovery.isValidWidgetID(name) else {
            throw ScaffoldError.invalidName(name)
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  (try fm.contentsOfDirectory(atPath: directory.path)).isEmpty
            else {
                throw ScaffoldError.directoryNotEmpty(directory.path)
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let files: [(name: String, contents: String, executable: Bool)]
        switch kind {
        case .exec:
            files = [
                ("widget.json", execManifest(name: name), false),
                ("widget.sh", execScript(name: name), true),
            ]
        case .workflow:
            files = [
                ("widget.json", workflowManifest(name: name), false),
                ("workflow.json", workflowDefinition(name: name), false),
            ]
        case .script:
            files = [
                ("widget.json", scriptManifest(name: name), false),
                ("index.ts", scriptEntry(name: name), false),
            ]
        }

        for file in files {
            let url = directory.appendingPathComponent(file.name)
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
            if file.executable {
                try fm.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: url.path
                )
            }
        }
        return files.map(\.name)
    }

    // MARK: - Templates

    private static func displayName(_ name: String) -> String {
        name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func execManifest(name: String) -> String {
        """
        {
          "$schema": "https://barshelf.jiun.dev/schema/widget-0.1.json",
          "schemaVersion": 1,
          "id": "\(name)",
          "name": "\(displayName(name))",
          "version": "0.1.0",
          "icon": "sparkles",
          "bucket": { "group": "My Widgets", "size": "S" },

          "entry": { "kind": "exec" },
          "source": {
            "kind": "exec",
            "command": ["./widget.sh"],
            "timeoutMs": 5000,
            "output": "viewtree"
          },

          "refresh": { "onOpen": true, "interval": 60, "staleAfterSec": 30 },
          "permissions": {
            "exec": [{ "command": "./widget.sh", "allowedArgs": [[]] }]
          }
        }
        """
    }

    private static func execScript(name: String) -> String {
        """
        #!/bin/bash
        # \(name) — prints a UINode JSON tree to stdout (output=viewtree).
        set -euo pipefail

        NOW="$(date '+%H:%M:%S')"

        cat <<EOF
        {
          "id": "root",
          "type": "vstack",
          "spacing": 8,
          "children": [
            { "id": "title", "type": "text", "text": "\(displayName(name))", "role": "title" },
            { "id": "time", "type": "text", "text": "Rendered at ${NOW}", "role": "body", "monospacedDigit": true },
            { "id": "hint", "type": "text", "text": "Edit widget.sh to change this view", "role": "caption" }
          ]
        }
        EOF
        """
    }

    private static func workflowManifest(name: String) -> String {
        """
        {
          "$schema": "https://barshelf.jiun.dev/schema/widget-0.1.json",
          "schemaVersion": 1,
          "id": "\(name)",
          "name": "\(displayName(name))",
          "version": "0.1.0",
          "icon": "folder",
          "bucket": { "group": "My Widgets", "size": "M" },

          "entry": { "kind": "workflow", "main": "workflow.json" },

          "refresh": { "onOpen": true, "staleAfterSec": 600 },

          "permissions": {
            "readPaths": ["~/Downloads"]
          },

          "settings": [
            { "key": "folder", "title": "Folder", "type": "directory", "default": "~/Downloads" },
            { "key": "limit", "title": "Maximum files", "type": "integer", "default": 8, "min": 1, "max": 48 }
          ]
        }
        """
    }

    private static func workflowDefinition(name: String) -> String {
        """
        {
          "schemaVersion": 1,
          "kind": "workflow",

          "sources": {
            "files": {
              "use": "fs.directory",
              "with": {
                "path": "${settings.folder}",
                "watch": true,
                "skipHidden": true,
                "sortBy": "modifiedAt",
                "sortDirection": "descending",
                "limit": "${settings.limit}"
              }
            }
          },

          "transforms": {
            "visible": { "use": "assign", "from": "$.sources.files.items" }
          },

          "view": {
            "type": "vstack",
            "spacing": 2,
            "children": [
              {
                "type": "hstack",
                "spacing": 8,
                "padding": 10,
                "children": [
                  { "type": "text", "text": "\(displayName(name))", "role": "title", "lineLimit": 1 },
                  { "type": "spacer" },
                  { "type": "text", "text": "${count(transforms.visible)} items", "role": "caption" }
                ]
              },
              { "type": "divider" },
              {
                "type": "list",
                "spacing": 2,
                "items": {
                  "forEach": "$.transforms.visible",
                  "as": "file",
                  "template": {
                    "type": "hstack",
                    "id": "file-${file.path}",
                    "spacing": 8,
                    "padding": 6,
                    "action": { "type": "openFile", "path": "${file.path}" },
                    "children": [
                      { "type": "text", "text": "${file.name}", "role": "body", "lineLimit": 1 },
                      { "type": "spacer" },
                      { "type": "text", "text": "${date.relative(file.modifiedAt)}", "role": "caption" }
                    ]
                  }
                }
              }
            ]
          },

          "empty": {
            "type": "empty",
            "icon": "tray",
            "title": "No files",
            "subtitle": "Choose another folder in widget settings."
          }
        }
        """
    }

    private static func scriptManifest(name: String) -> String {
        """
        {
          "$schema": "https://barshelf.jiun.dev/schema/widget-0.1.json",
          "schemaVersion": 1,
          "id": "\(name)",
          "name": "\(displayName(name))",
          "version": "0.1.0",
          "icon": "clock",
          "bucket": { "group": "My Widgets", "size": "S" },

          "entry": { "kind": "script", "runtime": "deno-ts@1" },
          "source": { "kind": "script", "output": "viewtree" },

          "refresh": { "onOpen": true, "staleAfterSec": 60 },

          "permissions": {
            "storage": true
          }
        }
        """
    }

    private static func scriptEntry(name: String) -> String {
        """
        import { barshelf, ui, type WidgetLoadContext, type WidgetTimerContext } from "barshelf";

        const TIMER_ID = "tick";

        async function render(nowMs: number): Promise<void> {
          const now = new Date(nowMs);
          await barshelf.render(
            ui.vstack([
              ui.text("\(displayName(name))", { id: "title", role: "title" }),
              ui.text(now.toLocaleTimeString(), {
                id: "time",
                role: "body",
                monospacedDigit: true,
              }),
              ui.text("Edit index.ts to change this view", {
                id: "hint",
                role: "caption",
              }),
            ], { id: "root", spacing: 8 }),
            { cacheTtlMs: 60_000 },
          );
        }

        async function load(ctx: WidgetLoadContext): Promise<void> {
          await barshelf.timer.every(TIMER_ID, 60_000);
          await render(ctx.now);
        }

        async function timer(ctx: WidgetTimerContext): Promise<void> {
          if (ctx.id === TIMER_ID) {
            await render(ctx.now);
          }
        }

        export default barshelf.widget({ load, timer });
        """
    }
}
