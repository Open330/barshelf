import Carbon.HIToolbox
import AppKit
import JavaScriptCore
import SwiftUI
import XCTest
@testable import MenubucketApp

final class AutomationTests: XCTestCase {
    func testTapRecoveryReplacesMissingPortButKeepsHealthyHeldKeys() throws {
        var enabled = false
        var releases = 0
        var replacements = 0
        var enables = 0
        try AutomationTapRecovery.recover(valid: false, enabled: { enabled },
            releaseKeys: { releases += 1 }, replace: { replacements += 1; enabled = true },
            enable: { enables += 1 })
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(releases, 1)
        try AutomationTapRecovery.recover(valid: true, enabled: { enabled },
            releaseKeys: { releases += 1 }, replace: { replacements += 1 },
            enable: { enables += 1 })
        XCTAssertEqual(releases, 1, "healthy watchdog checks must preserve held key-up routing")
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(enables, 0)
        enabled = false
        try AutomationTapRecovery.recover(valid: true, enabled: { enabled },
            releaseKeys: { releases += 1 }, replace: { replacements += 1 },
            enable: { enables += 1; enabled = true })
        XCTAssertEqual(releases, 2)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(enables, 1)
    }

    func testTapRecoveryReportsReplacementFailureAndUnsuccessfulReenable() {
        XCTAssertThrowsError(try AutomationTapRecovery.recover(valid: false, enabled: { false },
            releaseKeys: {}, replace: { throw AutomationFailure("tap creation failed") }, enable: {}))
        XCTAssertThrowsError(try AutomationTapRecovery.recover(valid: true, enabled: { false },
            releaseKeys: {}, replace: {}, enable: {}))
    }

    func testRuntimeFailureClearsActiveIndicatorAndPreservesSavedEnabledIntent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("automation.json")
        let engine = StubEngine()
        let controller = AutomationController(fileURL: url, makeEngine: { _ in engine },
            isTrusted: { true }, hammerspoonRunning: { false })
        XCTAssertTrue(controller.apply(source: AutomationScript.example, enabled: true))
        engine.runtimeFailed?("tap recovery failed")
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.message, "tap recovery failed")
        let config = try JSONDecoder().decode(AutomationController.Configuration.self, from: Data(contentsOf: url))
        XCTAssertTrue(config.enabled)
        controller.startAtLaunch()
        XCTAssertTrue(controller.isRunning)
        XCTAssertNil(controller.message)
        controller.disable()
    }

    func testExampleCompilesAndCallbacksPreserveScreenAndDirection() throws {
        let script = try AutomationScript(source: AutomationScript.example)
        XCTAssertEqual(script.bindings.count, 6)
        XCTAssertEqual(script.remap?.keyboardTypes, [91])
        XCTAssertEqual(script.remap?.keys, [34: 126, 38: 123, 40: 125, 37: 124])
        var commands: [String] = []
        script.command = { name, value in commands.append("\(name):\(value.toString()!)") }
        for index in script.bindings.indices { script.invoke(index) }
        XCTAssertEqual(commands, ["mouse:2", "mouse:1", "window:2", "window:1", "rotate:backward", "rotate:forward"])
    }

    func testJavaScriptClosuresRetainStateAcrossPresses() throws {
        let script = try AutomationScript(source: """
        let n = 0;
        barshelf.bind(["ctrl"], "i", () => barshelf.moveMouseToScreen(++n));
        """)
        var targets: [Int32] = []
        script.command = { _, value in targets.append(value.toInt32()) }
        script.invoke(0)
        script.invoke(0)
        XCTAssertEqual(targets, [1, 2])
    }

    func testInvalidScriptsAndTopLevelEffectsAreRejected() {
        for source in [
            "barshelf.bind([", "hs.window.focusedWindow()", "barshelf.moveMouseToScreen(2)",
            "barshelf.bind(['alt'], 'i', 'not a function')",
            "barshelf.bind(['alt'], 'i', () => {}); barshelf.bind(['opt'], 'i', () => {});",
            "barshelf.remapFn({keyboardTypes: [], keys: {i:'up'}})",
            "barshelf.remapFn({keyboardTypes: [91], keys: {i:'up', 'ㅑ':'down'}})",
            "barshelf.remapFn({keyboardTypes: [91.5], keys: {i:'up'}})",
            "barshelf.remapFn({keyboardTypes: [91], keys: {i:'banana'}})",
            "// no registrations"
        ] { XCTAssertThrowsError(try AutomationScript(source: source), source) }
    }

    func testCallbackErrorIsReportedAndNextPressStillWorks() throws {
        let script = try AutomationScript(source: """
        let first = true;
        barshelf.bind(["alt"], "i", () => {
          if (first) { first = false; throw new Error('deliberate'); }
          barshelf.moveMouseToScreen(2);
        });
        """)
        var message: String?
        var called = false
        script.report = { message = $0 }
        script.command = { _, _ in called = true }
        script.invoke(0)
        XCTAssertTrue(message?.contains("deliberate") == true)
        script.invoke(0)
        XCTAssertTrue(called)
    }

    func testSelectNextInputSourceDispatchesOnlyInsideCallback() throws {
        let script = try AutomationScript(source: "barshelf.bind(['cmd'], 'space', () => barshelf.selectNextInputSource());")
        var commands: [String] = []
        script.command = { name, _ in commands.append(name) }
        script.invoke(0)
        XCTAssertEqual(commands, ["inputSource"])
        XCTAssertThrowsError(try AutomationScript(source: "barshelf.selectNextInputSource()"))
    }

    func testNextInputSourceWrapsAndRecoversFromUnlistedCurrent() {
        let ids = ["com.apple.keylayout.ABC", "com.apple.inputmethod.Korean.2SetKorean"]
        XCTAssertEqual(AutomationInputSource.next(after: ids[0], in: ids), ids[1])
        XCTAssertEqual(AutomationInputSource.next(after: ids[1], in: ids), ids[0])
        XCTAssertEqual(AutomationInputSource.next(after: "com.apple.CharacterPaletteIM", in: ids), ids[0])
        XCTAssertNil(AutomationInputSource.next(after: ids[0], in: [ids[0]]))
    }

    func testNativeActionFailureReachesJavaScriptErrorHandler() throws {
        let script = try AutomationScript(source: "barshelf.bind(['alt'], 'i', () => barshelf.moveMouseToScreen(2));")
        script.command = { _, _ in throw AutomationFailure("Native operation failed") }
        var message: String?
        script.report = { message = $0 }
        script.invoke(0)
        XCTAssertTrue(message?.contains("Native operation failed") == true)
    }

    func testCurrentLuaProfileImportsWithoutChangingBindings() throws {
        let result = try HammerspoonImporter.convert(HammerspoonImporter.referenceSource)
        let script = try AutomationScript(source: result.script)
        let expected = try AutomationScript(source: AutomationScript.example)
        XCTAssertEqual(script.bindings.map(\.combination), expected.bindings.map(\.combination))
        XCTAssertEqual(script.remap, expected.remap)
        XCTAssertTrue(result.summary.contains("6 shortcuts"))
    }

    func testLuaImportPreservesCustomShortcutsKeyboardTypesAndTargets() throws {
        let lua = HammerspoonImporter.referenceSource
            .replacingOccurrences(of: "{ 91 }", with: "{ 91, 40 }")
            .replacingOccurrences(of: "moveMouseToScreen(2)", with: "moveMouseToScreen(3)")
            .replacingOccurrences(of: "{\"alt\", \"shift\"}, \"i\"", with: "{'ctrl', 'shift'}, 'o'")
        let script = try AutomationScript(source: HammerspoonImporter.convert(lua).script)
        XCTAssertEqual(script.remap?.keyboardTypes, [91, 40])
        XCTAssertEqual(script.bindings[0].combination, try HotkeyGrammar.parse("ctrl+shift+o").get())
        var screen: Int32?
        script.command = { _, value in screen = value.toInt32() }
        script.invoke(0)
        XCTAssertEqual(screen, 3)
    }

    func testLuaImportAcceptsCommentsAndWhitespace() throws {
        let lua = "--[[ a block comment ]]\n" + HammerspoonImporter.referenceSource
            .replacingOccurrences(of: "\n", with: "\n-- a comment\n  ")
        XCTAssertNoThrow(try HammerspoonImporter.convert(lua))
    }

    func testLuaImportRejectsExtraCodeAndModifiedHelpers() {
        let original = HammerspoonImporter.referenceSource
        for lua in [
            original + "\nhs.alert.show('extra behavior')",
            original.replacingOccurrences(of: "window:focus()", with: "window:close()"),
            original.replacingOccurrences(of: "moveMouseToScreen(2)", with: "moveMouseToScreen(2) hs.alert.show('extra')"),
            original.replacingOccurrences(of: "{ 91 }", with: "{ getKeyboardType() }"),
            original.replacingOccurrences(of: "i = \"up\"", with: "i = \"down\"") // conflicting Hangul alias
        ] { XCTAssertThrowsError(try HammerspoonImporter.convert(lua)) }
    }

    func testPhysicalFnMappingRetainsKeyUpAfterFnReleaseAndRepeat() throws {
        let config = try XCTUnwrap(AutomationScript(source: AutomationScript.example).remap)
        var state = AutomationRemapState()
        XCTAssertEqual(state.target(code: 34, keyboard: 91, down: true, fn: true, configuration: config), 126)
        XCTAssertEqual(state.target(code: 34, keyboard: 91, down: true, fn: false, configuration: config), 126)
        XCTAssertEqual(state.target(code: 34, keyboard: 91, down: false, fn: false, configuration: config), 126)
        XCTAssertTrue(state.held.isEmpty)
        XCTAssertNil(state.target(code: 34, keyboard: 91, down: true, fn: false, configuration: config))
    }

    func testExternalKeyboardDoesNotConsumeInternalKeyUp() throws {
        let config = try XCTUnwrap(AutomationScript(source: AutomationScript.example).remap)
        var state = AutomationRemapState()
        XCTAssertEqual(state.target(code: 38, keyboard: 91, down: true, fn: true, configuration: config), 123)
        XCTAssertNil(state.target(code: 38, keyboard: 40, down: false, fn: true, configuration: config))
        XCTAssertNil(state.target(code: 38, keyboard: 40, down: true, fn: true, configuration: config))
        XCTAssertEqual(state.target(code: 38, keyboard: 91, down: false, fn: false, configuration: config), 123)
    }

    func testScreenCoordinatesIncludeDisplaysAboveAndLeftOfPrimary() {
        XCTAssertEqual(AutomationGeometry.quartz(CGRect(x: -1920, y: 1080, width: 1920, height: 1080), primaryHeight: 1080),
                       CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
    }

    func testMovingWindowPreservesProportionsAndClampsToUsableArea() {
        let source = CGRect(x: 0, y: 25, width: 1000, height: 800)
        let target = CGRect(x: -2000, y: -1000, width: 2000, height: 1600)
        XCTAssertEqual(AutomationGeometry.movedFrame(CGRect(x: 100, y: 125, width: 400, height: 300), from: source, to: target),
                       CGRect(x: -1800, y: -800, width: 800, height: 600))
        XCTAssertEqual(AutomationGeometry.movedFrame(CGRect(x: -100, y: -100, width: 1500, height: 1200), from: source, to: target), target)
    }

    func testSpanningWindowBelongsToDisplayWithLargestIntersection() {
        XCTAssertEqual(AutomationGeometry.screenIndex(for: CGRect(x: 800, y: 100, width: 900, height: 600), screens: [
            CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)
        ]), 1)
    }

    func testWindowCycleWrapsBothDirections() {
        XCTAssertEqual(AutomationGeometry.nextWindow(current: 2, count: 3, forward: true), 0)
        XCTAssertEqual(AutomationGeometry.nextWindow(current: 0, count: 3, forward: false), 2)
        XCTAssertEqual(AutomationGeometry.nextWindow(current: nil, count: 3, forward: true), 0)
        XCTAssertNil(AutomationGeometry.nextWindow(current: 0, count: 1, forward: true))
    }

    func testDisabledScriptPersistsAndInvalidReplacementPreservesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("automation.json")
        let controller = AutomationController(fileURL: url)
        let script = "barshelf.bind(['ctrl'], 'i', () => moveMouseToScreen(1));"
        XCTAssertTrue(controller.apply(source: script, enabled: false))
        XCTAssertFalse(controller.apply(source: "invalid !!!", enabled: false))
        XCTAssertEqual(controller.source, script)
        let restored = AutomationController(fileURL: url)
        XCTAssertEqual(restored.source, script)
        XCTAssertFalse(restored.isRunning)
    }

    func testUnsavedDraftOutlivesTheEditorAndClearsWhenItMatchesTheSavedScript() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = AutomationController(fileURL: folder.appendingPathComponent("automation.json"))
        let saved = "barshelf.bind(['ctrl'], 'i', () => moveMouseToScreen(1));"
        XCTAssertTrue(controller.apply(source: saved, enabled: false))
        XCTAssertNil(controller.draft)

        // An edit is held by the controller, so a settings page that is left
        // and rebuilt shows it again instead of the saved script.
        controller.setDraft(saved + "\n// edit")
        XCTAssertEqual(controller.draft, saved + "\n// edit")
        XCTAssertEqual(controller.source, saved, "a draft is not saved")

        controller.setDraft(saved)
        XCTAssertNil(controller.draft, "text equal to the saved script is no draft")
    }

    func testImportIsOnlyADraftAndDoesNotOverwriteSavedSourceOrOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("init.lua")
        try HammerspoonImporter.referenceSource.write(to: url, atomically: true, encoding: .utf8)
        let controller = AutomationController(fileURL: folder.appendingPathComponent("automation.json"))
        let original = controller.source
        XCTAssertNotNil(controller.importFile(url))
        XCTAssertEqual(controller.source, original)
        XCTAssertEqual(try String(contentsOf: url), HammerspoonImporter.referenceSource)
        XCTAssertFalse(controller.isRunning)
    }

    private final class StubEngine: AutomationRunning {
        var report: ((String) -> Void)?
        var permissionLost: (() -> Void)?
        var runtimeFailed: ((String) -> Void)?
        var inputSourceStatusChanged: ((AutomationInputSource.Status) -> Void)?
        var starts = 0
        var stops = 0
        var failure = false
        func start() throws {
            starts += 1
            if failure { throw AutomationFailure("Shortcut conflict") }
        }
        func stop() { stops += 1 }
    }

    func testRegistrationFailureRestoresPreviousRuntimeAndSavedSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = StubEngine()
        let second = StubEngine()
        second.failure = true
        var engines = [first, second]
        let url = folder.appendingPathComponent("automation.json")
        let controller = AutomationController(fileURL: url, makeEngine: { _ in engines.removeFirst() },
                                              isTrusted: { true }, hammerspoonRunning: { false })
        XCTAssertTrue(controller.apply(source: AutomationScript.example, enabled: true))
        let saved = try Data(contentsOf: url)
        XCTAssertFalse(controller.apply(source: "barshelf.bind(['ctrl'], 'i', () => moveMouseToScreen(1));", enabled: true))
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(first.starts, 2)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(second.stops, 1)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        XCTAssertEqual(controller.source, AutomationScript.example)
        controller.disable()
        XCTAssertFalse(controller.isRunning)
    }

    func testRevokingPermissionStopsRuntimeAndPersistsDisabledState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        let url = folder.appendingPathComponent("automation.json")
        let controller = AutomationController(fileURL: url, makeEngine: { _ in engine },
                                              isTrusted: { true }, hammerspoonRunning: { false })
        XCTAssertTrue(controller.apply(source: AutomationScript.example, enabled: true))
        engine.permissionLost?()
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(engine.stops, 1)
        let config = try JSONDecoder().decode(AutomationController.Configuration.self, from: Data(contentsOf: url))
        XCTAssertFalse(config.enabled)
    }

    func testPermissionAndHammerspoonConflictsNeverStartRuntime() {
        for (trusted, running) in [(false, false), (true, true)] {
            var created = false
            let controller = AutomationController(fileURL: URL(fileURLWithPath: "/nonexistent/automation.json"),
                makeEngine: { _ in created = true; return StubEngine() },
                isTrusted: { trusted }, hammerspoonRunning: { running })
            XCTAssertFalse(controller.apply(source: AutomationScript.example, enabled: true))
            XCTAssertFalse(created)
            XCTAssertFalse(controller.isRunning)
            XCTAssertNotNil(controller.message)
        }
    }

    func testActualHammerspoonFileWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["BARSHELF_IMPORT_LUA"] else {
            throw XCTSkip("Set BARSHELF_IMPORT_LUA to verify a local profile")
        }
        let result = try HammerspoonImporter.convert(String(contentsOfFile: path, encoding: .utf8))
        let script = try AutomationScript(source: result.script)
        XCTAssertEqual(script.bindings.count, 6)
        XCTAssertEqual(script.remap?.keyboardTypes, [91])
    }

    @MainActor
    func testRenderExtensionSettingsWhenRequested() throws {
        guard let folder = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("Set BARSHELF_SHOT_DIR to inspect the extension settings")
        }
        func render(_ controller: AutomationController, name: String) throws {
            let view = Form { AutomationSettingsView(controller: controller) }
                .formStyle(.grouped).frame(width: 740, height: 1000)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 740, height: 1000)
            hosting.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        let controller = AutomationController(fileURL: URL(fileURLWithPath: folder).appendingPathComponent("automation-shot.json"))
        try render(controller, name: "automation-settings")
        for (name, status): (String, AutomationInputSource.Status) in [
            ("input-settings-unreadable", .needsAttention(AutomationInputSourceMonitor.settingsUnavailable)),
            ("input-switch-unchanged", .needsAttention(AutomationInputSourceMonitor.noChangeDetected)),
            ("input-switch-changed", .changed)
        ] {
            let engine = StubEngine()
            let preview = AutomationController(fileURL: URL(fileURLWithPath: folder).appendingPathComponent(name + ".json"),
                makeEngine: { _ in engine }, isTrusted: { true }, hammerspoonRunning: { false })
            XCTAssertTrue(preview.apply(source: AutomationScript.example, enabled: true))
            engine.inputSourceStatusChanged?(status)
            try render(preview, name: name)
            preview.disable()
        }
    }

    func testSaveFailureDoesNotCommitDraft() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = AutomationController(fileURL: url.appendingPathComponent("automation.json"))
        let original = controller.source
        XCTAssertFalse(controller.apply(source: "barshelf.bind(['alt'], 'u', () => moveMouseToScreen(1));", enabled: false))
        XCTAssertEqual(controller.source, original)
        XCTAssertNotNil(controller.message)
    }

    // MARK: System shortcut conflicts

    private func systemTable(_ entries: [Int: (enabled: Bool, keyCode: Int, modifiers: Int)]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: entries.map { id, entry in
            (String(id), ["enabled": entry.enabled,
                          "value": ["parameters": [32, entry.keyCode, entry.modifiers], "type": "standard"]] as [String: Any])
        })
    }

    /// ⌘Space bound in Automation while the system's "Select next source"
    /// (61) is on: both fire, so it is reported; with 61 off, nothing is.
    func testCommandSpaceConflictsOnlyWhileTheSystemShortcutIsOn() throws {
        let script = try AutomationScript(source: "barshelf.bind(['cmd'], 'space', () => barshelf.selectNextInputSource());")
        let bindings = script.bindings.map(\.combination)
        let on = systemTable([61: (true, 49, 0x100000), 64: (true, 49, 0x80000)])
        let conflicts = SystemShortcutConflicts.find(bindings: bindings, symbolicHotKeys: on)
        XCTAssertEqual(conflicts.map(\.systemID), [61], "⌥Space (Spotlight) is a different shortcut")
        XCTAssertEqual(conflicts.first?.displayBinding, "⌘Space")
        let off = systemTable([61: (false, 49, 0x100000)])
        XCTAssertTrue(SystemShortcutConflicts.find(bindings: bindings, symbolicHotKeys: off).isEmpty)
    }

    func testConflictsCompareAllFourModifiers() throws {
        let script = try AutomationScript(source: "barshelf.bind(['ctrl', 'alt', 'shift', 'cmd'], 'k', () => {});")
        let bindings = script.bindings.map(\.combination)
        let all = 0x100000 | 0x20000 | 0x80000 | 0x40000
        // Key code 40 is K. The fn bit (0x800000) some entries carry is ignored.
        XCTAssertEqual(SystemShortcutConflicts.find(bindings: bindings,
            symbolicHotKeys: systemTable([999: (true, 40, all | 0x800000)])).count, 1)
        XCTAssertTrue(SystemShortcutConflicts.find(bindings: bindings,
            symbolicHotKeys: systemTable([999: (true, 40, 0x100000)])).isEmpty)
        XCTAssertEqual(SystemShortcutConflicts.cocoaModifiers(fromCarbon: UInt32(cmdKey | shiftKey)), 0x100000 | 0x20000)
    }

    // MARK: Input source relay

    /// Hot key 61 set to F18 (key code 79, function flag only): the switch is
    /// relayed to the system. With a modifier, or off, it is not.
    func testInputSourceRelaysOnlyToAModifierlessSystemShortcut() {
        let f18 = systemTable([61: (true, 79, 0x800000)])
        XCTAssertEqual(AutomationInputSource.systemTrigger(in: f18),
                       AutomationInputSource.SystemTrigger(keyCode: 79, flags: .maskSecondaryFn))
        XCTAssertEqual(AutomationInputSource.systemTrigger(in: systemTable([61: (true, 79, 0)]))?.keyCode, 79)
        XCTAssertNil(AutomationInputSource.systemTrigger(in: systemTable([61: (true, 49, 0x100000)])), "⌘Space commits on release")
        XCTAssertNil(AutomationInputSource.systemTrigger(in: systemTable([61: (false, 79, 0x800000)])))
        XCTAssertNil(AutomationInputSource.systemTrigger(in: [:]))
    }

    /// The relay key is not a conflict: ⌘Space no longer matches 61 once 61
    /// is F18.
    func testF18RelayIsNotReportedAsAConflict() throws {
        let script = try AutomationScript(source: "barshelf.bind(['cmd'], 'space', () => barshelf.selectNextInputSource());")
        XCTAssertTrue(SystemShortcutConflicts.find(bindings: script.bindings.map(\.combination),
                      symbolicHotKeys: systemTable([61: (true, 79, 0x800000)])).isEmpty)
    }
    func testInputSwitchFailureKeepsOtherShortcutsRunningAndClearsOnlyItsOwnMessage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        let controller = AutomationController(fileURL: folder.appendingPathComponent("automation.json"),
            makeEngine: { _ in engine }, isTrusted: { true }, hammerspoonRunning: { false })
        XCTAssertTrue(controller.apply(source: AutomationScript.example, enabled: true))
        engine.inputSourceStatusChanged?(.needsAttention("input failed"))
        engine.report?("input failed")
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.inputSourceStatus, .needsAttention("input failed"))
        engine.inputSourceStatusChanged?(.checking)
        XCTAssertNil(controller.message)
        engine.report?("unrelated script log")
        engine.inputSourceStatusChanged?(.changed)
        XCTAssertEqual(controller.message, "unrelated script log")
        controller.disable()
        XCTAssertEqual(controller.inputSourceStatus, .idle)
        engine.inputSourceStatusChanged?(.needsAttention("late input failure"))
        engine.report?("late message")
        XCTAssertEqual(controller.inputSourceStatus, .idle)
        XCTAssertNil(controller.message)
    }

    func testReplacedOrRolledBackEnginesCannotOverwriteInputStatus() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = StubEngine(), failed = StubEngine(), replacement = StubEngine()
        failed.failure = true
        var engines = [first, failed, replacement]
        let controller = AutomationController(fileURL: folder.appendingPathComponent("automation.json"),
            makeEngine: { _ in engines.removeFirst() }, isTrusted: { true }, hammerspoonRunning: { false })
        XCTAssertTrue(controller.apply(source: AutomationScript.example, enabled: true))
        first.inputSourceStatusChanged?(.needsAttention("first"))
        XCTAssertFalse(controller.apply(source: AutomationScript.example, enabled: true))
        failed.inputSourceStatusChanged?(.needsAttention("failed replacement"))
        XCTAssertEqual(controller.inputSourceStatus, .needsAttention("first"))
        first.inputSourceStatusChanged?(.changed)
        XCTAssertEqual(controller.inputSourceStatus, .changed)
        XCTAssertTrue(controller.apply(source: AutomationScript.example, enabled: true))
        XCTAssertEqual(controller.inputSourceStatus, .idle)
        first.inputSourceStatusChanged?(.needsAttention("superseded"))
        first.runtimeFailed?("superseded failure")
        first.permissionLost?()
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.inputSourceStatus, .idle)
        replacement.inputSourceStatusChanged?(.needsAttention("current"))
        replacement.runtimeFailed?("current failure")
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.inputSourceStatus, .idle)
    }

    func testInputFailureIsNotDuplicatedByTheRealJavaScriptErrorBridge() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = StubEngine()
        let controller = AutomationController(fileURL: folder.appendingPathComponent("automation.json"),
            makeEngine: { _ in engine }, isTrusted: { true }, hammerspoonRunning: { false })
        XCTAssertTrue(controller.apply(source: AutomationScript.example, enabled: true))
        let script = try AutomationScript(source: "barshelf.bind(['cmd'], 'space', () => barshelf.selectNextInputSource()); barshelf.bind(['alt'], 'i', () => { throw new Error('unrelated'); });")
        script.command = { name, _ in
            if name == "inputSource" {
                engine.inputSourceStatusChanged?(.needsAttention("input failed"))
                throw AutomationInputSource.ReportedFailure(message: "input failed")
            }
        }
        script.report = { engine.report?($0) }
        script.invoke(0)
        XCTAssertEqual(controller.inputSourceStatus, .needsAttention("input failed"))
        XCTAssertNil(controller.message, "the exact already-reported native exception must not be duplicated with an Error prefix or line suffix")
        engine.inputSourceStatusChanged?(.checking)
        engine.inputSourceStatusChanged?(.changed)
        XCTAssertNil(controller.message)
        script.invoke(1)
        XCTAssertTrue(controller.message?.contains("unrelated") == true)
        engine.inputSourceStatusChanged?(.checking)
        engine.inputSourceStatusChanged?(.changed)
        XCTAssertTrue(controller.message?.contains("unrelated") == true)
        controller.disable()
    }

    func testCatchingAnInputFailureAndThrowingAnotherErrorStillReportsTheNewError() throws {
        let script = try AutomationScript(source: "barshelf.bind(['cmd'], 'space', () => { try { barshelf.selectNextInputSource(); } catch (e) { throw new Error('custom recovery failed'); } });")
        script.command = { _, _ in throw AutomationInputSource.ReportedFailure(message: "input failed") }
        var messages: [String] = []
        script.report = { messages.append($0) }
        script.invoke(0)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("custom recovery failed"))
    }

    func testUnusedAutomationEngineDeallocatesWithoutCreatingAnInputMonitor() throws {
        let script = try AutomationScript(source: "barshelf.bind(['cmd'], 'space', () => barshelf.selectNextInputSource());")
        weak var released: AutomationEngine?
        do {
            let engine = AutomationEngine(script: script)
            released = engine
        }
        XCTAssertNil(released)
    }

}
