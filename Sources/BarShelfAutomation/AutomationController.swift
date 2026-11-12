import AppKit
import ApplicationServices
import Combine
import MenubucketCore

/// One user-owned automation extension, independent of widget permissions.
/// Source + enabled intent are saved atomically; runtime replacement rolls back
/// on registration or persistence errors. Import alone never requests TCC.
package final class AutomationController: ObservableObject {
    package static let shared = AutomationController()
    package struct Configuration: Codable {
        package var source: String
        package var enabled: Bool
    }
    @Published package private(set) var source = AutomationScript.example
    @Published package private(set) var isRunning = false
    /// Unsaved edits in the settings editor; nil when the editor shows the
    /// saved script. Kept here rather than in the view, so leaving the page
    /// and coming back does not throw edits away.
    @Published package private(set) var draft: String?
    @Published package private(set) var message: String?
    @Published package private(set) var importSummary: String?
    /// Running bindings that macOS also uses for one of its shortcuts.
    @Published package private(set) var systemShortcutConflicts: [SystemShortcutConflicts.Conflict] = []
    /// What the running extension saw after its last input source switch.
    /// A failed switch is reported here and leaves the extension running:
    /// its other shortcuts still work.
    @Published package private(set) var inputSourceStatus: AutomationInputSource.Status = .idle
    private var runningBindings: [HotkeyGrammar.Combination] = []
    private var engine: AutomationRunning?
    private var launchEnabled = false
    private let fileURL: URL
    private let makeEngine: (AutomationScript) -> AutomationRunning
    private let isTrusted: () -> Bool
    private let hammerspoonRunning: () -> Bool

    package init(fileURL: URL = AutomationController.defaultFileURL,
         makeEngine: @escaping (AutomationScript) -> AutomationRunning = { AutomationEngine(script: $0) },
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         hammerspoonRunning: @escaping () -> Bool = {
             NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "org.hammerspoon.Hammerspoon" }
         }) {
        self.fileURL = fileURL
        self.makeEngine = makeEngine
        self.isTrusted = isTrusted
        self.hammerspoonRunning = hammerspoonRunning
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: fileURL))
            source = config.source
            launchEnabled = config.enabled
        } catch { message = String(localized: "Could not read saved automation: \(error.localizedDescription)") }
    }

    /// What a script registers, for the Automation page's figures.
    package struct Summary: Equatable {
        package let shortcuts: Int
        package let remaps: Int
    }

    private var summaryCache: (source: String, summary: Summary?)?

    /// What the saved script registers: its shortcuts and its remapped
    /// keys. Compiled once per saved script; nil when it does not compile.
    package func savedSummary() -> Summary? {
        if let summaryCache, summaryCache.source == source { return summaryCache.summary }
        let script = try? AutomationScript(source: source)
        let summary = script.map {
            Summary(shortcuts: $0.bindings.count, remaps: ($0.remap?.keys.count ?? 0) + $0.keyRemaps.count)
        }
        summaryCache = (source, summary)
        return summary
    }

    /// Reads the system shortcuts again: they change in System Settings with
    /// no notice to other apps.
    package func refreshSystemShortcutConflicts() {
        let conflicts = SystemShortcutConflicts.current(bindings: runningBindings)
        if conflicts != systemShortcutConflicts { systemShortcutConflicts = conflicts }
    }

    package func startAtLaunch() {
        guard launchEnabled else { return }
        apply(source: source, enabled: true)
    }

    /// Records editor text; matching the saved script clears the draft.
    package func setDraft(_ text: String) {
        draft = text == source ? nil : text
    }

    /// Whether putting `text` in the editor (an import, the example) would
    /// throw away edits that were never saved, so the editor should ask.
    package func replacingDraftLosesChanges(with text: String) -> Bool {
        guard let draft else { return false }
        return draft != text
    }

    @discardableResult
    package func apply(source candidate: String, enabled: Bool) -> Bool {
        do {
            let script = try AutomationScript(source: candidate)
            if enabled {
                guard isTrusted() else {
                    throw AutomationFailure(String(localized: "Grant Accessibility access below, then enable the extension again."))
                }
                guard !hammerspoonRunning() else {
                    throw AutomationFailure(String(localized: "Quit Hammerspoon before enabling this extension so the same keys are not handled twice."))
                }
            }
            let replacement = enabled ? makeEngine(script) : nil
            replacement?.report = { [weak self, weak replacement] message in
                guard let self, let replacement, self.engine === replacement else { return }
                self.message = message
            }
            replacement?.permissionLost = { [weak self, weak replacement] in
                guard let self, let replacement, self.engine === replacement else { return }
                self.disable()
                self.message = String(localized: "Accessibility access was removed. Grant access and enable the extension again.")
            }
            replacement?.inputSourceStatusChanged = { [weak self, weak replacement] status in
                // Only the engine that is running now may report: a
                // replacement rolled back after a failed start, or one since
                // replaced, must not overwrite the current state.
                guard let self, let replacement, self.engine === replacement else { return }
                if self.message == self.inputSourceStatus.message { self.message = nil }
                self.inputSourceStatus = status
            }
            replacement?.runtimeFailed = { [weak self, weak replacement] reason in
                guard let self, let replacement, self.engine === replacement else { return }
                // Preserve saved enabled intent for a subsequent launch, but
                // never show a failed input monitor as currently active.
                self.engine = nil
                self.isRunning = false
                self.inputSourceStatus = .idle
                self.message = reason
                NSLog("BarShelf automation stopped: %@", reason)
            }
            let previous = engine
            previous?.stop()
            do {
                try replacement?.start()
                try save(Configuration(source: candidate, enabled: enabled))
            } catch {
                replacement?.stop()
                do { try previous?.start() }
                catch {
                    engine = nil
                    isRunning = false
                    inputSourceStatus = .idle
                    throw AutomationFailure(String(localized: "Could not restore the previous extension: \(error.localizedDescription). Enable it again after resolving the issue."))
                }
                throw error
            }
            engine = replacement
            source = candidate
            launchEnabled = enabled
            isRunning = enabled
            message = nil
            inputSourceStatus = .idle
            runningBindings = enabled ? script.bindings.map(\.combination) : []
            refreshSystemShortcutConflicts()
            for conflict in systemShortcutConflicts {
                NSLog("BarShelf automation: %@ is also the macOS shortcut \"%@\" (symbolic hot key %ld); both run",
                      conflict.binding, conflict.systemName, conflict.systemID)
            }
            return true
        } catch {
            message = error.localizedDescription
            NSLog("BarShelf automation could not apply settings: %@", error.localizedDescription)
            return false
        }
    }

    /// Disabling must always release native resources, even if the file cannot
    /// be saved or the draft being edited currently contains a syntax error.
    package func disable() {
        engine?.stop()
        engine = nil
        isRunning = false
        inputSourceStatus = .idle
        runningBindings = []
        systemShortcutConflicts = []
        launchEnabled = false
        do {
            try save(Configuration(source: source, enabled: false))
            message = nil
        } catch { message = String(localized: "Stopped for this session, but could not save disabled state: \(error.localizedDescription)") }
    }

    package func stopForTermination() { engine?.stop() }

    /// Returns a draft for review; does not replace a saved/running extension.
    package func importFile(_ url: URL, excludingFunctionKeys: Bool = false) -> String? {
        importSummary = nil
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 256 * 1024 else {
                throw AutomationFailure(String(localized: "Extension files must be smaller than 256 KB."))
            }
            let contents = try String(contentsOf: url, encoding: .utf8)
            let result = try AutomationImporter.convert(contents, fileExtension: url.pathExtension, excludingFunctionKeys: excludingFunctionKeys)
            importSummary = result.summary
            message = nil
            return result.script
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Opens the drag-in helper beside Accessibility settings. Once macOS
    /// allows BarShelf, an extension saved as enabled starts without another
    /// click.
    package func requestAccessibility() {
        presentAccessibilityHelper { [weak self] in
            guard let self else { return }
            self.message = nil
            if !self.isRunning { self.startAtLaunch() }
        }
    }

    /// Shows the drag-in helper and calls back once macOS trusts BarShelf.
    /// The helper is a view, so the app supplies it; this target has no UI.
    package var presentAccessibilityHelper: (_ onTrusted: @escaping () -> Void) -> Void = { _ in }

    /// `~/Library/Application Support/barshelf/automation.json`
    package static var defaultFileURL: URL {
        BarShelfDirectories.applicationSupport.appendingPathComponent("automation.json")
    }

    private func save(_ config: Configuration) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }
}
