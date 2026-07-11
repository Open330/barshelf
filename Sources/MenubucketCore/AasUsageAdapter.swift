import Foundation

/// Builtin adapter for `aas usage --json` (`output = "data"`, adapter = "aas-usage").
///
/// Lives in MenubucketCore (Foundation-only) so its output structure is unit-testable.
/// Transforms the aas payload into a UINode tree:
/// - header: "aas" title + worst-remaining summary
/// - one section per provider; account cards (provider glyph + name + plan chips),
///   meter rows (label + health-colored linear progress + reset ETA), account
///   errors as danger captions
/// - footer: Refresh button (action: refresh)
public enum AasUsageAdapter {
    public static let name = "aas-usage"

    // MARK: - Payload schema

    public struct Payload: Codable, Equatable {
        public var accounts: [Account]

        public init(accounts: [Account]) {
            self.accounts = accounts
        }
    }

    public struct Account: Codable, Equatable {
        public var provider: String?
        public var name: String?
        public var email: String?
        public var active: Bool?
        public var plan: String?
        public var planLabel: String?
        public var headline: String?
        public var error: String?
        public var meters: [Meter]?

        public init(
            provider: String? = nil,
            name: String? = nil,
            email: String? = nil,
            active: Bool? = nil,
            plan: String? = nil,
            planLabel: String? = nil,
            headline: String? = nil,
            error: String? = nil,
            meters: [Meter]? = nil
        ) {
            self.provider = provider
            self.name = name
            self.email = email
            self.active = active
            self.plan = plan
            self.planLabel = planLabel
            self.headline = headline
            self.error = error
            self.meters = meters
        }
    }

    public struct Meter: Codable, Equatable {
        public var label: String?
        /// 0...100
        public var usedPct: Double?
        public var resetMs: Double?

        public init(label: String? = nil, usedPct: Double? = nil, resetMs: Double? = nil) {
            self.label = label
            self.usedPct = usedPct
            self.resetMs = resetMs
        }
    }

    // MARK: - Adapter

    /// M1 registry entry point: `(Data, AdapterContext) async throws -> AdapterResult`.
    /// aas needs no extra execs or deadline — it wraps the pure transform.
    public static func adapt(_ data: Data, context: AdapterContext) async throws -> AdapterResult {
        let tree = adapt(data)
        let statusText = (try? JSONDecoder().decode(Payload.self, from: data))
            .flatMap(worstRemaining(in:))
            .map { String(format: "%.0f%%", $0) }
        return AdapterResult(viewTree: tree, nextRefreshAtMs: nil, statusText: statusText)
    }

    /// Pure transform: `(Data) -> UINode`. Never throws — parse failures
    /// produce a danger banner node so the failure is visible in-place.
    public static func adapt(_ data: Data) -> UINode {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            return UINode(
                id: "aas-parse-error",
                type: "banner",
                text: "aas output could not be parsed: \(error.localizedDescription)",
                tone: "danger"
            )
        }
        return buildTree(from: payload)
    }

    public static func buildTree(from payload: Payload) -> UINode {
        var children: [UINode] = [header(for: payload)]

        if payload.accounts.isEmpty {
            children.append(UINode(
                id: "aas-empty",
                type: "empty",
                title: "No accounts",
                subtitle: "Run `aas login` to add an account.",
                icon: "person.crop.circle.badge.questionmark"
            ))
        } else {
            for (provider, accounts) in groupedByProvider(payload.accounts) {
                children.append(section(provider: provider, accounts: accounts))
            }
        }

        children.append(UINode(id: "aas-footer-divider", type: "divider"))
        children.append(UINode(
            id: "aas-refresh",
            type: "button",
            title: "Refresh",
            icon: "arrow.clockwise",
            action: NodeAction(type: "refresh")
        ))

        return UINode(id: "aas-root", type: "vstack", children: children, spacing: 8)
    }

    // MARK: - Pieces

    static func header(for payload: Payload) -> UINode {
        var items: [UINode] = [
            UINode(id: "aas-title", type: "text", text: "aas", role: "title"),
            UINode(id: "aas-header-spacer", type: "spacer"),
        ]
        if let worst = worstRemaining(in: payload) {
            items.append(UINode(
                id: "aas-summary",
                type: "text",
                text: String(format: "%.0f%% left", worst),
                role: "caption",
                monospacedDigit: true,
                foreground: severity(remainingPct: worst)
            ))
        }
        return UINode(id: "aas-header", type: "hstack", children: items, spacing: 6)
    }

    static func section(provider: String, accounts: [Account]) -> UINode {
        var rows: [UINode] = []
        for (index, account) in accounts.enumerated() {
            let key = accountKey(provider: provider, account: account, index: index)
            rows.append(accountCard(provider: provider, account: account, key: key))
        }
        return UINode(
            id: "aas-section-\(provider)",
            type: "section",
            children: rows,
            spacing: 6,
            title: providerTitle(provider)
        )
    }

    static func accountCard(provider: String, account: Account, key: String) -> UINode {
        var children: [UINode] = [accountHeader(provider: provider, account: account, key: key)]
        if let headline = account.headline, !headline.isEmpty {
            children.append(UINode(
                id: "\(key)-headline",
                type: "text",
                text: headline,
                role: "caption",
                lineLimit: 1,
                foreground: accountSeverity(account)
            ))
        }
        if let error = account.error, !error.isEmpty {
            children.append(UINode(
                id: "\(key)-error",
                type: "banner",
                text: error,
                tone: "danger",
                icon: "exclamationmark.triangle.fill"
            ))
        }
        children.append(contentsOf: meterGrid(meters: account.meters ?? [], key: key))
        if (account.meters ?? []).isEmpty, account.error?.isEmpty != false {
            children.append(UINode(
                id: "\(key)-no-meters",
                type: "text",
                text: "No usage meters reported",
                role: "caption",
                foreground: "secondary"
            ))
        }
        return UINode(
            id: "\(key)-card",
            type: "card",
            children: children,
            spacing: 6,
            tone: accountSeverity(account),
            widthFill: true
        )
    }

    static func accountHeader(provider: String, account: Account, key: String) -> UINode {
        var titleStack: [UINode] = [
            UINode(
                id: "\(key)-name",
                type: "text",
                text: account.name ?? account.email ?? "unknown",
                role: "body",
                lineLimit: 1
            )
        ]
        if let email = account.email, !email.isEmpty, email != account.name {
            titleStack.append(UINode(
                id: "\(key)-email",
                type: "text",
                text: email,
                role: "caption",
                lineLimit: 1,
                foreground: "secondary"
            ))
        }

        var items: [UINode] = [
            UINode(
                id: "\(key)-provider-icon",
                type: "image",
                source: ImageSource(kind: "sfSymbol", name: providerSymbol(provider)),
                size: 16,
                tint: providerTint(provider),
                accessibilityLabel: providerTitle(provider)
            ),
            UINode(
                id: "\(key)-identity",
                type: "vstack",
                children: titleStack,
                spacing: 1
            ),
            UINode(id: "\(key)-row-spacer", type: "spacer"),
        ]
        if account.active == true {
            items.append(UINode(id: "\(key)-active", type: "badge", text: "ACTIVE", tint: "good"))
        }
        if let plan = formattedPlan(account), !plan.isEmpty {
            items.append(UINode(id: "\(key)-plan", type: "badge", text: plan, tint: planTone(account.plan)))
        }
        return UINode(id: "\(key)-header", type: "hstack", children: items, spacing: 7)
    }

    /// Meters laid out two per row (the aas windows come in pairs — 5h/7d),
    /// each cell a compact stat: window label, a large remaining-% figure
    /// with the actual time until the window resets beside it, and the
    /// health-colored bar underneath. A lone meter spans the full width.
    static func meterGrid(meters: [Meter], key: String) -> [UINode] {
        guard !meters.isEmpty else { return [] }
        var rows: [UINode] = []
        var index = 0
        var rowNumber = 0
        while index < meters.count {
            let pair = Array(meters[index..<min(index + 2, meters.count)])
            var cells: [UINode] = []
            for (offset, meter) in pair.enumerated() {
                cells.append(meterCell(meter: meter, key: "\(key)-meter-\(index + offset)"))
            }
            rows.append(UINode(
                id: "\(key)-meters-\(rowNumber)",
                type: "hstack",
                children: cells,
                spacing: 12,
                widthFill: true,
                alignment: "top"
            ))
            index += 2
            rowNumber += 1
        }
        return rows
    }

    static func meterCell(meter: Meter, key: String) -> UINode {
        let used = min(max(meter.usedPct ?? 0, 0), 100)
        let remaining = 100 - used
        let tint = severity(remainingPct: remaining)
        var figureRow: [UINode] = [
            UINode(
                id: "\(key)-pct",
                type: "text",
                text: String(format: "%.0f%%", remaining),
                role: "title",
                lineLimit: 1,
                monospacedDigit: true,
                size: 19,
                foreground: tint
            ),
        ]
        if let reset = remainingTime(untilMs: meter.resetMs) {
            figureRow.append(UINode(
                id: "\(key)-reset",
                type: "text",
                text: reset,
                role: "caption",
                lineLimit: 1,
                monospacedDigit: true,
                foreground: "secondary"
            ))
        }
        return UINode(
            id: key,
            type: "vstack",
            children: [
                UINode(
                    id: "\(key)-label",
                    type: "text",
                    text: "\(meter.label ?? "Usage") left",
                    role: "caption",
                    lineLimit: 1,
                    foreground: "secondary"
                ),
                UINode(
                    id: "\(key)-figure",
                    type: "hstack",
                    children: figureRow,
                    spacing: 6,
                    alignment: "baseline"
                ),
                UINode(
                    id: "\(key)-progress",
                    type: "progress",
                    tint: tint,
                    value: used / 100.0,
                    style: "linear"
                ),
            ],
            spacing: 2,
            widthFill: true
        )
    }

    // MARK: - Helpers

    /// remaining < 10 → danger, < 30 → warning, else good.
    public static func severity(remainingPct: Double) -> String {
        if remainingPct < 10 { return "danger" }
        if remainingPct < 30 { return "warning" }
        return "good"
    }

    static func accountSeverity(_ account: Account) -> String {
        if account.error?.isEmpty == false { return "danger" }
        let remainings = (account.meters ?? [])
            .compactMap(\.usedPct)
            .map { 100 - min(max($0, 0), 100) }
        guard let worst = remainings.min() else { return "neutral" }
        return severity(remainingPct: worst)
    }

    static func worstRemaining(in payload: Payload) -> Double? {
        let remainings = payload.accounts
            .flatMap { $0.meters ?? [] }
            .compactMap { $0.usedPct }
            .map { 100 - min(max($0, 0), 100) }
        return remainings.min()
    }

    /// Groups accounts by provider, preserving first-appearance order.
    static func groupedByProvider(_ accounts: [Account]) -> [(String, [Account])] {
        var order: [String] = []
        var buckets: [String: [Account]] = [:]
        for account in accounts {
            let provider = account.provider ?? "other"
            if buckets[provider] == nil {
                order.append(provider)
            }
            buckets[provider, default: []].append(account)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    static func accountKey(provider: String, account: Account, index: Int) -> String {
        let raw = "\(provider)-\(account.name ?? account.email ?? "unknown")-\(index)"
        let safe = raw.map { char -> Character in
            char.isLetter || char.isNumber || char == "-" || char == "_" || char == "."
                ? char : "-"
        }
        return "aas-\(String(safe))"
    }

    static func providerTitle(_ provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic": return "Claude"
        case "openai": return "OpenAI"
        case "google": return "Google"
        case "xai": return "xAI"
        default:
            return provider.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    static func providerSymbol(_ provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic": return "sparkles"
        case "openai": return "circle.hexagongrid.fill"
        case "google": return "g.circle.fill"
        case "xai": return "xmark.circle.fill"
        default: return "cpu.fill"
        }
    }

    static func providerTint(_ provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic": return "warning"
        case "openai": return "good"
        case "google": return "accent"
        case "xai": return "primary"
        default: return "secondary"
        }
    }

    static func formattedPlan(_ account: Account) -> String? {
        let raw = (account.planLabel ?? account.plan)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        let normalizedPlan = account.plan?.lowercased()
        if normalizedPlan == "max" {
            let suffix = raw
                .replacingOccurrences(of: "max", with: "", options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? "MAX" : "MAX · \(suffix)"
        }
        return raw.uppercased()
    }

    static func planTone(_ plan: String?) -> String {
        switch plan?.lowercased() {
        case "max": return "accent"
        case "pro": return "neutral"
        case "team", "enterprise": return "good"
        default: return "neutral"
        }
    }

    /// Precise time until a window reset — "42m", "2h 10m", "3d 9h" — so the
    /// meter can show the actual wait next to the remaining percentage.
    /// Zero minor components collapse ("2h", "3d"); past timestamps → "due".
    static func remainingTime(untilMs ms: Double?, now: Date = Date()) -> String? {
        guard let ms else { return nil }
        let reset = Date(timeIntervalSince1970: ms / 1000.0)
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return "due" }
        let totalMinutes = max(Int((seconds / 60).rounded(.up)), 1)
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let totalHours = totalMinutes / 60
        if totalHours < 48 {
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(totalHours)h" : "\(totalHours)h \(minutes)m"
        }
        let days = totalHours / 24
        let hours = totalHours % 24
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }
}
