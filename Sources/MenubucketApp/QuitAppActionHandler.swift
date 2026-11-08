import AppKit
import Foundation
import MenubucketCore

/// What became of one `quitApp` action.
enum QuitAppOutcome: Equatable {
    /// The widget may not quit apps (undeclared, unapproved, disabled, or a
    /// value that names no app).
    case blocked
    /// Nothing quittable is running under that bundle id or pid: no such
    /// app, a process that is not an app, or BarShelf itself.
    case notRunning
    case cancelled
    /// `terminate()` was sent; the app may still ask to save first.
    case requested
}

extension WidgetRuntime {
    /// `quitApp`: ask the user, then send the app a normal quit.
    ///
    /// Gated like every other action that reaches outside BarShelf: the
    /// manifest declares `permissions.quitApps` and the user approved that
    /// permission set. Even then each quit is confirmed, Cancel being the
    /// default, and it is only ever `terminate()` — the app gets to ask
    /// about unsaved work, and is never force-quit. A pid that is not a
    /// running app (a daemon, a helper, a command-line tool) is refused, so
    /// a widget cannot turn this into a way to kill arbitrary processes.
    @discardableResult
    func performQuitApp(
        action: NodeAction,
        widgetID: String,
        confirm: ((_ appName: String, _ widgetName: String) -> Bool)? = nil
    ) -> QuitAppOutcome {
        guard let widget = widgets.first(where: { $0.id == widgetID }),
              !prefs.isDisabled(widgetID)
        else { return .blocked }
        let decision = QuitAppAction.evaluate(
            action,
            manifest: widget.manifest,
            status: permissionStore.status(for: widget.manifest)
        )
        guard case let .allowed(target) = decision else {
            if case let .blocked(reason) = decision {
                NSLog("barshelf: BLOCKED quitApp from %@ — %@", widgetID, reason)
                auditLog.record("quitApp.blocked", widgetId: widgetID, detail: [
                    "value": .string(action.value ?? ""),
                    "reason": .string(reason),
                ])
            }
            return .blocked
        }
        let apps = Self.quittableApps(for: target)
        guard let first = apps.first else {
            NSLog("barshelf: quitApp from %@ found no running app for '%@'",
                  widgetID, action.value ?? "")
            return .notRunning
        }
        let appName = first.localizedName ?? first.bundleIdentifier ?? action.value ?? ""
        let approved = (confirm ?? Self.confirmQuit)(appName, widget.displayName)
        guard approved else { return .cancelled }
        auditLog.record("quitApp.requested", widgetId: widgetID, detail: [
            "app": .string(first.bundleIdentifier ?? appName),
        ])
        for app in apps {
            app.terminate()
        }
        return .requested
    }

    /// Running apps a target names, minus anything that must not be quit
    /// this way: BarShelf itself and processes with no app presence
    /// (`.prohibited` — helpers, agents without UI).
    static func quittableApps(for target: QuitAppAction.Target) -> [NSRunningApplication] {
        let candidates: [NSRunningApplication]
        switch target {
        case let .pid(pid):
            candidates = NSRunningApplication(processIdentifier: pid).map { [$0] } ?? []
        case let .bundleID(bundleID):
            candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return candidates.filter { app in
            app.processIdentifier != ownPID
                && app.activationPolicy != .prohibited
                && !app.isTerminated
        }
    }

    /// "Quit Safari?" with Cancel as the default button.
    static func confirmQuit(appName: String, widgetName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit \(appName)?", comment: "quitApp confirmation title; the app's name")
        alert.informativeText = String(
            localized: "“\(widgetName)” asked to quit this app. If it has unsaved changes, it will ask you about them first.",
            comment: "quitApp confirmation body; the widget's name"
        )
        // Cancel first: it is the default (Return) and the rightmost button.
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\r"
        let quit = alert.addButton(withTitle: String(localized: "Quit"))
        quit.keyEquivalent = ""
        quit.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}
