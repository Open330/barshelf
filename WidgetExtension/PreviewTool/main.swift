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

let sizes: [(String, NSSize)] = [("small", NSSize(width: 170, height: 170)), ("medium", NSSize(width: 364, height: 170)), ("large", NSSize(width: 364, height: 382))]
var entries: [ShelfEntry] = (SharedContainer.index()?.entries ?? []).map {
    ShelfEntry(date: Date(), widgetID: $0.id, snapshot: SharedContainer.snapshot(for: $0.id))
}
entries.append(ShelfEntry(date: Date(), widgetID: nil, snapshot: nil))
entries.append(ShelfEntry(date: Date(), widgetID: "sample", snapshot: ShelfProvider.sample))

for entry in entries {
    for (name, size) in sizes {
        let view = ShelfWidgetView(entry: entry)
            .padding(14)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(nsColor: .windowBackgroundColor)))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let file = output.appendingPathComponent("\(entry.widgetID ?? "empty")-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }
}
