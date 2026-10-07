import XCTest
@testable import MenubucketApp
@testable import MenubucketCore

/// The BarShelf Dock's store (R15): it is the only thing that hides, shows,
/// and rewrites the Apple Dock, so those transitions are pinned down here
/// against a fake `com.apple.dock`.
final class DockStoreTests: XCTestCase {
    private final class FakeDefaults: AppleDockDefaults {
        var values: [String: Any] = [:]
        func value(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func synchronize() {}
    }

    private var fileURL: URL!
    private var defaults: FakeDefaults!
    private var restarts = 0

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("dock-\(UUID().uuidString).json")
        defaults = FakeDefaults()
        restarts = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func makeStore() -> DockStore {
        DockStore(fileURL: fileURL, appleDock: AppleDock(defaults: defaults) { [weak self] in self?.restarts += 1 })
    }

    func testReplaceHidesTheAppleDockAndOffPutsItBack() {
        defaults.values[AppleDock.autohideKey] = false
        let store = makeStore()
        store.update { $0.mode = .replace }
        XCTAssertTrue(store.appleDock.isHidden)
        XCTAssertEqual(store.configuration.appleDockBackup, AppleDockVisibility(autohide: false, autohideDelay: nil))

        store.update { $0.mode = .off }
        XCTAssertFalse(store.appleDock.isHidden)
        XCTAssertEqual(defaults.values[AppleDock.autohideKey] as? Bool, false)
        XCTAssertNil(defaults.values[AppleDock.autohideDelayKey])
        XCTAssertNil(store.configuration.appleDockBackup)
        XCTAssertEqual(restarts, 2)
    }

    func testOtherEditsDoNotTouchTheAppleDock() {
        let store = makeStore()
        store.update { $0.mode = .alongside }
        store.update { $0.tileSize = 60 }
        XCTAssertEqual(restarts, 0)
        XCTAssertNil(defaults.values[AppleDock.autohideKey])
    }

    /// A crash while hiding leaves a backup in dock.json; the next launch
    /// without `replace` must put the user's Dock back.
    func testLaunchRestoresALeftoverBackup() throws {
        var config = DockConfiguration(mode: .alongside)
        config.appleDockBackup = AppleDockVisibility(autohide: nil, autohideDelay: nil)
        try config.save(to: fileURL)
        defaults.values[AppleDock.autohideKey] = true
        defaults.values[AppleDock.autohideDelayKey] = AppleDock.hiddenDelay

        let store = makeStore()
        store.reconcileAppleDockAtLaunch()
        XCTAssertFalse(store.appleDock.isHidden)
        XCTAssertNil(store.configuration.appleDockBackup)
        XCTAssertNil(DockConfiguration.load(from: fileURL).appleDockBackup, "the restore must be saved")
    }

    func testQuitShowsTheAppleDockAndLaunchHidesItAgain() {
        let store = makeStore()
        store.update { $0.mode = .replace }
        store.restoreAppleDockForTermination()
        XCTAssertFalse(store.appleDock.isHidden)
        XCTAssertEqual(store.configuration.mode, .replace, "quitting is not turning the mode off")

        let relaunched = makeStore()
        relaunched.reconcileAppleDockAtLaunch()
        XCTAssertTrue(relaunched.appleDock.isHidden)
    }

    func testSwitchingAppliesTheSavedAppleDockLayoutOnlyWhenTurnedOn() {
        defaults.values[AppleDock.appsKey] = [AppleDockTiles.appTile(path: "/Applications/Mail.app")]
        let store = makeStore()
        let work = store.addProfile(named: "Work")
        store.captureAppleDock(into: work)
        defaults.values[AppleDock.appsKey] = [AppleDockTiles.appTile(path: "/Applications/Music.app")]

        store.activate(profileID: work)
        XCTAssertEqual(store.configuration.activeProfileID, work)
        XCTAssertEqual(restarts, 0, "Apple Dock layouts are off by default")

        store.update { $0.appleDockLayouts = true }
        store.activate(profileID: work)
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(AppleDockTiles.labels(of: defaults.values[AppleDock.appsKey] as! [Any]), ["Mail"])
    }

    func testActivateByNameNumberAndOffset() {
        let store = makeStore()
        let work = store.addProfile(named: "Work")
        var activated: [String] = []
        store.onProfileActivated = { activated.append($0.name) }
        XCTAssertTrue(store.activate(matching: "work"))
        XCTAssertFalse(store.activate(matching: "nope"))
        XCTAssertEqual(store.configuration.activeProfileID, work)
        store.activate(offset: 1)
        XCTAssertEqual(store.configuration.activeProfileID, DockProfile.defaultID)
        XCTAssertTrue(store.activate(matching: "2"))
        XCTAssertEqual(activated, ["Work", DockProfile.defaultName, "Work"])
    }

    func testItemEditing() {
        let store = makeStore()
        let a = DockItem(kind: .app(path: "/Applications/A.app"))
        let b = DockItem(kind: .app(path: "/Applications/B.app"))
        let c = DockItem(kind: .separator)
        store.addItems([a, b])
        store.addItems([c], before: b.id)
        XCTAssertEqual(store.activeProfile.items.map(\.id), [a.id, c.id, b.id])
        store.moveItem(a.id, before: nil)
        XCTAssertEqual(store.activeProfile.items.map(\.id), [c.id, b.id, a.id])
        store.removeItem(c.id)
        XCTAssertEqual(store.activeProfile.items.map(\.id), [b.id, a.id])
        XCTAssertEqual(DockConfiguration.load(from: fileURL).activeProfile.items.map(\.id), [b.id, a.id])
    }

    func testTheLastProfileCannotBeRemoved() {
        let store = makeStore()
        store.removeProfile(DockProfile.defaultID)
        XCTAssertEqual(store.configuration.profiles.count, 1)
    }

    // MARK: Tiles

    func testTilesAddRunningAppsNotInTheProfileThenTrash() {
        var config = DockConfiguration(mode: .alongside)
        config.profiles[0].items = [DockItem(id: "mail", kind: .app(path: "/Applications/Mail.app"))]
        let running = [
            RunningApps.App(path: "/Applications/Mail.app", bundleID: "com.apple.mail", processID: 1),
            RunningApps.App(path: "/Applications/Notes.app", bundleID: "com.apple.Notes", processID: 2),
        ]
        let ids = DockView.tiles(for: config, running: running).map(\.id)
        XCTAssertEqual(ids, ["mail", "divider:running", "running:/Applications/Notes.app", "divider:trash", "trash"])

        config.showRunningApps = false
        config.showTrash = false
        XCTAssertEqual(DockView.tiles(for: config, running: running).map(\.id), ["mail"])
    }

    // MARK: URL

    func testDockDeepLinkRoutesToHook() {
        let installer = WidgetInstaller()
        var received: [[URLQueryItem]] = []
        installer.onDockRequest = { received.append($0) }
        installer.handleDeepLink(URL(string: "barshelf://dock?profile=Work%20Mode")!)
        installer.handleDeepLink(URL(string: "barshelf://dock?next")!)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].first?.value, "Work Mode")
        XCTAssertEqual(received[1].first?.name, "next")
    }

    /// The copyable link names the profile by id, so renaming it does not
    /// quietly break a Focus automation.
    func testSwitchURLUsesTheStableID() {
        let profile = DockProfile(id: "a&b", name: "Deep Work")
        let url = URL(string: DockSettingsPage.switchURL(for: profile))!
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        XCTAssertEqual(value, "a&b")
    }

    func testDeletingTheActiveProfileSwitchesProperly() {
        defaults.values[AppleDock.appsKey] = [AppleDockTiles.appTile(path: "/Applications/Mail.app")]
        let store = makeStore()
        store.captureAppleDock(into: DockProfile.defaultID)
        let work = store.addProfile(named: "Work")
        store.update { $0.appleDockLayouts = true }
        store.activate(profileID: work)
        defaults.values[AppleDock.appsKey] = [AppleDockTiles.appTile(path: "/Applications/Music.app")]
        var activated: [String] = []
        store.onProfileActivated = { activated.append($0.id) }

        store.removeProfile(work)
        XCTAssertEqual(store.configuration.activeProfileID, DockProfile.defaultID)
        XCTAssertEqual(activated, [DockProfile.defaultID])
        XCTAssertEqual(AppleDockTiles.labels(of: defaults.values[AppleDock.appsKey] as! [Any]), ["Mail"])
    }

    func testAnUnreadableAppleDockIsNotSaved() {
        let store = makeStore()
        XCTAssertFalse(store.captureAppleDock(into: DockProfile.defaultID))
        XCTAssertNil(store.activeProfile.appleDock)
        XCTAssertNotNil(store.lastError)
    }

    func testRestoreRequestedByTheCLILeavesReplaceMode() {
        let store = makeStore()
        store.update { $0.mode = .replace }
        store.restoreAppleDockOnRequest()
        XCTAssertEqual(store.configuration.mode, .alongside)
        XCTAssertFalse(store.appleDock.isHidden)
        XCTAssertNil(DockConfiguration.load(from: fileURL).appleDockBackup)
    }

    func testMenuRouterForgetsAGoneTile() {
        let router = DockMenuRouter()
        router.bar = { [.action("Dock Settings…") {}] }
        router.enter("mail", entries: { [.action("Quit") {}] })
        XCTAssertEqual(router.current?.map(\.title), ["Quit"])
        router.keep(only: ["notes"])
        XCTAssertEqual(router.current?.map(\.title), ["Dock Settings…"])
    }
}

/// Dock menus are defined once and offered as a right-click NSMenu and as
/// named accessibility actions; both must carry the same commands.
final class DockMenuTests: XCTestCase {
    func testTidyDropsStrayDividers() {
        let entries = DockMenuEntry.tidy([
            .divider, .action("A") {}, .divider, .divider, .action("B") {}, .divider,
        ])
        XCTAssertEqual(entries.map(\.title), ["A", "", "B"])
    }

    /// VoiceOver gets every command as a named action, submenus spelled out.
    func testFlattenedActionsSpellOutSubmenus() {
        var ran: [String] = []
        let flat = DockMenuEntry.flattened([
            .action("Open") { ran.append("open") },
            .divider,
            .action("Hidden", enabled: false) {},
            .submenu("Profile", [.action("Work") { ran.append("work") }]),
        ])
        XCTAssertEqual(flat.map(\.title), ["Open", "Profile: Work"])
        flat.forEach { $0.run() }
        XCTAssertEqual(ran, ["open", "work"])
    }

    func testNSMenuMatchesTheEntries() {
        var ran: [String] = []
        let menu = DockMenuPresenter.makeMenu([
            .action("Open") { ran.append("open") },
            .divider,
            .submenu("Profile", [.action("Work", checked: true) { ran.append("work") }]),
            .action("Remove from Dock", destructive: true) { ran.append("remove") },
        ])
        XCTAssertEqual(menu.items.map(\.title), ["Open", "", "Profile", "Remove from Dock"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        guard let work = menu.items[2].submenu?.items.first else { return XCTFail("no submenu") }
        XCTAssertEqual(work.state, .on)
        for item in [menu.items[0], work, menu.items[3]] {
            XCTAssertTrue(NSApplication.shared.sendAction(item.action!, to: item.target, from: item))
        }
        XCTAssertEqual(ran, ["open", "work", "remove"])
    }
}
