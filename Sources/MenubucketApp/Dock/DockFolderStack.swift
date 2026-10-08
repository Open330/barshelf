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
    @State private var entries: [Entry] = []

    /// Enough to find a recent download; the rest is a click away in Finder.
    static let limit = 60

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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 10) {
                        ForEach(entries) { entry in cell(entry) }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 452)
        .onAppear { load() }
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
                    .frame(width: 80)
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
