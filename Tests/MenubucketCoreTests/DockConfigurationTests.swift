import XCTest
@testable import MenubucketCore

final class DockConfigurationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDefaultsAreOffWithOneProfile() {
        let config = DockConfiguration()
        XCTAssertEqual(config.mode, .off)
        XCTAssertEqual(config.profiles.count, 1)
        XCTAssertEqual(config.activeProfileID, DockProfile.defaultID)
        XCTAssertFalse(config.appleDockLayouts)
        XCTAssertNil(config.appleDockBackup)
    }

    func testRoundTripKeepsEveryItemKind() throws {
        let items: [DockItem] = [
            DockItem(kind: .app(path: "/Applications/Safari.app")),
            DockItem(kind: .folder(path: "/Users/me/Downloads", color: .orange, label: "D")),
            DockItem(kind: .file(path: "/Users/me/notes.txt")),
            DockItem(kind: .link(url: "https://example.com", title: "Example")),
            DockItem(kind: .shortcut(name: "Start Day")),
            DockItem(kind: .widget(id: "battery")),
            DockItem(kind: .spacer),
            DockItem(kind: .separator),
        ]
        let layout = AppleDockLayout(
            appTiles: [AppleDockTiles.appTile(path: "/Applications/Safari.app")],
            otherTiles: [],
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let config = DockConfiguration(
            mode: .replace, style: .shelf, edge: .left, tileSize: 64,
            profiles: [DockProfile(id: "work", name: "Work", items: items, appleDock: layout, popupPage: "Dev")],
            activeProfileID: "work", profileHotkeysEnabled: true, appleDockLayouts: true,
            appleDockBackup: AppleDockVisibility(autohide: false, autohideDelay: nil)
        )
        let file = tempDir.appendingPathComponent("dock.json")
        try config.save(to: file)
        let loaded = DockConfiguration.load(from: file)
        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.activeProfile.appleDock?.appNames, ["Safari"])
    }

    func testUnknownItemTypesAreDroppedNotFatal() throws {
        let json = """
        {"mode":"alongside","activeProfileID":"p","profiles":[{"id":"p","name":"P","items":[
          {"id":"a","type":"app","path":"/Applications/Mail.app"},
          {"id":"x","type":"hologram","path":"/nope"},
          "garbage",
          {"id":"s","type":"separator"}
        ]}]}
        """
        let config = try JSONDecoder().decode(DockConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.mode, .alongside)
        XCTAssertEqual(config.activeProfile.items.map(\.id), ["a", "s"])
    }

    func testAppleDockStyleSettingsRoundTripAndClamp() throws {
        var config = DockConfiguration()
        config.magnificationAmount = 7
        config.autoHideDelay = -1
        config.showIndicators = false
        config.animateOpening = false
        config.display = .pointer
        config.folderView = .list
        config.showRecentApps = true
        config.normalize()
        XCTAssertEqual(config.magnificationAmount, DockConfiguration.magnificationAmountRange.upperBound)
        XCTAssertEqual(config.autoHideDelay, 0)
        let file = tempDir.appendingPathComponent("dock.json")
        try config.save(to: file)
        XCTAssertEqual(DockConfiguration.load(from: file), config)

        // Files from before these settings get the Apple Dock's defaults.
        let old = try JSONDecoder().decode(DockConfiguration.self, from: Data(#"{"mode":"alongside"}"#.utf8))
        XCTAssertTrue(old.showIndicators)
        XCTAssertTrue(old.animateOpening)
        XCTAssertEqual(old.display, .main)
        XCTAssertEqual(old.folderView, .grid)
        XCTAssertFalse(old.showRecentApps)
        XCTAssertEqual(old.magnificationAmount, DockConfiguration.defaultMagnificationAmount)
    }

    func testUnknownModeFallsBackAndSizesClamp() throws {
        let json = #"{"mode":"teleport","tileSize":4000,"widgetSize":-3}"#
        let config = try JSONDecoder().decode(DockConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.mode, .off)
        XCTAssertEqual(config.tileSize, DockConfiguration.tileSizeRange.upperBound)
        XCTAssertEqual(config.widgetSize, DockConfiguration.widgetSizeRange.lowerBound)
    }

    func testNormalizeFixesDuplicateIDsAndMissingActiveProfile() {
        let config = DockConfiguration(
            profiles: [
                DockProfile(id: "a", name: "One", items: [DockItem(id: "i", kind: .spacer), DockItem(id: "i", kind: .separator)]),
                DockProfile(id: "a", name: "Two"),
            ],
            activeProfileID: "missing"
        )
        XCTAssertEqual(Set(config.profiles.map(\.id)).count, 2)
        XCTAssertEqual(Set(config.profiles[0].items.map(\.id)).count, 2)
        XCTAssertEqual(config.activeProfileID, "a")
    }

    func testProfileMatchingByIDNameOrPosition() {
        let config = DockConfiguration(profiles: [
            DockProfile(id: "w", name: "Work"),
            DockProfile(id: "p", name: "Personal"),
        ])
        XCTAssertEqual(config.profile(matching: "p")?.name, "Personal")
        XCTAssertEqual(config.profile(matching: "work")?.id, "w")
        XCTAssertEqual(config.profile(matching: "2")?.id, "p")
        XCTAssertNil(config.profile(matching: "3"))
        XCTAssertNil(config.profile(matching: "  "))
    }

    func testProfileOffsetWraps() {
        var config = DockConfiguration(profiles: [
            DockProfile(id: "a", name: "A"), DockProfile(id: "b", name: "B"), DockProfile(id: "c", name: "C"),
        ])
        XCTAssertEqual(config.profile(offsetFromActive: -1).id, "c")
        config.activeProfileID = "c"
        XCTAssertEqual(config.profile(offsetFromActive: 1).id, "a")
    }

    func testItemForFile() {
        XCTAssertEqual(
            DockItem.forFile(at: URL(fileURLWithPath: "/Applications/Notes.app"), isDirectory: true).kind,
            .app(path: "/Applications/Notes.app")
        )
        XCTAssertEqual(
            DockItem.forFile(at: URL(fileURLWithPath: "/tmp/dir"), isDirectory: true).kind,
            .folder(path: "/tmp/dir", color: nil, label: nil)
        )
        XCTAssertEqual(
            DockItem.forFile(at: URL(fileURLWithPath: "/tmp/a.txt"), isDirectory: false).kind,
            .file(path: "/tmp/a.txt")
        )
    }
}

final class AppleDockTests: XCTestCase {
    private final class FakeDefaults: AppleDockDefaults {
        var values: [String: Any] = [:]
        func value(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func synchronize() {}
    }

    private func tile(_ path: String, guid: Int) -> [String: Any] {
        var tile = AppleDockTiles.appTile(path: path)
        tile["GUID"] = guid
        var data = tile["tile-data"] as! [String: Any]
        data["file-label"] = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        tile["tile-data"] = data
        return tile
    }

    func testCaptureAndApplyRestartsOnlyWhenDifferent() {
        let defaults = FakeDefaults()
        var restarts = 0
        let dock = AppleDock(defaults: defaults) { restarts += 1 }
        defaults.values[AppleDock.appsKey] = [tile("/Applications/Mail.app", guid: 1)]
        let work = dock.currentLayout()
        XCTAssertEqual(work.appNames, ["Mail"])

        // Same items with fresh bookkeeping: nothing to do.
        defaults.values[AppleDock.appsKey] = [tile("/Applications/Mail.app", guid: 99)]
        XCTAssertFalse(dock.apply(work))
        XCTAssertEqual(restarts, 0)

        defaults.values[AppleDock.appsKey] = [tile("/Applications/Music.app", guid: 2)]
        XCTAssertTrue(dock.apply(work))
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(AppleDockTiles.labels(of: defaults.values[AppleDock.appsKey] as! [Any]), ["Mail"])
    }

    func testApplyKeepsBoundedBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dock-backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = FakeDefaults()
        let dock = AppleDock(defaults: defaults, backupDirectory: dir) {}
        for index in 0..<(AppleDock.backupLimit + 3) {
            let layout = AppleDockLayout(
                appTiles: [tile("/Applications/App\(index).app", guid: index)], otherTiles: [],
                capturedAt: Date(timeIntervalSince1970: Double(index))
            )
            dock.apply(layout)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, AppleDock.backupLimit)
    }

    func testHideAndRestorePutBackWhatWasThere() {
        let defaults = FakeDefaults()
        var restarts = 0
        let dock = AppleDock(defaults: defaults) { restarts += 1 }
        XCTAssertFalse(dock.isHidden)
        let backup = dock.hide()
        XCTAssertEqual(backup, AppleDockVisibility(autohide: nil, autohideDelay: nil))
        XCTAssertTrue(dock.isHidden)
        XCTAssertNil(dock.hide(), "hiding twice must not overwrite the real backup")
        dock.restore(backup!)
        XCTAssertNil(defaults.values[AppleDock.autohideKey])
        XCTAssertNil(defaults.values[AppleDock.autohideDelayKey])
        XCTAssertFalse(dock.isHidden)
        XCTAssertEqual(restarts, 2)
    }

    func testUnhideWithoutBackupKeepsAutohide() {
        let defaults = FakeDefaults()
        defaults.values[AppleDock.autohideKey] = true
        defaults.values[AppleDock.autohideDelayKey] = 1000.0
        let dock = AppleDock(defaults: defaults) {}
        dock.unhideWithoutBackup()
        XCTAssertEqual(defaults.values[AppleDock.autohideKey] as? Bool, true)
        XCTAssertNil(defaults.values[AppleDock.autohideDelayKey])
    }

    /// An empty layout is an unreadable save; writing it would unpin
    /// every app in the Dock.
    func testAnEmptyLayoutIsNeverWritten() {
        let defaults = FakeDefaults()
        defaults.values[AppleDock.appsKey] = [tile("/Applications/Mail.app", guid: 1)]
        var restarts = 0
        let dock = AppleDock(defaults: defaults) { restarts += 1 }
        XCTAssertFalse(dock.apply(AppleDockLayout(appTiles: [], otherTiles: [])))
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual((defaults.values[AppleDock.appsKey] as? [Any])?.count, 1)
        XCTAssertTrue(AppleDockLayout(appTiles: [], otherTiles: []).isEmpty)
    }

    func testLabelsSkipSpacers() {
        let tiles: [Any] = [
            tile("/Applications/Mail.app", guid: 1),
            ["tile-type": "small-spacer-tile", "tile-data": [String: Any]()],
            AppleDockTiles.folderTile(path: "/Users/me/Downloads"),
        ]
        XCTAssertEqual(AppleDockTiles.labels(of: tiles), ["Mail", "Downloads"])
        XCTAssertTrue(AppleDockTiles.isSpacer(tiles[1]))
        XCTAssertEqual(AppleDockTiles.fileURL(of: tiles[2])?.path, "/Users/me/Downloads")
    }
}
