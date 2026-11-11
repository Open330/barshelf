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

/// The menu bar as Text and Items draws it, for Settings: the BarShelf icon
/// with the shared strip beside it, then every item of its own. Drawn by the
/// menu bar's own renderers, like the cluster preview, so both layouts show
/// what the bar shows rather than a description of it.
struct MenuBarItemsPreview: View {
    let entries: [MenuBarEntry]
    /// The BarShelf icon's symbol.
    var markSymbol: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let parts = MenuBarPolicy.partition(entries)
        HStack(alignment: .center, spacing: Spacing.xs) {
            item(stripImage(parts.strip), template: false, caption: "BarShelf icon")
            ForEach(parts.separate, id: \.widgetID) { entry in
                let image = MenuBarController.previewImage(for: entry)
                item(image, template: image.isTemplate, caption: LocalizedStringKey(entry.name))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview: \(spoken(parts))"))
    }

    private func spoken(_ parts: (strip: [MenuBarEntry], separate: [MenuBarEntry])) -> String {
        (parts.strip + parts.separate)
            .map { entry in
                let text = MenuBarPolicy.accessibilityText(entry)
                return text.isEmpty ? entry.name : "\(entry.name), \(text)"
            }
            .joined(separator: "; ")
    }

    private func item(_ image: NSImage, template: Bool, caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Image(nsImage: image)
                .renderingMode(template ? .template : .original)
                .padding(.horizontal, Spacing.stack)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Fill.card)
                )
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The main item: the icon, then the strip's text in the bar's fonts and
    /// colours, resolved for the window's appearance.
    private func stripImage(_ strip: [MenuBarEntry]) -> NSImage {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        let height = NSStatusBar.system.thickness
        let mark = BarShelfStatusIcon.image(for: markSymbol, fallback: AppPreferences.defaultMenuBarSymbol)
        let text = MenuBarController.attributedStrip(strip)
        let side = min(height - 4, 16)
        let markSize = NSSize(width: side * max(mark.size.width, 1) / max(mark.size.height, 1), height: side)
        let textSize = text.size()
        let gap: CGFloat = text.length > 0 ? 4 : 0
        let size = NSSize(width: ceil(markSize.width + gap + textSize.width), height: height)
        return NSImage(size: size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                let rect = NSRect(origin: NSPoint(x: 0, y: (height - markSize.height) / 2), size: markSize)
                let tinted = NSImage(size: markSize, flipped: false) { bounds in
                    mark.draw(in: bounds)
                    NSColor.labelColor.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect)
                text.draw(at: NSPoint(x: markSize.width + gap, y: (height - textSize.height) / 2))
            }
            return true
        }
    }
}
