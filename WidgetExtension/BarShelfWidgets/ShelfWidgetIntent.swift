import AppIntents
import Foundation
import MenubucketCore
import WidgetKit

/// A BarShelf widget the user can put on the desktop, from the list the app
/// writes into the shared container.
struct ShelfWidgetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "BarShelf Widget"
    static let defaultQuery = ShelfWidgetQuery()

    var id: String
    var name: String
    var page: String?

    var displayRepresentation: DisplayRepresentation {
        if let page {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(page)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    init(_ entry: SharedShelf.Entry) {
        id = entry.id
        name = entry.name
        page = entry.page
    }
}

struct ShelfWidgetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ShelfWidgetEntity] {
        let entries = SharedContainer.index()?.entries ?? []
        return identifiers.compactMap { id in entries.first { $0.id == id }.map(ShelfWidgetEntity.init) }
    }

    func suggestedEntities() async throws -> [ShelfWidgetEntity] {
        (SharedContainer.index()?.entries ?? []).map(ShelfWidgetEntity.init)
    }

    func defaultResult() async -> ShelfWidgetEntity? {
        SharedContainer.index()?.entries.first.map(ShelfWidgetEntity.init)
    }
}

struct SelectShelfWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a Widget"
    static let description = IntentDescription("Show one of your BarShelf widgets.")

    @Parameter(title: "Widget")
    var widget: ShelfWidgetEntity?

    init() {}
}

/// The App Group container the BarShelf app writes into.
enum SharedContainer {
    static var url: URL? {
        // The preview tool is not sandboxed and has no App Group; it points
        // here explicitly.
        if let override = ProcessInfo.processInfo.environment["BARSHELF_SHARED_CONTAINER"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedShelf.appGroupID)
    }

    static func index() -> SharedShelf.Index? {
        url.flatMap(SharedShelf.readIndex(from:))
    }

    static func snapshot(for widgetID: String) -> SharedShelf.Snapshot? {
        url.flatMap { SharedShelf.readSnapshot(widgetID: widgetID, from: $0) }
    }
}
