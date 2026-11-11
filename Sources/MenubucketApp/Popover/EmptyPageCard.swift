import SwiftUI

/// What an empty page shows in place of its widgets, in the popup and on the
/// Shelf board: a card-shaped slot that says where a new widget goes and
/// offers the two ways to put one there. It is not a widget — nothing is
/// installed, scheduled or counted — and it leaves as soon as a widget
/// arrives (`WidgetRuntime.computePages` keeps the page while it is empty).
struct EmptyPageCard: View {
    @ObservedObject var runtime: WidgetRuntime
    let page: String
    /// Opens the Gallery; the next widget installed lands on this page.
    let addWidget: () -> Void
    var compact = false

    var body: some View {
        let others = movableWidgets
        VStack(spacing: compact ? Spacing.xs : Spacing.s) {
            Image(systemName: "plus.square.dashed")
                .font(compact ? .title2 : .largeTitle)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.xxs) {
                Text("Add widgets here")
                    .font(compact ? .callout.weight(.semibold) : .headline)
                Text(compact
                    ? "Drop a widget here, or add one."
                    : "Get one from the Gallery, or move one you have.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: Spacing.xs) {
                Button {
                    runtime.addNextWidget(toPage: page)
                    addWidget()
                } label: {
                    Label("Add Widget…", systemImage: "plus")
                }
                .buttonStyle(.glass(.primary))
                if !others.isEmpty {
                    Menu("Move a Widget Here") {
                        ForEach(others) { widget in
                            Button(widget.displayName) { runtime.moveWidgetToEnd(widget.id, ofPage: page) }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass(.secondary))
                    .fixedSize()
                }
            }
            .controlSize(compact ? .small : .regular)
        }
        .padding(compact ? Spacing.s : Spacing.l)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.tertiary)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Empty page \(PageName.label(page))"))
    }

    /// Widgets on other pages, by name.
    private var movableWidgets: [LoadedWidget] {
        runtime.widgets
            .filter { runtime.effectiveGroup(for: $0.id) != page }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
