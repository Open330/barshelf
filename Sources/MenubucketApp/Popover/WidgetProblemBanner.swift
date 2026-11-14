import SwiftUI

/// One line above the shelf when a widget on another page has a problem:
/// which one, what is wrong, and the way to its page. Without it the red dot
/// on the icon pointed at a card the popup was not showing.
struct WidgetProblemBanner: View {
    @ObservedObject var attention: ShelfAttention
    let currentPageIDs: Set<String>
    let onShow: (String) -> Void

    var body: some View {
        let elsewhere = Self.elsewhere(attention.problems, currentPageIDs: currentPageIDs)
        if let first = elsewhere.first {
            HStack(spacing: Spacing.xs) {
                Image(systemName: StatusTone.warning.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StatusTone.warning.color)
                    .accessibilityHidden(true)
                Text(Self.message(first, others: elsewhere.count - 1))
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.xxs)
                Button(String(localized: "Show", comment: "Popup banner: go to the widget with a problem")) {
                    onShow(first.widgetID)
                }
                .buttonStyle(.glass(.secondary))
                .controlSize(.small)
                .help(String(localized: "Go to \(first.name)"))
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(radius: Radius.control, dimmed: true)
            .padding(.horizontal, Spacing.cardGap)
            .padding(.top, Spacing.cardGap)
            .accessibilityElement(children: .combine)
        }
    }

    /// Problems on pages other than the one shown: those on it have their
    /// own card in view.
    static func elsewhere(_ problems: [ShelfAttention.Problem], currentPageIDs: Set<String>) -> [ShelfAttention.Problem] {
        problems.filter { !currentPageIDs.contains($0.widgetID) }
    }

    static func message(_ problem: ShelfAttention.Problem, others: Int) -> String {
        others > 0
            ? String(localized: "\(problem.name): \(problem.message) (and \(others) more)", comment: "Popup banner")
            : String(localized: "\(problem.name): \(problem.message)", comment: "Popup banner")
    }
}
