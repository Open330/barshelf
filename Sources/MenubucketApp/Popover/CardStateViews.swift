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
                .fill(Fill.pressed)
                .frame(width: geometry.size.width * fraction)
        }
        .frame(height: height)
    }
}

/// Nothing to show yet: what the widget's author says to do, or what the
/// card is waiting for. Its own Refresh only on a card whose header has none.
struct CardEmptyView: View {
    let message: String
    var nextRefresh: Date?
    var onRefresh: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Group {
                if let nextRefresh {
                    // Redrawn once when the time comes, so a refresh that is
                    // late never turns the countdown into a counter.
                    TimelineView(.explicit([nextRefresh])) { context in
                        if Self.showsCountdown(to: nextRefresh, now: context.date) {
                            Text("\(message), \(Text(nextRefresh, style: .relative)) from now",
                                 comment: "Empty card: “Waiting for the first refresh, 30 sec from now”")
                        } else {
                            Text(verbatim: message)
                        }
                    }
                } else {
                    Text(verbatim: message)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onRefresh {
                Button("Refresh", action: onRefresh)
                    .buttonStyle(.glass(.secondary))
                    .controlSize(.small)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    /// The countdown only while the time is ahead: once it has passed,
    /// a relative date would count up instead.
    static func showsCountdown(to nextRefresh: Date, now: Date) -> Bool { nextRefresh > now }

    /// The author's hint; otherwise what the card is waiting for.
    static func message(hint: String?, hasRefreshed: Bool) -> String {
        if let hint, !hint.isEmpty { return hint }
        return hasRefreshed
            ? String(localized: "Nothing to show right now")
            : String(localized: "Waiting for the first refresh")
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
                    .buttonStyle(.glass(.primary))
                Button(showsDetails ? "Hide Details" : "Details") { showsDetails.toggle() }
                Button("Settings…", action: onSettings)
                if explanation.kind == .permissionDenied {
                    PrivacySettingsButton()
                }
            }
            .buttonStyle(.glass(.secondary))
            .controlSize(.small)
            if showsDetails {
                RawErrorText(error: error)
            }
        }
    }
}

/// An error anywhere outside a card (a builder test, a settings page): the
/// explained cause and fix, with the raw message behind "Details".
struct ExplainedErrorView: View {
    let error: String
    var context: ErrorExplainer.Context = .refresh
    @State private var showsDetails = false

    var body: some View {
        let explanation = ErrorExplainer.explain(error, context: context)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Label {
                Text(explanation.cause)
            } icon: {
                Image(systemName: StatusTone.critical.symbol)
                    .foregroundStyle(StatusTone.critical.color)
            }
            .font(.caption.weight(.medium))
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(explanation.fix)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(showsDetails ? "Hide Details" : "Details") { showsDetails.toggle() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            if showsDetails {
                RawErrorText(error: error)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
            Pill(
                text: String(localized: "Cached"),
                symbol: "clock.arrow.circlepath",
                color: StatusTone.warning.color
            )
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
                    if explanation.kind == .permissionDenied {
                        PrivacySettingsButton()
                    }
                    Spacer()
                    Button("Retry") {
                        showsPopover = false
                        onRetry()
                    }
                    .buttonStyle(.glass(.primary))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Spacing.m)
            .frame(width: 280)
        }
    }
}

private struct PrivacySettingsButton: View {
    var body: some View {
        Button("Privacy Settings…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Permissions

/// A widget with new or changed permissions: what the widget is for, what it
/// wants in plain words, and the decision. Allow is the prominent choice;
/// Deny sits beside it.
///
/// One request or several, it is the same list, so the card reads the same
/// whatever the widget asks for. On the shelf it starts folded to one row
/// (what it asks for, in brief, and the decision), so a page of new widgets
/// still shows the ones already running; the chevron unfolds the full list.
///
/// Allow is not bound to Return: several cards can be waiting at once, and a
/// stray keystroke must never grant a widget access.
struct PermissionApprovalView: View {
    let widgetName: String
    /// What the widget does, one sentence.
    var summary: String?
    let requests: [PermissionRequest]
    /// Starts folded to one row; the shelf's cards do.
    var startsCollapsed = false
    let onAllow: () -> Void
    let onDeny: () -> Void
    @State private var expanded: Bool?

    private var isExpanded: Bool { expanded ?? !startsCollapsed }

    var body: some View {
        Group {
            if isExpanded { full } else { folded }
        }
        // The widget's card is the surface; a box of its own here would be
        // a box inside a box.
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(widgetName) needs your permission to run."))
    }

    /// The folded row's brief: the first thing asked for, and how many
    /// more, so one phrase never stands for the whole request.
    static func briefParts(_ requests: [PermissionRequest]) -> (first: String, more: Int) {
        let phrases = requests.flatMap { $0.description.split(separator: "\n").map(String.init) }
        return (phrases.first ?? "", max(phrases.count - 1, 0))
    }

    static func moreLabel(_ count: Int) -> String {
        String(localized: "+\(count) more", comment: "Folded permission card: how many more things it asks for")
    }

    /// The brief as one string (VoiceOver, tests).
    static func brief(_ requests: [PermissionRequest]) -> String {
        let parts = briefParts(requests)
        return parts.more > 0 ? parts.first + " " + moreLabel(parts.more) : parts.first
    }

    private var folded: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.xs) {
                heading(subtitle: Self.briefParts(requests).first, more: Self.briefParts(requests).more, truncates: true)
                PermissionDecisionButtons(onDeny: onDeny, onAllow: onAllow)
            }
            // A half-width card: the decision under the heading.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                heading(subtitle: Self.briefParts(requests).first, more: Self.briefParts(requests).more)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PermissionDecisionButtons(onDeny: onDeny, onAllow: onAllow)
                }
            }
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            heading(subtitle: summary)
            PermissionList(requests: requests)
                .padding(.leading, PermissionWaiting.badgeSize + Spacing.xs)
            // The decision sits on its own row, so the reason above keeps
            // the card's full width. Deliberately no `.defaultAction`: see
            // the type's note.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                PermissionDecisionButtons(onDeny: onDeny, onAllow: onAllow)
            }
        }
    }

    /// - Parameter truncates: the folded row's brief gives way to the
    ///   buttons beside it instead of pushing them under the heading.
    private func heading(subtitle: String?, more: Int = 0, truncates: Bool = false) -> some View {
        HStack(alignment: .center, spacing: Spacing.xs) {
            PermissionWaitingBadge()
            VStack(alignment: .leading, spacing: Spacing.hair) {
                // Folded, the row shares its width with the decision: a
                // shorter title keeps it on one line at the popup's width.
                Text(isExpanded ? PermissionWaiting.title : PermissionWaiting.shortTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(truncates ? 1 : 2)
                if let subtitle, !subtitle.isEmpty {
                    HStack(spacing: Spacing.xxs) {
                        Text(subtitle)
                            .lineLimit(isExpanded ? 3 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            // A small ideal width, so `ViewThatFits` judges the
                            // row by the title and buttons, not the full brief.
                            .frame(idealWidth: truncates ? 40 : nil, maxWidth: truncates ? .infinity : nil, alignment: .leading)
                        if more > 0 {
                            // Never truncated: the phrase gives way first.
                            Text(Self.moreLabel(more))
                                .fixedSize()
                                .layoutPriority(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if startsCollapsed {
                Button {
                    expanded = !isExpanded
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.icon)
                .help(isExpanded ? String(localized: "Show less") : String(localized: "Show what it asks for"))
                .accessibilityLabel(isExpanded ? Text("Show less") : Text("Show what \(widgetName) asks for"))
            }
        }
    }
}

/// The lock in a soft disc: a widget waiting for a decision.
struct PermissionWaitingBadge: View {
    var body: some View {
        Image(systemName: PermissionWaiting.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PermissionWaiting.tone.color)
            .frame(width: PermissionWaiting.badgeSize, height: PermissionWaiting.badgeSize)
            .background(Circle().fill(PermissionWaiting.tone.color.opacity(Fill.Wash.strong)))
            .accessibilityHidden(true)
    }
}

/// One row per requested capability, icon first, and the exact commands
/// behind "Details" when there are any.
struct PermissionList: View {
    let requests: [PermissionRequest]
    @State private var showsDetails = false

    var body: some View {
        let details = requests.flatMap(\.details)
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
            if !details.isEmpty {
                Button(showsDetails ? "Hide Details" : "Details") { showsDetails.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("The exact commands this widget may run")
                if showsDetails {
                    ScrollView {
                        RawErrorText(error: details.joined(separator: "\n\n"))
                    }
                    .frame(maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The user said no: a quiet, compact card that keeps the way back (review
/// and allow) and the way out (remove the widget) one click away.
struct PermissionDeniedView: View {
    let widgetName: String
    var summary: String?
    let requests: [PermissionRequest]
    let onAllow: () -> Void
    let onRemove: () -> Void
    @State private var reviewing = false

    var body: some View {
        if reviewing {
            PermissionApprovalView(
                widgetName: widgetName,
                summary: summary,
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
                        .buttonStyle(.glass(.secondary))
                    Button("Remove Widget…", role: .destructive, action: onRemove)
                        .buttonStyle(.glass(.destructive))
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

/// A script widget that kept crashing and was stopped: what happened, what
/// to try, and the supervisor's own reason behind "Details".
struct CrashDisabledView: View {
    let reason: String
    let onRestart: () -> Void
    let onOpenLogs: () -> Void
    @State private var showsDetails = false

    /// The fix line: the explainer's when it recognises the reason (a
    /// missing command, a timeout), otherwise the crash's own advice.
    static func fix(for reason: String) -> String {
        let explanation = ErrorExplainer.explain(reason)
        guard explanation.kind != .generic else {
            return String(localized: "Open Logs to see what went wrong, then restart it. If it keeps crashing, check for a widget update.")
        }
        return explanation.fix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            StatusBanner(
                tone: .critical,
                message: String(localized: "This widget stopped after crashing several times.")
            )
            Text(Self.fix(for: reason))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.xs) {
                Button("Restart Widget", action: onRestart)
                    .buttonStyle(.glass(.primary))
                Button("Open Logs", action: onOpenLogs)
                    .buttonStyle(.glass(.secondary))
                Button(showsDetails ? "Hide Details" : "Details") { showsDetails.toggle() }
                    .buttonStyle(.glass(.secondary))
            }
            .controlSize(.small)
            if showsDetails {
                RawErrorText(error: reason)
            }
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
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .monospacedDigit()
    }
}
