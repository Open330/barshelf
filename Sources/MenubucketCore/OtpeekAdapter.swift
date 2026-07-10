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
        public var deletedAt: Double?

        public init(
            id: String,
            type: String? = nil,
            issuer: String? = nil,
            accountName: String? = nil,
            deletedAt: Double? = nil
        ) {
            self.id = id
            self.type = type
            self.issuer = issuer
            self.accountName = accountName
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
        let accounts: [Account]
        do {
            accounts = try JSONDecoder().decode([Account].self, from: data)
        } catch {
            throw AdapterError.invalidPayload(
                "otpeek list output could not be parsed: \(error.localizedDescription)"
            )
        }

        let totpAccounts = accounts.filter {
            ($0.type ?? "totp").lowercased() == "totp" && $0.deletedAt == nil
        }
        guard !totpAccounts.isEmpty else {
            return AdapterResult(viewTree: emptyTree())
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
                rows.append(accountRow(account: account, code: code))
                earliestValidUntil = min(earliestValidUntil ?? .infinity, code.validUntil)
            case let .failure(error):
                rows.append(errorRow(account: account, message: errorText(error)))
            case nil:
                rows.append(errorRow(account: account, message: "no result"))
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

    static func accountRow(account: Account, code: Code) -> UINode {
        let key = "otp-\(account.id)"
        return UINode(
            id: "\(key)-row",
            type: "hstack",
            children: [
                identityColumn(account: account, key: key),
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
            ],
            spacing: 8
        )
    }

    static func errorRow(account: Account, message: String) -> UINode {
        let key = "otp-\(account.id)"
        return UINode(
            id: "\(key)-row",
            type: "hstack",
            children: [
                identityColumn(account: account, key: key),
                UINode(id: "\(key)-spacer", type: "spacer"),
                UINode(
                    id: "\(key)-error",
                    type: "text",
                    text: message,
                    role: "caption",
                    lineLimit: 2,
                    foreground: "danger"
                ),
            ],
            spacing: 8
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

    static func emptyTree() -> UINode {
        UINode(
            id: "otpeek-empty",
            type: "empty",
            title: "No TOTP accounts",
            subtitle: "Add one with `otpeek add`.",
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
