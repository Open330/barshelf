import Foundation

/// Builtin adapter for otpeek (`output = "data"`, adapter = "otpeek").
///
/// Source: `otpeek list --json` (sensitive — contains secrets; never logged
/// or cached to disk). The adapter filters TOTP accounts and runs
/// `otpeek code <id> --json` for each in parallel (allowlisted as
/// `["code", "*", "--json"]`), producing one row per account:
/// issuer/accountName + countdown ring + grouped code with a copyText action
/// that auto-clears the clipboard after 30 s.
///
/// `nextRefreshAtMs = min(validUntil) + 250` — the host's deadline trigger
/// re-runs the pipeline right after the earliest code rolls over.
public enum OtpeekAdapter {
    public static let name = "otpeek"

    public static let clipboardClearSeconds = 30
    static let deadlineSlackMs: Double = 250

    /// Keychain guidance shown when otpeek rejects the vault password.
    public static let keychainSetupHint = """
    Store the vault password in the Keychain so BarShelf can unlock otpeek:
    security add-generic-password -s dev.barshelf -a otpeek-vault-password -w
    """

    // MARK: - Payload schemas (otpeek CLI, camelCase JSON)

    /// One entry of `otpeek list --json` (extra fields like `secret` are
    /// intentionally not modeled — they must never leave the decode step).
    public struct Account: Codable, Equatable {
        public var id: String
        /// "totp" | "hotp"
        public var type: String?
        public var issuer: String?
        public var accountName: String?
        public var folderId: String?
        public var isFavorite: Bool?
        public var deletedAt: Double?

        public init(
            id: String,
            type: String? = nil,
            issuer: String? = nil,
            accountName: String? = nil,
            folderId: String? = nil,
            isFavorite: Bool? = nil,
            deletedAt: Double? = nil
        ) {
            self.id = id
            self.type = type
            self.issuer = issuer
            self.accountName = accountName
            self.folderId = folderId
            self.isFavorite = isFavorite
            self.deletedAt = deletedAt
        }
    }

    /// Output of `otpeek code <id> --json`.
    public struct Code: Codable, Equatable {
        public var code: String
        /// Epoch ms.
        public var validFrom: Double
        /// Epoch ms.
        public var validUntil: Double

        public init(code: String, validFrom: Double, validUntil: Double) {
            self.code = code
            self.validFrom = validFrom
            self.validUntil = validUntil
        }
    }
}

extension OtpeekAdapter.Account: Sendable {}
extension OtpeekAdapter.Code: Sendable {}

extension OtpeekAdapter {

    // MARK: - Adapter entry point


    public static func adapt(_ data: Data, context: AdapterContext) async throws -> AdapterResult {
        let folder = context.settings["folder"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let favoritesOnly = context.settings["favoritesOnly"]?.boolValue ?? false
        let favoritesFirst = context.settings["favoritesFirst"]?.boolValue ?? false
        let showIcons = context.settings["showIcons"]?.boolValue ?? true
        let accountData: Data
        if folder.isEmpty {
            accountData = data
        } else {
            accountData = try await context.runAllowed(
                command: ["otpeek", "list", "--folder", folder, "--json"]
            )
        }

        let accounts: [Account]
        do {
            accounts = try JSONDecoder().decode([Account].self, from: accountData)
        } catch {
            throw AdapterError.invalidPayload(
                "otpeek list output could not be parsed: \(error.localizedDescription)"
            )
        }

        var totpAccounts = accounts.filter {
            ($0.type ?? "totp").lowercased() == "totp" && $0.deletedAt == nil
        }
        if favoritesOnly {
            totpAccounts.removeAll { $0.isFavorite != true }
        }
        if favoritesFirst {
            totpAccounts = totpAccounts.enumerated().sorted { lhs, rhs in
                let lhsFavorite = lhs.element.isFavorite == true
                let rhsFavorite = rhs.element.isFavorite == true
                if lhsFavorite != rhsFavorite { return lhsFavorite && !rhsFavorite }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        guard !totpAccounts.isEmpty else {
            return AdapterResult(viewTree: emptyTree(filtered: favoritesOnly || !folder.isEmpty))
        }

        // Fetch codes in parallel, preserving account order.
        var outcomes: [Result<Code, Error>?] = Array(repeating: nil, count: totpAccounts.count)
        await withTaskGroup(of: (Int, Result<Code, Error>).self) { group in
            for (index, account) in totpAccounts.enumerated() {
                group.addTask {
                    do {
                        let output = try await context.runAllowed(
                            command: ["otpeek", "code", account.id, "--json"]
                        )
                        let code = try JSONDecoder().decode(Code.self, from: output)
                        return (index, .success(code))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for await (index, outcome) in group {
                outcomes[index] = outcome
            }
        }

        // Vault password failures affect every account identically — surface
        // one actionable error card instead of N cryptic rows.
        let failures = outcomes.compactMap { outcome -> Error? in
            if case let .failure(error) = outcome { return error }
            return nil
        }
        if failures.count == totpAccounts.count,
           let first = failures.first,
           looksLikePasswordError(first) {
            throw AdapterError.message(
                "otpeek could not unlock the vault: \(errorText(first))\n\(keychainSetupHint)"
            )
        }

        var rows: [UINode] = []
        var earliestValidUntil: Double?
        for (index, account) in totpAccounts.enumerated() {
            switch outcomes[index] {
            case let .success(code):
                rows.append(accountRow(account: account, code: code, showIcon: showIcons))
                earliestValidUntil = min(earliestValidUntil ?? .infinity, code.validUntil)
            case let .failure(error):
                rows.append(errorRow(account: account, message: errorText(error), showIcon: showIcons))
            case nil:
                rows.append(errorRow(account: account, message: "no result", showIcon: showIcons))
            }
        }

        return AdapterResult(
            viewTree: UINode(
                id: "otpeek-root",
                type: "list",
                items: rows,
                spacing: 8,
                searchPlaceholder: "Search accounts…"
            ),
            nextRefreshAtMs: earliestValidUntil.map { $0 + deadlineSlackMs },
            statusText: nil // codes are sensitive — never promote to the menu bar
        )
    }

    // MARK: - Tree pieces

    static func accountRow(account: Account, code: Code, showIcon: Bool = true) -> UINode {
        let key = "otp-\(account.id)"
        var children: [UINode] = []
        if showIcon {
            children.append(iconNode(account: account, key: key))
        }
        children.append(identityColumn(account: account, key: key))
        if let favorite = favoriteIndicator(account: account, key: key) {
            children.append(favorite)
        }
        children.append(contentsOf: [
            UINode(id: "\(key)-spacer", type: "spacer"),
            UINode(
                id: "\(key)-code",
                type: "button",
                title: groupedCode(code.code),
                action: NodeAction(
                    type: "copyText",
                    value: code.code,
                    toast: "Copied — clears in \(clipboardClearSeconds)s",
                    clearAfterSec: clipboardClearSeconds
                )
            ),
            UINode(
                id: "\(key)-ring",
                type: "progress",
                size: 26,
                tint: "accent",
                style: "ring",
                countdown: UINode.Countdown(from: code.validFrom, until: code.validUntil),
                labelFrom: "remainingSeconds",
                tintRules: [UINode.TintRule(whenRemainingLtSeconds: 10, tint: "danger")]
            ),
        ])
        return UINode(
            id: "\(key)-row",
            type: "hstack",
            children: children,
            spacing: 8
        )
    }

    static func errorRow(account: Account, message: String, showIcon: Bool = true) -> UINode {
        let key = "otp-\(account.id)"
        var children: [UINode] = []
        if showIcon {
            children.append(iconNode(account: account, key: key))
        }
        children.append(identityColumn(account: account, key: key))
        if let favorite = favoriteIndicator(account: account, key: key) {
            children.append(favorite)
        }
        children.append(contentsOf: [
            UINode(id: "\(key)-spacer", type: "spacer"),
            UINode(
                id: "\(key)-error",
                type: "text",
                text: message,
                role: "caption",
                lineLimit: 2,
                foreground: "danger"
            ),
        ])
        return UINode(
            id: "\(key)-row",
            type: "hstack",
            children: children,
            spacing: 8
        )
    }

    static let iconPointSize: Double = 20

    /// Leading service icon: a favicon when the issuer maps to a website
    /// domain we're confident about, otherwise an initial-letter monogram.
    /// The favicon URL is fetched by the host renderer (gated on the widget's
    /// `permissions.network` allowlist) with the monogram as its fallback, so
    /// a blocked or failed load degrades to the same letter tile.
    static func iconNode(account: Account, key: String) -> UINode {
        let display = displayName(account: account)
        let monogram = String(display.prefix(1)).uppercased()
        let source: ImageSource
        if let domain = faviconDomain(for: account) {
            source = ImageSource(
                kind: "url",
                url: faviconURL(domain: domain),
                monogram: monogram
            )
        } else {
            source = ImageSource(kind: "monogram", monogram: monogram)
        }
        return UINode(
            id: "\(key)-icon",
            type: "image",
            source: source,
            size: iconPointSize,
            accessibilityLabel: display
        )
    }

    static func displayName(account: Account) -> String {
        let issuer = account.issuer?.trimmingCharacters(in: .whitespaces) ?? ""
        if !issuer.isEmpty { return issuer }
        let name = account.accountName ?? ""
        return name.isEmpty ? "?" : name
    }

    static func faviconURL(domain: String) -> String {
        let encoded = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain
        return "https://www.google.com/s2/favicons?domain=\(encoded)&sz=64"
    }

    /// Maps an account to its most plausible website domain (favicon lookup),
    /// ported from otpeek's own favicon resolver. Only "confident" matches are
    /// returned — known mapping, domain-looking issuer, or a non-generic email
    /// host. Bare single-word guesses (`{issuer}.com`) are skipped because the
    /// favicon service returns a misleading globe for unknown domains; those
    /// accounts keep the monogram.
    static func faviconDomain(for account: Account) -> String? {
        let issuer = (account.issuer ?? "").trimmingCharacters(in: .whitespaces)
        for source in [issuer, account.accountName ?? ""] {
            let lower = source.lowercased()
            guard !lower.isEmpty else { continue }
            for (key, domain) in knownDomains where lower.contains(key) { return domain }
            // Already looks like a domain ("pixiv.net").
            if !lower.contains(" "), lower.contains("."), !lower.contains("@") { return lower }
            // Email account name → use its host unless it's a generic mail host.
            if let at = lower.firstIndex(of: "@") {
                let host = String(lower[lower.index(after: at)...])
                if !host.isEmpty, !genericMailHosts.contains(host) { return host }
            }
        }
        return nil
    }

    /// Known services whose display name doesn't map cleanly to a domain.
    /// Substring match (contains), so **more specific keys come first** —
    /// "amazon web services" must win over "amazon" (ordered array, not a
    /// Dictionary, for deterministic matching).
    static let knownDomains: [(String, String)] = [
        ("amazon web services", "aws.amazon.com"),
        ("aws", "aws.amazon.com"),
        ("visit japan web", "vjw-lp.digital.go.jp"),
        ("electronic arts", "ea.com"),
        ("google", "google.com"), ("github", "github.com"), ("gitlab", "gitlab.com"),
        ("amazon", "amazon.com"),
        ("cloudflare", "cloudflare.com"), ("discord", "discord.com"),
        ("facebook", "facebook.com"), ("twitter", "x.com"), ("linkedin", "linkedin.com"),
        ("notion", "notion.so"), ("bitwarden", "bitwarden.com"), ("tumblr", "tumblr.com"),
        ("pixiv", "pixiv.net"), ("nvidia", "nvidia.com"), ("mathworks", "mathworks.com"),
        ("mailgun", "mailgun.com"), ("proxmox", "proxmox.com"),
        ("plaync", "plaync.com"), ("bithumb", "bithumb.com"), ("coinrail", "coinrail.co.kr"),
        ("coinnest", "coinnest.co.kr"), ("coinlink", "coinlink.co.kr"),
        ("miningpoolhub", "miningpoolhub.com"), ("pypi", "pypi.org"),
        ("microsoft", "microsoft.com"), ("apple", "apple.com"),
        ("dropbox", "dropbox.com"), ("slack", "slack.com"),
        ("steam", "steampowered.com"), ("reddit", "reddit.com"),
        ("paypal", "paypal.com"), ("instagram", "instagram.com"), ("binance", "binance.com"),
        ("coinbase", "coinbase.com"), ("upbit", "upbit.com"),
    ]

    static let genericMailHosts: Set<String> = [
        "gmail.com", "googlemail.com", "naver.com", "outlook.com", "hotmail.com",
        "yahoo.com", "icloud.com", "me.com", "proton.me", "protonmail.com",
    ]

    /// A compact, non-interactive marker keeps favorites recognizable without
    /// adding an empty-star column to every account row.
    static func favoriteIndicator(account: Account, key: String) -> UINode? {
        guard account.isFavorite == true else { return nil }
        return UINode(
            id: "\(key)-favorite",
            type: "image",
            source: ImageSource(kind: "sfSymbol", name: "star.fill"),
            size: 11,
            tint: "warning",
            accessibilityLabel: "Favorite"
        )
    }

    static func identityColumn(account: Account, key: String) -> UINode {
        var lines: [UINode] = []
        let issuer = account.issuer?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = account.accountName ?? ""
        lines.append(UINode(
            id: "\(key)-issuer",
            type: "text",
            text: issuer.isEmpty ? (name.isEmpty ? "unknown" : name) : issuer,
            role: "body",
            lineLimit: 1
        ))
        if !issuer.isEmpty, !name.isEmpty {
            lines.append(UINode(
                id: "\(key)-name",
                type: "text",
                text: name,
                role: "caption",
                lineLimit: 1
            ))
        }
        return UINode(id: "\(key)-identity", type: "vstack", children: lines, spacing: 1)
    }

    static func emptyTree(filtered: Bool = false) -> UINode {
        UINode(
            id: "otpeek-empty",
            type: "empty",
            title: filtered ? "No matching accounts" : "No TOTP accounts",
            subtitle: filtered ? "Adjust the OTP widget filters." : "Add one with `otpeek add`.",
            icon: "key.slash"
        )
    }

    // MARK: - Helpers

    /// "728419" → "728 419", "12345678" → "1234 5678". Codes of 4 digits or
    /// fewer stay as-is; multiples of 3 group by 3, otherwise split in half.
    public static func groupedCode(_ code: String) -> String {
        let characters = Array(code)
        guard characters.count > 4 else { return code }
        var groups: [String] = []
        if characters.count % 3 == 0 {
            for start in stride(from: 0, to: characters.count, by: 3) {
                groups.append(String(characters[start..<start + 3]))
            }
        } else {
            let half = (characters.count + 1) / 2
            groups = [String(characters[0..<half]), String(characters[half...])]
        }
        return groups.joined(separator: " ")
    }

    static func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    static func looksLikePasswordError(_ error: Error) -> Bool {
        errorText(error).lowercased().contains("password")
    }
}
