import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A folder opened from the dock as a grid of its contents, the way the Apple
/// Dock shows a stack: newest first by date added, subfolders open in place
/// with a way back, and files can be dragged out.
struct DockFolderStack: View {
    let root: URL
    let onClose: () -> Void

    @State private var trail: [URL] = []
    @State private var entries: [Entry]

    init(root: URL, onClose: @escaping () -> Void) {
        self.root = root
        self.onClose = onClose
        // Read before the popover opens: it is placed for its first size, and
        // contents arriving later made it grow down over the dock.
        _entries = State(initialValue: Self.entries(in: root))
    }

    /// Enough to find a recent download; the rest is a click away in Finder.
    static let limit = 60
    static let columns = 4
    static let cellWidth: CGFloat = 96
    static let rowHeight: CGFloat = 92
    static let rowSpacing: CGFloat = 10

    /// Every row when they fit, else four and a half, so it reads as more.
    static func gridHeight(count: Int) -> CGFloat {
        let rows = max(1, (count + columns - 1) / columns)
        let shown = min(CGFloat(rows), 4.5)
        return shown * rowHeight + (shown.rounded(.up) - 1) * rowSpacing + 24
    }

    struct Entry: Identifiable, Equatable {
        let url: URL
        let name: String
        let opensInPlace: Bool
        var id: URL { url }
    }

    private var folder: URL { trail.last ?? root }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                Text("Empty Folder")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellWidth), spacing: 8), count: Self.columns),
                              spacing: Self.rowSpacing) {
                        ForEach(entries) { entry in cell(entry) }
                    }
                    .padding(12)
                }
                // A scroll view has no height of its own, and the popover
                // took the smallest it could: one row. Rows decide it, up to
                // a screenful.
                .frame(height: Self.gridHeight(count: entries.count))
            }
        }
        .frame(width: CGFloat(Self.columns) * Self.cellWidth + CGFloat(Self.columns - 1) * 8 + 24)
        .onChange(of: trail) { _, _ in load() }
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            if !trail.isEmpty {
                Button {
                    trail.removeLast()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back")
                .accessibilityLabel(Text("Back"))
            }
            Text(FileManager.default.displayName(atPath: folder.path))
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button("Open in Finder") {
                NSWorkspace.shared.open(folder)
                onClose()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func cell(_ entry: Entry) -> some View {
        Button {
            if entry.opensInPlace {
                trail.append(entry.url)
            } else {
                NSWorkspace.shared.open(entry.url)
                onClose()
            }
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: DockActions.fileIcon(at: entry.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                Text(entry.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(width: Self.cellWidth - 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
        .help(entry.name)
        .accessibilityLabel(Text(entry.name))
    }

    private func load() {
        entries = Self.entries(in: folder)
    }

    /// The folder's visible contents, newest first by date added (then
    /// modified), as many as `limit`.
    static func entries(in folder: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        let dated = urls.map { url -> (URL, Date, URLResourceValues?) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast, values)
        }
        return dated
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { url, _, values in
                Entry(
                    url: url,
                    name: FileManager.default.displayName(atPath: url.path),
                    opensInPlace: values?.isDirectory == true && values?.isPackage != true
                )
            }
    }
}
