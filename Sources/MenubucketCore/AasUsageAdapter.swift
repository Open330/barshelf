import Foundation

/// Builtin adapter for `aas usage --json` (`output = "data"`, adapter = "aas-usage").
///
/// Lives in MenubucketCore (Foundation-only) so its output structure is unit-testable.
/// Transforms the aas payload into a UINode tree:
/// - header: "aas" title + worst-remaining summary
/// - one section per provider; account rows (active dot + name + plan badge),
///   meter rows (label + linear progress + percent), account errors as danger captions
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
                text: String(format: "worst: %.0f%% left", worst),
                role: "caption",
                monospacedDigit: true,
                foreground: severity(remainingPct: worst)
            ))
        }
        return UINode(id: "aas-header", type: "hstack", children: items, spacing: 6)
    }

    static func section(provider: String, accounts: [Account]) -> UINode {
        var rows: [UINode] = []
        for account in accounts {
            let key = accountKey(provider: provider, account: account)
            rows.append(accountRow(account: account, key: key))
            if let headline = account.headline, !headline.isEmpty {
                rows.append(UINode(
                    id: "\(key)-headline",
                    type: "text",
                    text: headline,
                    role: "caption",
                    lineLimit: 1
                ))
            }
            if let error = account.error, !error.isEmpty {
                rows.append(UINode(
                    id: "\(key)-error",
                    type: "text",
                    text: error,
                    role: "caption",
                    lineLimit: 2,
                    foreground: "danger"
                ))
            }
            for (index, meter) in (account.meters ?? []).enumerated() {
                rows.append(meterRow(meter: meter, key: "\(key)-meter-\(index)"))
            }
        }
        return UINode(
            id: "aas-section-\(provider)",
            type: "section",
            children: rows,
            spacing: 4,
            title: provider
        )
    }

    static func accountRow(account: Account, key: String) -> UINode {
        var items: [UINode] = [
            UINode(
                id: "\(key)-dot",
                type: "image",
                source: ImageSource(kind: "sfSymbol", name: "circle.fill"),
                size: 7,
                tint: (account.active ?? false) ? "good" : "neutral"
            ),
            UINode(
                id: "\(key)-name",
                type: "text",
                text: account.name ?? account.email ?? "unknown",
                role: "body",
                lineLimit: 1
            ),
            UINode(id: "\(key)-row-spacer", type: "spacer"),
        ]
        if let plan = account.planLabel ?? account.plan, !plan.isEmpty {
            items.append(UINode(id: "\(key)-plan", type: "badge", text: plan, tint: "accent"))
        }
        return UINode(id: "\(key)-row", type: "hstack", children: items, spacing: 6)
    }

    static func meterRow(meter: Meter, key: String) -> UINode {
        let used = min(max(meter.usedPct ?? 0, 0), 100)
        let remaining = 100 - used
        return UINode(
            id: key,
            type: "hstack",
            children: [
                UINode(
                    id: "\(key)-progress",
                    type: "progress",
                    tint: severity(remainingPct: remaining),
                    value: used / 100.0,
                    label: meter.label
                ),
                UINode(
                    id: "\(key)-pct",
                    type: "text",
                    text: String(format: "%.0f%%", used),
                    role: "caption",
                    monospacedDigit: true
                ),
            ],
            spacing: 6
        )
    }

    // MARK: - Helpers

    /// remaining < 10 → danger, < 30 → warning, else good.
    public static func severity(remainingPct: Double) -> String {
        if remainingPct < 10 { return "danger" }
        if remainingPct < 30 { return "warning" }
        return "good"
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

    static func accountKey(provider: String, account: Account) -> String {
        "aas-\(provider)-\(account.name ?? account.email ?? "unknown")"
    }
}
