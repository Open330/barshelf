import AppKit
import MenubucketCore
import SwiftUI

// What the app offers for one widget, said and drawn the same way wherever
// the widget appears: its popup card, its Shelf chip, its Gallery page, its
// Privacy row, its onboarding row.

// MARK: - Context menu

/// A widget's right-click menu, in one order everywhere. A surface leaves
/// out what it has no use for (a pinned card cannot be turned off; only the
/// Shelf duplicates) but never renames or reorders what it keeps.
struct WidgetContextMenu<Moves: View>: View {
    struct PinItem {
        let title: String
        let enabled: Bool
        let action: () -> Void
    }

    let widgetID: String
    let runtime: WidgetRuntime
    var pin: PinItem?
    let openSettings: () -> Void
    var refresh: (() -> Void)?
    /// Turn Off / Turn On; nil leaves the item out.
    var setDisabled: ((Bool) -> Void)?
    var duplicate: (() -> Void)?
    var remove: (() -> Void)?
    /// Move Up, Move Down, Move to Page — whichever the surface supports.
    @ViewBuilder var moves: Moves

    var body: some View {
        if let pin {
            Button(pin.title, action: pin.action)
                .disabled(!pin.enabled)
        }
        Button("Settings…", action: openSettings)
        if let refresh {
            Button("Refresh", action: refresh)
        }
        Divider()
        if let setDisabled {
            let disabled = runtime.prefs.isDisabled(widgetID)
            Button(disabled ? "Turn On" : "Turn Off") { setDisabled(!disabled) }
        }
        moves
        Divider()
        if let duplicate {
            Button("Duplicate…", action: duplicate)
        }
        Button("Show in Finder") {
            if let directory = runtime.widgetDirectory(for: widgetID) {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        }
        if let remove {
            Divider()
            Button("Remove Widget…", role: .destructive, action: remove)
        }
    }
}

// MARK: - Removal

/// The one confirmation before a widget is removed.
///
/// Removing deletes the widget's folder, its settings, saved data, secrets
/// and permission decisions (`WidgetRuntime.removeWidget`). Nothing keeps a
/// copy, so it cannot be undone; a widget that came from the Gallery can be
/// installed from there again, one built here or added from a URL cannot.
enum WidgetRemoval {
    static func title(_ name: String) -> String {
        String(localized: "Remove “\(name)”?", comment: "Confirmation title before removing a widget")
    }

    static var message: String {
        String(localized: "This deletes the widget and its settings and saved data from this Mac. It can’t be undone, but a widget from the Gallery can be installed again there.")
    }
}

extension View {
    /// See `WidgetRemoval`.
    func widgetRemovalConfirmation(
        isPresented: Binding<Bool>, name: String, onRemove: @escaping () -> Void
    ) -> some View {
        alert(WidgetRemoval.title(name), isPresented: isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive, action: onRemove)
        } message: {
            Text(WidgetRemoval.message)
        }
    }
}

// MARK: - Permission

/// A widget that has asked for permission and not been answered yet: a
/// lock in the warning tone, everywhere it is shown (cards, the Privacy page,
/// the widget inspector, onboarding), so "waiting" reads as one state. The
/// info blue it used before sank into a dark card (dark blue on navy).
enum PermissionWaiting {
    static var title: String { String(localized: "Waiting for your permission") }
    /// The folded approval card's title, beside its Deny and Allow.
    static var shortTitle: String { String(localized: "Needs permission", comment: "Folded permission card title, next to Deny and Allow") }
    static let symbol = "lock.fill"
    static let tone = StatusTone.warning
    /// The lock badge's diameter; the list under it is indented to match.
    static let badgeSize: CGFloat = 26
}

/// The decision on a widget's permissions: Deny quiet, Allow filled.
///
/// Allow is never the default button: several widgets can be waiting at
/// once, and a stray Return must never grant one access.
struct PermissionDecisionButtons: View {
    /// Names the widget for VoiceOver where the row around it does not.
    var widgetName: String?
    /// Nil leaves Deny out (already denied).
    var onDeny: (() -> Void)?
    let onAllow: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let onDeny {
                Button("Deny", action: onDeny)
                    .buttonStyle(.glass(.plain))
                    .accessibilityLabel(widgetName.map { Text("Deny \($0)") } ?? Text("Deny"))
            }
            Button("Allow", action: onAllow)
                .buttonStyle(.glass(.primary))
                .accessibilityLabel(widgetName.map { Text("Allow \($0)") } ?? Text("Allow"))
        }
        .controlSize(.small)
    }
}
