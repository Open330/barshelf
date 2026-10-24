import XCTest
@testable import MenubucketApp
import MenubucketCore

@MainActor
final class GalleryEntryTextTests: XCTestCase {
    private let weatherURL = "https://github.com/Open330/barshelf/tree/main/widgets/weather"

    func testKoreanWordsFindTheProjectsWidgets() {
        let model = GalleryModel(
            widgetsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("barshelf-gallery-ko-\(UUID().uuidString)")
        )
        let weather = entry(id: "dev.barshelf.weather", name: "Weather", url: weatherURL, category: "Demo")
        let battery = entry(
            id: "dev.barshelf.battery-meter", name: "Battery",
            url: "https://github.com/Open330/barshelf/tree/main/widgets/battery-meter", category: "System"
        )
        model.setEntries(forPreview: [weather, battery])

        model.searchText = "날씨"
        XCTAssertEqual(model.filteredEntries.map(\.id), [weather.id])
        model.searchText = "배터리"
        XCTAssertEqual(model.filteredEntries.map(\.id), [battery.id])
        // Every word has to match, in any field.
        model.searchText = "battery 충전"
        XCTAssertEqual(model.filteredEntries.map(\.id), [battery.id])
        model.searchText = "battery 날씨"
        XCTAssertTrue(model.filteredEntries.isEmpty)
        // Case and accents don't matter.
        model.searchText = "WEATHER"
        XCTAssertEqual(model.filteredEntries.map(\.id), [weather.id])
        // "widget" is true of every entry, so it never stops a match — and
        // never makes one on its own word's behalf.
        model.searchText = "날씨 위젯"
        XCTAssertEqual(model.filteredEntries.map(\.id), [weather.id])
        model.searchText = "weather widget"
        XCTAssertEqual(model.filteredEntries.map(\.id), [weather.id])
        model.searchText = "배터리 위젯"
        XCTAssertEqual(model.filteredEntries.map(\.id), [battery.id])
        model.searchText = "위젯 날씨 배터리"
        XCTAssertTrue(model.filteredEntries.isEmpty)
        model.searchText = "위젯"
        XCTAssertEqual(Set(model.filteredEntries.map(\.id)), [weather.id, battery.id])
    }

    func testTheShelfsKoreanNameFindsTheEntry() {
        let model = GalleryModel(
            widgetsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("barshelf-gallery-ko-\(UUID().uuidString)")
        )
        let exchange = entry(
            id: "dev.barshelf.exchange", name: "Exchange",
            url: "https://github.com/Open330/barshelf/tree/main/widgets/exchange", category: "Demo"
        )
        model.setEntries(forPreview: [exchange])
        model.searchText = "환율 위젯"
        XCTAssertEqual(model.filteredEntries.map(\.id), [exchange.id])
    }

    func testAThirdPartyEntryReusingAnIDKeepsItsOwnWords() {
        var impostor = entry(id: "dev.barshelf.weather", name: "Surf Report", url: "https://example.invalid/surf", category: "Demo")
        impostor.description = "Wave heights."
        XCTAssertFalse(GalleryEntryText.isOfficial(impostor))
        XCTAssertEqual(GalleryEntryText.description(for: impostor), "Wave heights.")
        XCTAssertFalse(GalleryEntryText.searchTerms(for: impostor).contains("날씨"))
        XCTAssertEqual(GalleryEntryText.title(for: impostor, language: "ko"), "Surf Report")

        var official = entry(id: "dev.barshelf.weather", name: "Weather", url: weatherURL, category: "Demo")
        official.description = "Native weather widget over a free HTTPS API."
        XCTAssertTrue(GalleryEntryText.isOfficial(official))
        XCTAssertNotEqual(GalleryEntryText.description(for: official), official.description)
    }

    func testCategoryLabelsAndUnknownCategories() {
        XCTAssertNotEqual(GalleryEntryText.categoryLabel("Demo"), "Demo")
        XCTAssertEqual(GalleryEntryText.categoryLabel("Surfing"), "Surfing")
    }

    /// Keeps the app's words in step with the registry it ships: an entry
    /// whose id or install URL changed would silently fall back to English.
    func testEveryShippedRegistryEntryHasAppWords() throws {
        let index = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("registry/index.json")
        let registry = try RegistryIndex.parse(Data(contentsOf: index)).index
        XCTAssertFalse(registry.widgets.isEmpty)
        for widget in registry.widgets {
            XCTAssertTrue(GalleryEntryText.isOfficial(widget), "\(widget.id) has no app-side gallery words")
            XCTAssertTrue(
                GalleryEntryText.searchTerms(for: widget).contains { $0.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } },
                "\(widget.id) has no Korean search keyword"
            )
        }
    }

    /// The gallery calls a project widget what its installed card will: the
    /// name its widget.json translates for the shelf.
    func testOfficialTitlesMatchTheShelfsNames() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let registry = try RegistryIndex.parse(Data(contentsOf: root.appendingPathComponent("registry/index.json"))).index
        var checked = 0
        for widget in registry.widgets {
            guard let bundled = widget.install.bundled else {
                // Installed from another repository, whose manifest decides.
                XCTAssertEqual(GalleryEntryText.title(for: widget, language: "ko"), widget.name, widget.id)
                continue
            }
            let manifest = try Manifest.decode(
                from: Data(contentsOf: root.appendingPathComponent("widgets/\(bundled)/widget.json"))
            )
            XCTAssertEqual(widget.name, manifest.name, "\(widget.id): registry and widget.json disagree")
            XCTAssertEqual(GalleryEntryText.title(for: widget, language: "ko"), manifest.localizedName(for: "ko"), widget.id)
            XCTAssertEqual(GalleryEntryText.title(for: widget, language: "ko-KR"), manifest.localizedName(for: "ko"), widget.id)
            XCTAssertEqual(GalleryEntryText.title(for: widget, language: "en"), widget.name, widget.id)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
    }

    private func entry(id: String, name: String, url: String, category: String) -> RegistryWidgetEntry {
        var entry = RegistryWidgetEntry(id: id, name: name, version: "1.0", install: .init(url: url))
        entry.category = category
        return entry
    }
}
