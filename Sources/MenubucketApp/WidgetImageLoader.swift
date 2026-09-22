import AppKit
import Combine

/// View-owned state for asynchronous images. All entry points run on the main
/// queue, matching the image services' completion contract. A SwiftUI view is
/// a value: comparing a captured URL to itself cannot reject an old callback.
final class WidgetImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    private var identity: String?
    private var generation: UInt = 0
    private var isLoading = false

    func image(for identity: String) -> NSImage? {
        self.identity == identity ? image : nil
    }

    func load(
        identity: String,
        request: (@escaping (NSImage?) -> Void) -> NSImage?
    ) {
        if self.identity == identity, isLoading || image != nil { return }
        generation &+= 1
        let expectedGeneration = generation
        self.identity = identity
        image = nil
        isLoading = true
        let completion: (NSImage?) -> Void = { [weak self] image in
            guard let self, self.generation == expectedGeneration else { return }
            self.isLoading = false
            self.image = image
        }
        if let cached = request(completion) { completion(cached) }
    }

    /// Invalidates callbacks when a view becomes hidden or loses permission.
    /// Shared service requests can still finish and populate their own cache.
    func reset() {
        generation &+= 1
        identity = nil
        isLoading = false
        image = nil
    }
}
