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

    /// Nothing by default: a widget placed without a choice says how to make
    /// one, instead of quietly showing whichever widget is first.
    func defaultResult() async -> ShelfWidgetEntity? { nil }
}

/// One piece of a chosen widget — an account card, a sensor row, a file —
/// that the desktop widget can show on its own (`SharedShelf.Part`).
struct ShelfPartEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
    static let defaultQuery = ShelfPartQuery()

    /// `<widget id>\n<part key>`: self-contained, so a saved choice can be
    /// resolved without knowing which widget it was made for.
    var id: String
    var title: String
    var group: String?

    var widgetID: String { String(id.split(separator: "\n", maxSplits: 1).first ?? "") }
    var key: String { String(id.split(separator: "\n", maxSplits: 1).dropFirst().first ?? "") }

    var displayRepresentation: DisplayRepresentation {
        if let group {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(group)")
        }
        return DisplayRepresentation(title: "\(title)")
    }

    init(widgetID: String, part: SharedShelf.Part) {
        id = widgetID + "\n" + part.key
        title = part.title
        group = part.group
    }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

struct ShelfPartQuery: EntityQuery {
    /// The widget chosen above, so the list shows that widget's pieces.
    @IntentParameterDependency<SelectShelfWidgetIntent>(\.$widget)
    var configuration

    func entities(for identifiers: [String]) async throws -> [ShelfPartEntity] {
        identifiers.map { id in
            let entity = ShelfPartEntity(id: id, title: "")
            let part = SharedContainer.snapshot(for: entity.widgetID)?.parts.first { $0.key == entity.key }
            if let part { return ShelfPartEntity(widgetID: entity.widgetID, part: part) }
            // Gone since it was chosen; keep the choice, named by its key.
            return ShelfPartEntity(id: id, title: entity.key.components(separatedBy: "/").last ?? entity.key)
        }
    }

    func suggestedEntities() async throws -> [ShelfPartEntity] {
        guard let widget = configuration?.widget,
              let snapshot = SharedContainer.snapshot(for: widget.id)
        else { return [] }
        return snapshot.parts.map { ShelfPartEntity(widgetID: widget.id, part: $0) }
    }
}

/// How the desktop widget lays out what it shows.
enum ShelfWidgetStyle: String, AppEnum {
    case automatic, bigValue, meters, list, grid

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [ShelfWidgetStyle: DisplayRepresentation] = [
        .automatic: "Automatic",
        .bigValue: "Big Number",
        .meters: "Meters",
        .list: "List",
        .grid: "Grid",
    ]

    /// The template it stands for; nil lets the data decide.
    var template: SharedShelf.Template? {
        switch self {
        case .automatic: return nil
        case .bigValue: return .bigValue
        case .meters: return .meters
        case .list: return .list
        case .grid: return .grid
        }
    }
}

struct SelectShelfWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a Widget"
    static let description = IntentDescription("Show one of your BarShelf widgets, or just the items you pick from it.")

    @Parameter(title: "Widget")
    var widget: ShelfWidgetEntity?

    /// Empty shows the widget's own summary: its headline in the small size,
    /// its first items in the larger ones.
    @Parameter(title: "Show")
    var parts: [ShelfPartEntity]?

    @Parameter(title: "Style", default: .automatic)
    var style: ShelfWidgetStyle

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
        guard var snapshot = url.flatMap({ SharedShelf.readSnapshot(widgetID: widgetID, from: $0) }) else { return nil }
        // Written by a BarShelf from before items existed: split it here.
        if snapshot.parts.isEmpty, let tree = snapshot.viewTree {
            snapshot.parts = SharedShelf.parts(of: tree)
        }
        return snapshot
    }
}
