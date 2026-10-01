import AppKit
import ApplicationServices
import Combine

/// One user-owned automation extension, independent of widget permissions.
/// Source + enabled intent are saved atomically; runtime replacement rolls back
/// on registration or persistence errors. Import alone never requests TCC.
final class AutomationController: ObservableObject {
    static let shared = AutomationController()
    struct Configuration: Codable {
        var source: String
        var enabled: Bool
    }
    @Published private(set) var source = AutomationScript.example
    @Published private(set) var isRunning = false
    @Published private(set) var message: String?
    @Published private(set) var importSummary: String?
    private var engine: AutomationRunning?
    private var launchEnabled = false
    private let fileURL: URL
    private let makeEngine: (AutomationScript) -> AutomationRunning
    private let isTrusted: () -> Bool
    private let hammerspoonRunning: () -> Bool

    init(fileURL: URL = WidgetRuntime.applicationSupportDirectory.appendingPathComponent("automation.json"),
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

    func startAtLaunch() {
        guard launchEnabled else { return }
        apply(source: source, enabled: true)
    }

    @discardableResult
    func apply(source candidate: String, enabled: Bool) -> Bool {
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
            replacement?.report = { [weak self] in self?.message = $0 }
            replacement?.permissionLost = { [weak self] in
                self?.disable()
                self?.message = String(localized: "Accessibility access was removed. Grant access and enable the extension again.")
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
                    throw AutomationFailure(String(localized: "Could not restore the previous extension: \(error.localizedDescription). Enable it again after resolving the issue."))
                }
                throw error
            }
            engine = replacement
            source = candidate
            launchEnabled = enabled
            isRunning = enabled
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    /// Disabling must always release native resources, even if the file cannot
    /// be saved or the draft being edited currently contains a syntax error.
    func disable() {
        engine?.stop()
        engine = nil
        isRunning = false
        launchEnabled = false
        do {
            try save(Configuration(source: source, enabled: false))
            message = nil
        } catch { message = String(localized: "Stopped for this session, but could not save disabled state: \(error.localizedDescription)") }
    }

    func stopForTermination() { engine?.stop() }

    /// Returns a draft for review; does not replace a saved/running extension.
    func importFile(_ url: URL) -> String? {
        importSummary = nil
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 256 * 1024 else {
                throw AutomationFailure(String(localized: "Extension files must be smaller than 256 KB."))
            }
            let contents = try String(contentsOf: url, encoding: .utf8)
            let imported: String
            let summary: String
            if url.pathExtension.lowercased() == "lua" {
                let result = try HammerspoonImporter.convert(contents)
                imported = result.script
                summary = result.summary
            } else if url.pathExtension.lowercased() == "js" {
                _ = try AutomationScript(source: contents)
                imported = contents
                summary = String(localized: "JavaScript loaded into the editor. Save to apply it.")
            } else { throw AutomationFailure(String(localized: "Choose an init.lua navigation profile or a .js extension.")) }
            importSummary = summary
            message = nil
            return imported
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func save(_ config: Configuration) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }
}
