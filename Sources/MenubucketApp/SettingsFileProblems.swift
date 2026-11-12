import AppKit
import MenubucketCore

/// Tells the user when one of their settings files could not be read or
/// written (`JSONFile.problemNotification`), instead of starting from
/// defaults or dropping a change without a word.
///
/// - Unreadable: the file was moved aside and BarShelf started without it.
///   That loses what the user set up, so it is an alert with the kept file.
/// - Write failed: a toast, at most once per file every few minutes, since
///   a full disk would otherwise raise one on every change.
@MainActor
final class SettingsFileProblems {
    static let shared = SettingsFileProblems()

    private var observer: NSObjectProtocol?
    private var lastWriteToast: [URL: Date] = [:]
    private var pendingUnreadable: [JSONFile.Problem] = []
    private var alertScheduled = false

    nonisolated static let writeToastInterval: TimeInterval = 300

    /// Starts listening. Call before any store loads, so a file moved aside
    /// at launch is reported too.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: JSONFile.problemNotification, object: nil, queue: nil
        ) { note in
            guard let problem = note.userInfo?[JSONFile.problemKey] as? JSONFile.Problem else { return }
            Task { @MainActor in SettingsFileProblems.shared.handle(problem) }
        }
    }

    func handle(_ problem: JSONFile.Problem, now: Date = Date()) {
        switch problem.kind {
        case .unreadable:
            pendingUnreadable.append(problem)
            guard !alertScheduled else { return }
            alertScheduled = true
            // After launch has finished and the menu bar item exists.
            DispatchQueue.main.async { [weak self] in self?.showUnreadableAlert() }
        case .writeFailed:
            guard Self.shouldToast(lastShown: lastWriteToast[problem.file], now: now) else { return }
            lastWriteToast[problem.file] = now
            ToastCenter.shared.show(
                String(localized: "Couldn't save your settings"),
                detail: String(localized: "\(problem.file.lastPathComponent): \(problem.message)"),
                tone: .failure
            )
        }
    }

    nonisolated static func shouldToast(lastShown: Date?, now: Date) -> Bool {
        guard let lastShown else { return true }
        return now.timeIntervalSince(lastShown) >= writeToastInterval
    }

    private func showUnreadableAlert() {
        alertScheduled = false
        let problems = pendingUnreadable
        pendingUnreadable = []
        guard !problems.isEmpty else { return }
        let names = problems.map(\.file.lastPathComponent).joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "BarShelf couldn't read some of your settings")
        alert.informativeText = String(localized: "\(names) could not be read, so BarShelf started without it. The original file was kept beside it, with \"corrupt\" and the date in its name.")
        alert.addButton(withTitle: String(localized: "OK"))
        let kept = problems.compactMap { problem -> URL? in
            if case .unreadable(let movedTo) = problem.kind { return movedTo }
            return nil
        }
        if !kept.isEmpty { alert.addButton(withTitle: String(localized: "Show in Finder")) }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting(kept)
        }
    }
}
