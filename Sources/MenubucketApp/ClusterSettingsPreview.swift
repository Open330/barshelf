import AppKit
import MenubucketCore
import SwiftUI

extension WidgetRuntime {
    /// The colour a widget's chip is drawn in: its accent, or nil for the
    /// system accent.
    func chipColor(for widgetID: String) -> NSColor? {
        guard let widget = widgets.first(where: { $0.id == widgetID }),
              let color = prefs.effectiveAppearance(for: widget.manifest, widgetID: widgetID).accentColor
        else { return nil }
        return NSColor(color)
    }
}

/// The menu bar cluster as Settings shows it: drawn by the menu bar's own
/// renderer, at rest and with a chip pointed at, so the settings never
/// describe chips the bar does not draw.
struct ClusterSettingsPreview: View {
    let chips: [ClusterChip]
    let color: (ClusterChip) -> NSColor
    /// The BarShelf icon beside the chips.
    var markSymbol: String?
    /// The chip shown pointed at.
    var focusIndex = 0

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Spacing.m) {
            frame(image(focus: nil), caption: "At rest")
            if !chips.isEmpty {
                frame(image(focus: min(focusIndex, chips.count - 1)), caption: "Pointed at")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview: \(chips.map(\.spoken).joined(separator: ", "))"))
    }

    private func frame(_ image: NSImage, caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Image(nsImage: image)
                .padding(.horizontal, Spacing.xs)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Fill.card)
                )
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func image(focus: Int?) -> NSImage {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        let colors = MenuBarController.clusterColors(chips, base: { id in
            chips.first { $0.widgetID == id }.map(color) ?? .controlAccentColor
        })
        let draw: (ClusterChip) -> NSColor = { colors[$0.id] ?? color($0) }
        let pill = MenuBarController.pillWidth(chips)
        let mark = BarShelfStatusIcon.image(
            for: markSymbol ?? AppPreferences.defaultMenuBarSymbol, fallback: AppPreferences.defaultMenuBarSymbol
        )
        let geometry = ClusterGeometry(count: chips.count)
        let positions = MenuBarController.clusterTargets(chips, focus: focus)
        let lead = focus == nil ? 0 : MenuBarController.clusterLead(for: chips)
        return MenuBarController.clusterImage(
            chips, positions: positions, focus: focus, pill: focus == nil ? CGFloat(ClusterGeometry.disc) : pill,
            lead: lead,
            markAlpha: markSymbol == nil || geometry.hidesMark(focus: focus) ? 0 : 1,
            mark: mark, badged: false, color: draw, appearance: appearance,
            height: NSStatusBar.system.thickness
        )
    }
}
