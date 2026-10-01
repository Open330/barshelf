import AppKit
import MenubucketCore
import SwiftUI

// Every state a card can be in besides "showing the widget", each with the
// thing to do next (R13 §4.4). The runtime decides the state; these only draw
// it, from the shared `StatusBanner` and design tokens.

// MARK: - Loading, empty, error

/// First load: grey bars where the content will be, so the card keeps its
/// footprint instead of jumping when data arrives.
struct CardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            bar(width: 0.55, height: 12)
            bar(width: 0.9, height: 10)
            bar(width: 0.7, height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }

    private func bar(width fraction: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: Radius.control / 2, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: geometry.size.width * fraction)
        }
        .frame(height: height)
    }
}

/// Loaded fine, but there is nothing to show yet.
struct CardEmptyView: View {
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text("No data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Refresh", action: onRefresh)
                .controlSize(.small)
        }
        .padding(.vertical, Spacing.xxs)
    }
}

/// A refresh failed and there is no earlier result to fall back on: what
/// happened, what to try, and the raw message behind "Details".
struct CardErrorView: View {
    let error: String
    let onRetry: () -> Void
    let onSettings: () -> Void
    @State private var showsDetails = false

    var body: some View {
        let explanation = ErrorExplainer.explain(error)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            StatusBanner(tone: .critical, message: explanation.cause)
            Text(explanation.fix)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.xs) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                Button(showsDetails ? "Hide Details" : "Details") { showsDetails.toggle() }
                Button("Settings…", action: onSettings)
            }
            .controlSize(.small)
            if showsDetails {
                RawErrorText(error: error)
            }
        }
    }
}

/// The error exactly as the widget reported it, selectable so it can be
/// copied into a bug report.
struct RawErrorText: View {
    let error: String

    var body: some View {
        Text(error)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.xs)
            .cardSurface(radius: Radius.control)
    }
}

/// The latest refresh failed but the card still shows the last good result:
/// a small "Cached" badge whose popover says why and offers a retry.
struct CachedBadge: View {
    let error: String
    let onRetry: () -> Void
    @State private var showsPopover = false

    var body: some View {
        Button { showsPopover.toggle() } label: {
            Label("Cached", systemImage: "clock.arrow.circlepath")
                .font(.caption2)
                .padding(.horizontal, Spacing.xxs + 2)
                .padding(.vertical, 1)
                .foregroundStyle(StatusTone.warning.color)
                .background(Capsule().fill(StatusTone.warning.color.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Showing the last good result — the latest refresh failed")
        .accessibilityLabel("Showing cached data. The latest refresh failed.")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            let explanation = ErrorExplainer.explain(error)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Showing the last good result")
                    .font(.headline)
                StatusBanner(tone: .warning, message: explanation.cause)
                Text(explanation.fix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                RawErrorText(error: error)
                HStack {
                    Spacer()
                    Button("Retry") {
                        showsPopover = false
                        onRetry()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Spacing.m)
            .frame(width: 280)
        }
    }
}

// MARK: - Permissions

/// A widget with new or changed permissions: what it wants, in plain words,
/// and the decision. Allow is the prominent choice; Deny sits beside it.
///
/// Allow is not bound to Return: several cards can be waiting at once, and a
/// stray keystroke must never grant a widget access.
struct PermissionApprovalView: View {
    let widgetName: String
    let requests: [PermissionRequest]
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            StatusBanner(
                tone: .info,
                message: String(localized: "\(widgetName) needs your permission to run."),
                symbol: "lock.shield"
            )
            PermissionList(requests: requests)
            HStack(spacing: Spacing.xs) {
                Spacer(minLength: 0)
                Button("Deny", action: onDeny)
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }
}

/// One row per requested capability, icon first.
struct PermissionList: View {
    let requests: [PermissionRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(requests, id: \.self) { request in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: request.symbol)
                        .font(.caption)
                        .foregroundStyle(request.isWarning ? StatusTone.warning.color : .secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(request.description)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The user said no: a quiet, compact card that keeps the way back (review
/// and allow) and the way out (remove the widget) one click away.
struct PermissionDeniedView: View {
    let widgetName: String
    let requests: [PermissionRequest]
    let onAllow: () -> Void
    let onRemove: () -> Void
    @State private var reviewing = false

    var body: some View {
        if reviewing {
            PermissionApprovalView(
                widgetName: widgetName,
                requests: requests,
                onAllow: onAllow,
                onDeny: { reviewing = false }
            )
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Paused — you denied this widget’s permissions.", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: Spacing.xs) {
                    Button("Review Permissions") { reviewing = true }
                    Button("Remove Widget…", role: .destructive, action: onRemove)
                }
                .controlSize(.small)
            }
            .padding(Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(dimmed: true)
        }
    }
}

// MARK: - Crash-disabled

/// A script widget that kept crashing and was stopped.
struct CrashDisabledView: View {
    let reason: String
    let onRestart: () -> Void
    let onOpenLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            StatusBanner(
                tone: .critical,
                message: String(localized: "Stopped after crashing repeatedly: \(reason)")
            )
            HStack(spacing: Spacing.xs) {
                Button("Restart Widget", action: onRestart)
                    .buttonStyle(.borderedProminent)
                Button("Open Logs", action: onOpenLogs)
            }
            .controlSize(.small)
        }
    }

    /// The widget's own log when it has one, otherwise the folder they live in.
    static func openLogs(widgetID: String) {
        let file = WidgetLogStore().fileURL(widgetId: widgetID)
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = WidgetLogStore.defaultDirectory()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

// MARK: - Freshness

/// "Updated 5 min ago" for the card header.
enum CardFreshness {
    static func label(updatedAt: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(updatedAt)
        if elapsed < 60 { return String(localized: "Updated just now") }
        let relative = formatter.localizedString(for: updatedAt, relativeTo: max(now, updatedAt))
        return String(localized: "Updated \(relative)")
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// The freshness caption, re-rendered every half minute while its page is on
/// screen so "2 min ago" does not stay "just now".
struct FreshnessText: View {
    let updatedAt: Date
    @Environment(\.widgetContentIsActive) private var contentIsActive

    var body: some View {
        if contentIsActive {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                label(now: context.date)
            }
        } else {
            label(now: Date())
        }
    }

    private func label(now: Date) -> some View {
        Text(CardFreshness.label(updatedAt: updatedAt, now: now))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .monospacedDigit()
    }
}
