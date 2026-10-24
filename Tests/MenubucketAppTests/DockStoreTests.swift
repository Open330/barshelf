import XCTest
@testable import MenubucketApp
@testable import MenubucketCore

/// The BarShelf Dock's store (R15): it is the only thing that hides, shows,
/// and rewrites the Apple Dock, so those transitions are pinned down here
/// against a fake `com.apple.dock`.
final class DockStoreTests: XCTestCase {
    private final class FakeDefaults: AppleDockDefaults {
        var values: [String: Any] = [:]
        var beforeSet: ((String, Any?) -> Void)?
        var synchronizationFailures = 0
        func value(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) {
            beforeSet?(key, value)
            values[key] = value
        }
        func synchronize() {}
        func synchronizeChanges() throws {
            if synchronizationFailures > 0 {
                synchronizationFailures -= 1
                throw AppleDockError.preferenceWriteFailed
            }
        }
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

    func testRecoveryBackupIsOnDiskBeforeFirstPreferenceMutationOrRestart() throws {
        let original = AppleDockVisibility(autohide: false, autohideDelay: 0.75)
        defaults.values[AppleDock.autohideKey] = original.autohide
        defaults.values[AppleDock.autohideDelayKey] = original.autohideDelay
        let file = try XCTUnwrap(fileURL)
        var mutations = 0
        defaults.beforeSet = { _, _ in
            mutations += 1
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(DockConfiguration.load(from: file).appleDockBackup, original)
        }
        let dock = AppleDock(defaults: defaults) {
            XCTAssertEqual(DockConfiguration.load(from: file).appleDockBackup, original)
        }
        var store: DockStore? = DockStore(fileURL: file, appleDock: dock)
        store?.update { $0.mode = .replace }
        XCTAssertNil(store?.lastError)
        XCTAssertEqual(mutations, 2)
        XCTAssertTrue(dock.isHidden)
        defaults.beforeSet = nil
        store = nil // abrupt app exit: no termination restoration

        let recovered = DockStore(fileURL: file, appleDock: dock)
        recovered.reconcileAppleDockAtLaunch()
        XCTAssertEqual(recovered.configuration.appleDockBackup, original)
        recovered.restoreAppleDockOnRequest()
        XCTAssertEqual(dock.visibility, original)
        XCTAssertNil(DockConfiguration.load(from: file).appleDockBackup)
    }

    func testFailedBackupSaveLeavesAppleDockAndModeUnchanged() {
        defaults.values[AppleDock.autohideKey] = false
        defaults.values[AppleDock.autohideDelayKey] = 0.25
        var mutations = 0
        defaults.beforeSet = { _, _ in mutations += 1 }
        let store = DockStore(fileURL: fileURL,
            appleDock: AppleDock(defaults: defaults) { [weak self] in self?.restarts += 1 },
            persistConfiguration: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        store.update { $0.mode = .replace }

        XCTAssertEqual(mutations, 0)
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual(store.configuration.mode, .off)
        XCTAssertNil(store.configuration.appleDockBackup)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.appleDock.visibility, AppleDockVisibility(autohide: false, autohideDelay: 0.25))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFailedHideRollsBackExactlyAndKeepsDurableRecoveryRecord() {
        let original = AppleDockVisibility(autohide: nil, autohideDelay: 0.125)
        defaults.values[AppleDock.autohideDelayKey] = original.autohideDelay
        defaults.synchronizationFailures = 1
        let store = makeStore()
        store.update { $0.mode = .replace }

        XCTAssertEqual(store.configuration.mode, .off)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.appleDock.visibility, original)
        XCTAssertEqual(DockConfiguration.load(from: fileURL).appleDockBackup, original)
        let relaunched = makeStore()
        relaunched.reconcileAppleDockAtLaunch()
        XCTAssertEqual(relaunched.appleDock.visibility, original)
        XCTAssertNil(relaunched.configuration.appleDockBackup)
        XCTAssertNil(DockConfiguration.load(from: fileURL).appleDockBackup)
    }

    func testFailedRollbackRetainsBackupForNextLaunch() {
        let original = AppleDockVisibility(autohide: false, autohideDelay: nil)
        defaults.values[AppleDock.autohideKey] = false
        defaults.synchronizationFailures = 2
        let store = makeStore()
        store.update { $0.mode = .replace }
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.configuration.mode, .off)
        XCTAssertEqual(DockConfiguration.load(from: fileURL).appleDockBackup, original)

        // Model a partial system write surviving both failed synchronizations.
        defaults.values[AppleDock.autohideKey] = true
        defaults.values[AppleDock.autohideDelayKey] = AppleDock.hiddenDelay
        let relaunched = makeStore()
        relaunched.reconcileAppleDockAtLaunch()
        XCTAssertEqual(relaunched.appleDock.visibility, original)
        XCTAssertNil(DockConfiguration.load(from: fileURL).appleDockBackup)
    }

    /// A failed rollback says what happened in the app's own words and offers
    /// the kept copy; Restore Apple Dock (the settings banner's action) then
    /// puts it back and clears the warning, without waiting for a relaunch.
    func testAFailedRollbackOffersRestoreAndRestoreClearsTheWarning() {
        let original = AppleDockVisibility(autohide: false, autohideDelay: nil)
        defaults.values[AppleDock.autohideKey] = false
        defaults.synchronizationFailures = 2
        let store = makeStore()
        store.update { $0.mode = .replace }

        XCTAssertEqual(store.lastError, DockStore.message(for: AppleDockError.rollbackFailed))
        XCTAssertNotEqual(store.lastError, AppleDockError.rollbackFailed.errorDescription, "not Core's English text")
        XCTAssertTrue(store.hasAppleDockBackup, "the banner offers Restore Apple Dock")

        // The half-written hide survived; the action puts the user's settings back.
        defaults.values[AppleDock.autohideKey] = true
        defaults.values[AppleDock.autohideDelayKey] = AppleDock.hiddenDelay
        store.restoreAppleDockOnRequest()
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.hasAppleDockBackup)
        XCTAssertEqual(store.appleDock.visibility, original)
        XCTAssertNil(DockConfiguration.load(from: fileURL).appleDockBackup)
        XCTAssertEqual(store.configuration.mode, .off)
    }

    func testEveryFailureIsWordedByTheApp() {
        let rejected = DockStore.message(for: AppleDockError.preferenceWriteFailed)
        let rollback = DockStore.message(for: AppleDockError.rollbackFailed)
        struct DiskFull: LocalizedError { var errorDescription: String? { "The disk is full." } }
        let save = DockStore.message(for: DiskFull())
        XCTAssertNotEqual(rejected, AppleDockError.preferenceWriteFailed.errorDescription)
        XCTAssertTrue(rollback.contains("Restore Apple Dock"))
        XCTAssertTrue(save.contains("The disk is full."), "keeps the underlying reason")
        XCTAssertEqual(Set([rejected, rollback, save]).count, 3)
    }

    func testFailedRestoreKeepsBackupAndAllowsRetry() {
        let original = AppleDockVisibility(autohide: false, autohideDelay: 0.375)
        defaults.values[AppleDock.autohideKey] = original.autohide
        defaults.values[AppleDock.autohideDelayKey] = original.autohideDelay
        let store = makeStore()
        store.update { $0.mode = .replace }
        defaults.synchronizationFailures = 1
        store.restoreAppleDockOnRequest()
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.configuration.mode, .replace)
        XCTAssertEqual(store.configuration.appleDockBackup, original)
        XCTAssertEqual(DockConfiguration.load(from: fileURL).appleDockBackup, original)

        store.restoreAppleDockOnRequest()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.configuration.mode, .alongside)
        XCTAssertEqual(store.appleDock.visibility, original)
        XCTAssertNil(DockConfiguration.load(from: fileURL).appleDockBackup)
    }

    func testSizeFollowsTheAppleDockUntilChosen() {
        defaults.values["tilesize"] = 29.0
        let store = makeStore()
        store.syncSizeWithAppleDock()
        XCTAssertEqual(store.configuration.tileSize, 29)
        defaults.values["tilesize"] = 48.0
        store.syncSizeWithAppleDock()
        XCTAssertEqual(store.configuration.tileSize, 48)
        store.update { $0.matchAppleDockSize = false; $0.tileSize = 60 }
        defaults.values["tilesize"] = 20.0
        store.syncSizeWithAppleDock()
        XCTAssertEqual(store.configuration.tileSize, 60)
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

    func testRecentAppsSkipWhatIsAlreadyShown() {
        var config = DockConfiguration(mode: .alongside)
        config.profiles[0].items = [DockItem(id: "mail", kind: .app(path: "/Applications/Mail.app"))]
        config.showTrash = false
        config.showRecentApps = true
        let running = [RunningApps.App(path: "/Applications/Notes.app", bundleID: "com.apple.Notes", processID: 1)]
        let recent = ["/Applications/Mail.app", "/Applications/Notes.app", "/Applications/Gone.app",
                      "/Applications/A.app", "/Applications/B.app", "/Applications/C.app", "/Applications/D.app"]
        let ids = DockView.tiles(for: config, running: running, recent: recent, exists: { !$0.contains("Gone") }).map(\.id)
        XCTAssertEqual(ids, [
            "mail", "divider:running", "running:/Applications/Notes.app", "divider:recent",
            "recent:/Applications/A.app", "recent:/Applications/B.app", "recent:/Applications/C.app",
        ])
    }

    func testRecentListIsMostRecentFirstAndKept() throws {
        let suite = "dock-recent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let apps = RunningApps(defaults: defaults)
        apps.noteUsed("/Applications/A.app")
        apps.noteUsed("/Applications/B.app")
        apps.noteUsed("/Applications/A.app")
        // Real app switches may land in between; the order of these holds.
        let a = try XCTUnwrap(apps.recent.firstIndex(of: "/Applications/A.app"))
        let b = try XCTUnwrap(apps.recent.firstIndex(of: "/Applications/B.app"))
        XCTAssertLessThan(a, b)
        XCTAssertEqual(apps.recent.filter { $0 == "/Applications/A.app" }.count, 1)
        XCTAssertEqual(RunningApps(defaults: defaults).recent, apps.recent)
        apps.noteUsed("/tmp/scratch/fstest")
        XCTAssertFalse(apps.recent.contains("/tmp/scratch/fstest"), "bare executables are not apps")
    }

    func testFolderStackIsNewestFirstAndOpensFoldersInPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("old.txt")
        let new = dir.appendingPathComponent("new.txt")
        try Data().write(to: old)
        try Data().write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        let entries = DockFolderStack.entries(in: dir)
        XCTAssertEqual(Set(entries.map(\.name)), ["old.txt", "new.txt", "Sub"])
        XCTAssertTrue(entries.first { $0.name == "Sub" }!.opensInPlace)
        XCTAssertFalse(entries.first { $0.name == "new.txt" }!.opensInPlace)
    }

    // MARK: Full screen

    func testFullScreenMeansAWindowCoveringTheWholeScreen() {
        let main = DockPanelController.windowServerFrame(of: NSRect(x: 0, y: 0, width: 2560, height: 1440), primaryHeight: 1440)
        let below = DockPanelController.windowServerFrame(of: NSRect(x: 0, y: -1440, width: 2560, height: 1440), primaryHeight: 1440)
        XCTAssertEqual(below, CGRect(x: 0, y: 1440, width: 2560, height: 1440))
        func window(_ rect: CGRect, layer: Int = 0, pid: pid_t = 42) -> [String: Any] {
            [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid,
             kCGWindowBounds as String: rect.dictionaryRepresentation]
        }
        // A zoomed window stops below the menu bar.
        XCTAssertFalse(DockPanelController.isFullScreen(
            windows: [window(CGRect(x: 0, y: 30, width: 2560, height: 1410))], screenFrame: main, ownPID: 1))
        XCTAssertTrue(DockPanelController.isFullScreen(
            windows: [window(main)], screenFrame: main, ownPID: 1))
        // Not on this display, not an ordinary window, or our own: no.
        XCTAssertFalse(DockPanelController.isFullScreen(windows: [window(below)], screenFrame: main, ownPID: 1))
        XCTAssertFalse(DockPanelController.isFullScreen(windows: [window(main, layer: 25)], screenFrame: main, ownPID: 1))
        XCTAssertFalse(DockPanelController.isFullScreen(windows: [window(main, pid: 1)], screenFrame: main, ownPID: 1))

        // A notched laptop: full screen starts below the camera housing (38 pt),
        // and a zoomed window starts below the taller menu bar (49 pt here).
        let laptop = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        XCTAssertTrue(DockPanelController.isFullScreen(
            windows: [window(CGRect(x: 0, y: 38, width: 1710, height: 1074))],
            screenFrame: laptop, topInset: 38, ownPID: 1))
        XCTAssertFalse(DockPanelController.isFullScreen(
            windows: [window(CGRect(x: 0, y: 49, width: 1710, height: 1014))],
            screenFrame: laptop, topInset: 38, ownPID: 1))
    }

    // MARK: Hotkeys

    /// The Automation script wins a ⌃⌥ number over the dock, and gives it
    /// back when it stops.
    func testAutomationKeysAreLeftToAutomation() {
        let store = makeStore()
        _ = store.addProfile(named: "Work")
        store.update { $0.profileHotkeysEnabled = true }
        let hotkeys = DockHotkeys(store: store)
        let expectation = expectation(description: "registered")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        let one = InAppHotkeys.Key(keyCode: DockHotkeys.digitKeyCodes[0], modifiers: DockHotkeys.modifiers)
        InAppHotkeys.shared.setAutomationKeys([one])
        XCTAssertEqual(DockHotkeyStatus.shared.heldByAutomation, [1])
        InAppHotkeys.shared.setAutomationKeys([])
        XCTAssertEqual(DockHotkeyStatus.shared.heldByAutomation, [])
        _ = hotkeys
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

    /// `barshelf accessibility` opens this link; it must never fall through
    /// to the installer.
    func testAccessibilityDeepLinkRoutesToHook() {
        let installer = WidgetInstaller()
        var opened = 0
        installer.onAccessibilityRequest = { opened += 1 }
        installer.handleDeepLink(URL(string: "barshelf://accessibility")!)
        XCTAssertEqual(opened, 1)
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
