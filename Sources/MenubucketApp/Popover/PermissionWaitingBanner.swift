import SwiftUI

/// One line above the shelf when widgets are waiting for permission: how
/// many, and the way to the Privacy page, which lists them by what they ask
/// for. Deliberately no Allow All here: deciding takes reading.
///
/// Shown when several widgets are waiting, or one is waiting on another page
/// (its own card is then out of sight).
struct PermissionWaitingBanner: View {
    @ObservedObject var attention: ShelfAttention
    let currentPageIDs: Set<String>
    let onReview: () -> Void

    var body: some View {
        let waiting = attention.waitingWidgetIDs
        if ShelfAttention.showsWaitingBanner(waitingIDs: waiting, currentPageIDs: currentPageIDs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: PermissionWaiting.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PermissionWaiting.tone.color)
                    .accessibilityHidden(true)
                Text(Self.message(count: waiting.count))
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.xxs)
                Button(AppMenuCommand.reviewPermissions.title, action: onReview)
                    .buttonStyle(.glass(.secondary))
                    .controlSize(.small)
                    .help("Open Privacy to see what each widget asks for")
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

    static func message(count: Int) -> String {
        count == 1
            ? String(localized: "A widget is waiting for your permission", comment: "Popup banner")
            : String(localized: "\(count) widgets are waiting for your permission", comment: "Popup banner")
    }
}
