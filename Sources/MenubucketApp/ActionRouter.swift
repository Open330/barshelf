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
                        NSLog("menubucket: cleared clipboard for %@ after %ds", widgetID, clearAfter)
                    }
                }
            }
            // Simple feedback in lieu of a toast overlay (M2 candidate).
            // Never log the copied value — it may be sensitive.
            NSSound.beep()
            NSLog("menubucket: copied text for \(widgetID)%@",
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
            let expanded = (path as NSString).expandingTildeInPath
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded))

        case "revealFile":
            guard let path = action.path ?? action.value else { return }
            let expanded = (path as NSString).expandingTildeInPath
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])

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
            NSLog("menubucket: unknown action type '%@' from %@", action.type, widgetID)
        }
    }
}
