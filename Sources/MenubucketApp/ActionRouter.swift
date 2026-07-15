import AppKit
import Foundation
import MenubucketCore

/// Executes declarative `NodeAction`s coming from rendered buttons.
enum ActionRouter {
    static func perform(_ action: NodeAction, widgetID: String, runtime: WidgetRuntime?) {
        switch action.type {
        case "copyText":
            guard let value = action.value else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            // Sensitive values (OTP codes): auto-clear after N seconds, but
            // only if the pasteboard still holds our copy (changeCount check).
            if let clearAfter = action.clearAfterSec, clearAfter > 0 {
                let changeCount = pasteboard.changeCount
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(clearAfter)) {
                    if NSPasteboard.general.changeCount == changeCount {
                        NSPasteboard.general.clearContents()
                        NSLog("barshelf: cleared clipboard for %@ after %ds", widgetID, clearAfter)
                    }
                }
            }
            // In-popup confirmation toast; the beep is kept as an audible
            // fallback for when the popup (and thus the toast) is closed.
            // Never log the copied value — it may be sensitive.
            Task { @MainActor in ToastCenter.shared.show(action.toast ?? "Copied") }
            NSSound.beep()
            NSLog("barshelf: copied text for \(widgetID)%@",
                  action.toast.map { " (\($0))" } ?? "")

        case "run":
            // Only commands matching the manifest permissions.exec allowlist
            // may run; the runtime blocks and logs mismatches.
            runtime?.performRun(action: action, widgetID: widgetID)

        case "openURL":
            guard let urlString = action.url ?? action.value,
                  let url = URL(string: urlString)
            else { return }
            NSWorkspace.shared.open(url)

        case "openFile":
            guard let path = action.path ?? action.value else { return }
            guard runtime?.filePathAllowed(path, widgetID: widgetID) == true else { return }
            let expanded = (path as NSString).expandingTildeInPath
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded))

        case "revealFile":
            guard let path = action.path ?? action.value else { return }
            guard runtime?.filePathAllowed(path, widgetID: widgetID) == true else { return }
            let expanded = (path as NSString).expandingTildeInPath
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])

        case "openApp":
            // Launch (or foreground) an app by bundle id ("com.apple.iCal"),
            // display name ("Activity Monitor"), or a full .app path — so a
            // widget can behave like a native one: click → open its companion app.
            guard let value = action.value ?? action.url else { return }
            openApp(value)

        case "refresh":
            if let targetID = action.id {
                runtime?.refresh(widgetID: targetID)
            } else {
                runtime?.refresh(widgetID: widgetID)
            }

        case "event":
            // Script runtime: forwarded to the widget as `widget.action`.
            runtime?.sendScriptEvent(actionId: action.id, widgetID: widgetID)

        // Host-generated cards (permission approval / crash-loop restart).
        case "permission.approve":
            runtime?.approvePermissions(widgetID: widgetID)

        case "permission.deny":
            runtime?.denyPermissions(widgetID: widgetID)

        case "widget.restart":
            runtime?.restartScriptWidget(widgetID: widgetID)

        default:
            NSLog("barshelf: unknown action type '%@' from %@", action.type, widgetID)
        }
    }

    /// Resolves and launches an application from a bundle identifier, a display
    /// name, or a full `.app` path. Bundle identifiers are the most reliable for
    /// system apps (they survive localization and relocation).
    private static func openApp(_ identifier: String) {
        let workspace = NSWorkspace.shared
        let config = NSWorkspace.OpenConfiguration()

        // Looks like a bundle id: dotted, no slash, no space (e.g. com.apple.iCal).
        if identifier.contains("."), !identifier.contains("/"),
           !identifier.contains(" "),
           let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
            workspace.openApplication(at: url, configuration: config)
            return
        }

        // A full path to a bundle.
        if identifier.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: identifier) {
                workspace.openApplication(
                    at: URL(fileURLWithPath: identifier), configuration: config)
            }
            return
        }

        // A display name: search the standard application locations.
        let appName = identifier.hasSuffix(".app") ? identifier : "\(identifier).app"
        let searchDirs = [
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications",
            "/Applications/Utilities",
        ]
        for dir in searchDirs {
            let candidate = "\(dir)/\(appName)"
            if FileManager.default.fileExists(atPath: candidate) {
                workspace.openApplication(
                    at: URL(fileURLWithPath: candidate), configuration: config)
                return
            }
        }
        NSLog("barshelf: openApp could not resolve '%@'", identifier)
    }
}
