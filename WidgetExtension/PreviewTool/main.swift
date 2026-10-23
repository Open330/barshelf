import AppKit
import MenubucketCore
import SwiftUI
import WidgetKit

// Renders the desktop widget, as the extension draws it, for every widget in
// the shared container — so the widget can be checked without placing it.
//
//   BARSHELF_SHARED_CONTAINER=~/Library/Group\ Containers/728FW73BS8.com.barshelf.shared \
//     BarShelfWidgetsPreview <out-dir>

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "./widget-previews")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
_ = NSApplication.shared

let sizes: [(String, NSSize, WidgetFamily)] = [
    ("small", NSSize(width: 170, height: 170), .systemSmall),
    ("medium", NSSize(width: 364, height: 170), .systemMedium),
    ("large", NSSize(width: 364, height: 382), .systemLarge),
    ("xlarge", NSSize(width: 760, height: 382), .systemExtraLarge),
]
var entries: [ShelfEntry] = (SharedContainer.index()?.entries ?? []).map {
    ShelfEntry(date: Date(), widgetID: $0.id, snapshot: SharedContainer.snapshot(for: $0.id))
}
if let style = ProcessInfo.processInfo.environment["PREVIEW_STYLE"].flatMap(ShelfWidgetStyle.init(rawValue:)) {
    entries = entries.map { ShelfEntry(date: $0.date, widgetID: $0.widgetID, snapshot: $0.snapshot, partKeys: $0.partKeys, style: style) }
}
entries.append(ShelfEntry(date: Date(), widgetID: nil, snapshot: nil))
entries.append(ShelfEntry(date: Date(), widgetID: "sample", snapshot: ShelfProvider.sample))
// The states that explain themselves (PREVIEW_STATES=1): picked items that
// are gone, a failed refresh with and without a last reading, and a refresh
// BarShelf never answered. Written as state-<name>-<size>.png.
if ProcessInfo.processInfo.environment["PREVIEW_STATES"] == "1" {
    var failed = ShelfProvider.sample
    failed.error = "'gh' not found (searched: /opt/homebrew/bin, /usr/local/bin)"
    var failedEmpty = SharedShelf.Snapshot(widgetID: "state-error-empty", name: "Developer Inbox", icon: "tray")
    failedEmpty.error = failed.error
    let asked = Date().addingTimeInterval(-120)
    entries += [
        ShelfEntry(date: Date(), widgetID: "state-missing", snapshot: ShelfProvider.sample, partKeys: ["/Codex"]),
        ShelfEntry(date: Date(), widgetID: "state-error", snapshot: failed),
        ShelfEntry(date: Date(), widgetID: "state-error-empty", snapshot: failedEmpty),
        ShelfEntry(date: Date(), widgetID: "state-unanswered", snapshot: ShelfProvider.sample, refresh: .unanswered(since: asked)),
        ShelfEntry(date: Date(), widgetID: "state-unanswered-empty", snapshot: nil, refresh: .unanswered(since: asked)),
        ShelfEntry(date: Date(), widgetID: "state-gone", snapshot: nil, offered: false),
    ]
}
// A pick: the given part keys of the given widget (PREVIEW_PICK=<id>|<key>|<key>…).
if let pick = ProcessInfo.processInfo.environment["PREVIEW_PICK"]?.components(separatedBy: "|"), pick.count > 1 {
    entries.append(ShelfEntry(date: Date(), widgetID: pick[0], snapshot: SharedContainer.snapshot(for: pick[0]), partKeys: Array(pick.dropFirst())))
}

for entry in entries {
    for (name, size, family) in sizes {
        let view = ShelfWidgetView(entry: entry, familyOverride: family)
            .environment(\.colorScheme, ProcessInfo.processInfo.environment["PREVIEW_DARK"] == "1" ? .dark : .light)
            .padding(14)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 22).fill(ProcessInfo.processInfo.environment["PREVIEW_DARK"] == "1" ? Color(white: 0.12) : Color(white: 0.97)))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let file = output.appendingPathComponent("\(entry.widgetID ?? "empty")\(entry.partKeys.isEmpty ? "" : "-picked")-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }
}
