import AppKit
import Darwin
import Foundation
import MenubucketCore

// MARK: - Provider

/// What a vault widget may see of an item: never a secret.
struct VaultItem: Equatable, Sendable {
    let id: String
    let name: String
    let username: String?
    let host: String?
    let hasTOTP: Bool
}

enum VaultField: String, CaseIterable, Sendable {
    case username, password, totp
}

/// Why a vault operation failed, in words that can never carry provider
/// output (stderr can echo input; it is discarded, not shown).
enum VaultError: Error, Equatable, Sendable {
    case notInstalled
    case unlockFailed
    case locked
    case timedOut
    case tooLarge
    case failed
    /// BarShelf's own Bitwarden profile has no account yet: sign in once.
    case signedOut
    case signInFailed
    /// The account asks for a two-step login code.
    case twoFactorRequired

    var message: String {
        switch self {
        case .notInstalled: return String(localized: "The Bitwarden CLI (bw) isn't installed.")
        case .unlockFailed: return String(localized: "Couldn't unlock. Check the master password and that bw is logged in.")
        case .locked: return String(localized: "The vault is locked.")
        case .timedOut: return String(localized: "Bitwarden took too long to answer.")
        case .tooLarge: return String(localized: "The vault answer was too large to read.")
        case .failed: return String(localized: "Bitwarden couldn't do that.")
        case .signedOut: return String(localized: "Sign in to Bitwarden in BarShelf first.")
        case .signInFailed: return String(localized: "Couldn't sign in. Check the server, email, master password and code.")
        case .twoFactorRequired: return String(localized: "Bitwarden asks for a two-step login code.")
        }
    }
}

/// Whether BarShelf's own provider profile has an account signed in.
enum VaultAccount: String, Sendable {
    case signedIn, signedOut, unknown
}

/// What `bw status` says about BarShelf's profile. No secret in it.
struct VaultStatus: Equatable, Sendable {
    var account: VaultAccount
    var lastSync: String?
    var server: String?

    static let unknown = VaultStatus(account: .unknown)
}

/// What signing in needs. The password is passed on stdin, never argv.
struct VaultSignIn: Sendable {
    var server: String?
    var email: String
    var password: String
    /// Bitwarden's two-step method number (0 authenticator, 1 email, 3 YubiKey OTP).
    var method: Int?
    var code: String?
    /// A personal API key, for accounts Bitwarden asks to verify this new
    /// device by emailed code (which bw only takes interactively). Passed in
    /// the child's environment only; the password then unlocks.
    var clientID: String?
    var clientSecret: String?
}

/// A password manager BarShelf drives itself. The widget cannot choose its
/// commands: it can ask to unlock, list item metadata, copy one field of one
/// item, and lock. Swappable in tests. Calls honor task cancellation.
protocol VaultProvider: Sendable {
    func unlock(password: String) async throws -> String
    func items(session: String) async throws -> [VaultItem]
    func value(of field: VaultField, itemID: String, session: String) async throws -> String
    /// Locks the provider. Without a session it still locks: a cancelled
    /// unlock may have left the CLI unlocked without BarShelf seeing the key.
    func lock(session: String?) async
    /// Pulls the vault from the server into BarShelf's profile. Unlocking
    /// only decrypts the local copy, so it is done once per unlock.
    func sync(session: String) async throws
    /// Whether BarShelf's profile has an account (not whether it is
    /// unlocked), when it last synced and with which server.
    func status() async -> VaultStatus
    /// Signs BarShelf's profile in and returns the session it unlocks.
    func signIn(_ request: VaultSignIn) async throws -> String
    /// Server and email of the account the user's own CLI uses, to prefill
    /// sign-in. Never a secret.
    func suggestedAccount() async -> (server: String?, email: String?)
    /// Signs BarShelf's profile out. The user's own CLI profile is untouched.
    func signOut() async throws
}

/// The Bitwarden CLI, run directly (no shell), from a known install location
/// (not PATH or the widget's folder), with a minimal environment. The master
/// password goes through stdin (`--passwordfile /dev/stdin`), never argv or
/// the environment; the session through `BW_SESSION` to this child only.
///
/// Runs go through `ExecService.capture`, the same process control widget
/// commands use: the child gets its own process group, a timeout or
/// cancellation stops the group and anything still holding its pipes, and
/// reads are bounded by a deadline. stderr is dropped, never shown.
///
/// BarShelf uses its own CLI profile (`BITWARDENCLI_APPDATA_DIR`, in its
/// Application Support folder), signed in once from BarShelf. Bitwarden keeps
/// one session per profile, so with a shared profile every unlock or lock in
/// BarShelf invalidated the session a terminal was using; now neither side
/// touches the other.
/// BarShelf trusts the bw it finds (and, for npm installs, the node next to
/// it) as it trusts any software the user installed; a process already
/// running as the user can read its memory, which no app can prevent.
struct BitwardenCLIProvider: VaultProvider {
    static let maxOutputBytes = 16 << 20
    static let maxPasswordBytes = 1024

    /// Tests point this at a synthetic helper; nil means the vetted locations.
    var executableOverride: URL?
    /// BarShelf's own CLI profile. Created owner-only on first use.
    var dataDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/barshelf/bitwarden-cli", isDirectory: true)
    var timeout: TimeInterval = 30

    /// Where bw is installed by Homebrew, npm (global or nvm), volta or bun.
    static func executable(home: String = NSHomeDirectory()) -> URL? {
        var candidates = ["/opt/homebrew/bin/bw", "/usr/local/bin/bw",
                          home + "/.npm-global/bin/bw", home + "/.volta/bin/bw", home + "/.bun/bin/bw"]
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append("\(nvm)/\(version)/bin/bw")
            }
        }
        return candidates.lazy.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func unlock(password: String) async throws -> String {
        let input = Data((password + "\n").utf8)
        guard input.count <= Self.maxPasswordBytes else { throw VaultError.unlockFailed }
        let output = try await capture(["unlock", "--passwordfile", "/dev/stdin", "--raw"], stdin: input, session: nil)
        guard output.exitCode == 0 else {
            throw Self.mentions(output.stderr, "not logged in") ? VaultError.signedOut : VaultError.unlockFailed
        }
        return try Self.sessionKey(output.stdout, failure: .unlockFailed)
    }

    /// A large vault can take a while; longer than other calls.
    func sync(session: String) async throws {
        let output = try await capture(["sync"], stdin: nil, session: session, timeout: max(timeout, 120))
        guard output.exitCode == 0 else { throw VaultError.failed }
    }

    func status() async -> VaultStatus {
        guard let output = try? await capture(["status"], stdin: nil, session: nil), output.exitCode == 0,
              let object = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let status = object["status"] as? String
        else { return .unknown }
        return VaultStatus(account: status == "unauthenticated" ? .signedOut : .signedIn,
                           lastSync: object["lastSync"] as? String, server: object["serverUrl"] as? String)
    }

    func signIn(_ request: VaultSignIn) async throws -> String {
        let input = Data((request.password + "\n").utf8)
        guard input.count <= Self.maxPasswordBytes, !request.email.isEmpty, !request.email.hasPrefix("-") else {
            throw VaultError.signInFailed
        }
        // The profile is signed out here, which `config server` requires.
        // An empty field resets it to bitwarden.com, so a mistyped server
        // does not stick; anything else must be https.
        var server = "bitwarden.com"
        if let typed = request.server, !typed.isEmpty {
            guard let url = URL(string: typed), url.scheme == "https", url.host != nil else { throw VaultError.signInFailed }
            server = url.absoluteString
        }
        let config = try await capture(["config", "server", server], stdin: nil, session: nil)
        guard config.exitCode == 0 else { throw VaultError.signInFailed }

        if let clientID = request.clientID, let secret = request.clientSecret, !clientID.isEmpty, !secret.isEmpty {
            // API-key login signs in without unlocking; the password unlocks.
            let login = try await capture(["login", "--apikey"], stdin: nil, session: nil,
                                          environment: ["BW_CLIENTID": clientID, "BW_CLIENTSECRET": secret])
            guard login.exitCode == 0 else { throw VaultError.signInFailed }
            let unlocked = try await capture(["unlock", "--passwordfile", "/dev/stdin", "--raw"], stdin: input, session: nil)
            guard unlocked.exitCode == 0 else { throw VaultError.unlockFailed }
            return try Self.sessionKey(unlocked.stdout, failure: .unlockFailed)
        }

        var arguments = ["login", "--passwordfile", "/dev/stdin", "--raw"]
        if let method = request.method {
            arguments += ["--method", String(method)]
            // The one-time code goes in argv: bw has no other way to take it.
            if let code = request.code, !code.isEmpty { arguments += ["--code", code] }
        }
        arguments += ["--", request.email]
        let output = try await capture(arguments, stdin: input, session: nil)
        guard output.exitCode == 0 else {
            // "Code is required." covers two-step and new-device checks;
            // several two-step methods without --method: "No provider selected."
            if ["code is required", "two-step", "no provider selected"].contains(where: { Self.mentions(output.stderr, $0) }) {
                throw VaultError.twoFactorRequired
            }
            throw VaultError.signInFailed
        }
        return try Self.sessionKey(output.stdout, failure: .signInFailed)
    }

    /// The default (terminal) profile's server and email, from `bw status`.
    func suggestedAccount() async -> (server: String?, email: String?) {
        guard let output = try? await capture(["status"], stdin: nil, session: nil, ownProfile: false),
              output.exitCode == 0,
              let status = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any]
        else { return (nil, nil) }
        return (status["serverUrl"] as? String, status["userEmail"] as? String)
    }

    /// A session key is base64; anything else is not one.
    static func sessionKey(_ data: Data, failure: VaultError) throws -> String {
        let session = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.count >= 20, session.allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) }) else {
            throw failure
        }
        return session
    }

    /// Classifies provider stderr inside the host; the text never leaves.
    static func mentions(_ stderr: Data, _ phrase: String) -> Bool {
        String(decoding: stderr, as: UTF8.self).lowercased().contains(phrase)
    }

    func items(session: String) async throws -> [VaultItem] {
        let data = try await run(["list", "items"], stdin: nil, session: session, failure: .locked)
        return try Self.project(data)
    }

    /// The field exactly as bw prints it: off a terminal it adds no
    /// newline, so nothing is trimmed (a password may end in whitespace).
    func value(of field: VaultField, itemID: String, session: String) async throws -> String {
        let data = try await run(["get", field.rawValue, itemID], stdin: nil, session: session, failure: .failed)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { throw VaultError.failed }
        return text
    }

    func lock(session: String?) async {
        _ = try? await run(["lock"], stdin: nil, session: session, failure: .failed)
    }

    /// `bw logout` in BarShelf's profile; already signed out counts as done.
    func signOut() async throws {
        let output = try await capture(["logout"], stdin: nil, session: nil)
        guard output.exitCode == 0 || Self.mentions(output.stderr, "not logged in") else { throw VaultError.failed }
    }

    /// Names, usernames, hosts and whether a TOTP exists: the only fields
    /// that leave this function. Passwords, notes and TOTP seeds stay in
    /// the parsed dictionaries, which are dropped here.
    static func project(_ data: Data) throws -> [VaultItem] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw VaultError.failed
        }
        return raw.compactMap { item -> VaultItem? in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let login = item["login"] as? [String: Any]
            let uri = (login?["uris"] as? [[String: Any]])?.first?["uri"] as? String
            let host = uri.flatMap { URL(string: $0)?.host }
            let totp = (login?["totp"] as? String).map { !$0.isEmpty } ?? false
            return VaultItem(id: id, name: name, username: login?["username"] as? String, host: host, hasTOTP: totp)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Runs bw and maps every outcome to a fixed `VaultError`; nothing the
    /// child printed on stderr leaves this function.
    func run(_ arguments: [String], stdin: Data?, session: String?, failure: VaultError) async throws -> Data {
        let output = try await capture(arguments, stdin: stdin, session: session)
        guard output.exitCode == 0 else { throw failure }
        return output.stdout
    }

    /// One bw run in BarShelf's profile (or, for `suggestedAccount` only,
    /// the user's default one). Launch errors map to `VaultError`; the
    /// caller classifies a non-zero exit.
    func capture(_ arguments: [String], stdin: Data?, session: String?, ownProfile: Bool = true,
                 environment extra: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> ExecService.Capture {
        guard let executable = executableOverride ?? Self.executable() else { throw VaultError.notInstalled }
        let home = NSHomeDirectory()
        var environment = [
            "HOME": home,
            // bw from npm is a node script: its own folder holds node.
            "PATH": executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "BW_NOINTERACTION": "true",
            "LANG": "en_US.UTF-8",
        ]
        if let session { environment["BW_SESSION"] = session }
        environment.merge(extra) { _, new in new }
        if ownProfile {
            try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            environment["BITWARDENCLI_APPDATA_DIR"] = dataDirectory.path
        }
        let result = await ExecService.capture(
            command: [executable.path] + arguments, discover: nil,
            timeoutMs: Int((timeout ?? self.timeout) * 1000), workingDirectory: URL(fileURLWithPath: home),
            extraEnvironment: environment, stdoutLimit: Self.maxOutputBytes, stdin: stdin)
        try Task.checkCancellation()
        switch result {
        case let .success(capture):
            return capture
        case .failure(.timeout):
            throw VaultError.timedOut
        case .failure(.outputTooLarge):
            throw VaultError.tooLarge
        case .failure(.binaryNotFound):
            throw VaultError.notInstalled
        case .failure:
            throw VaultError.failed
        }
    }
}

// MARK: - Broker

/// Holds unlocked vault sessions, in memory only, and ends them. A widget
/// gets item metadata and opaque handles; copying a field is done here and
/// the value goes straight to the pasteboard.
///
/// Sessions are per provider, not per widget: Bitwarden's CLI keeps one
/// session per profile, so every copy of a vault widget shares it, and
/// ending it for one ends it for all. Calls into a provider run one at a
/// time, so a lock can never overtake an unlock or the other way round.
///
/// A session ends after `idleLockMinutes` without a user vault action
/// (refreshes do not count), at `maxSessionMinutes` after unlock (both on a
/// monotonic clock), on screen lock, sleep and quit, and whenever the runtime
/// stops or reloads a vault widget. A shared session never outlives the
/// shortest grant that used it: each widget's limits tighten the session's
/// when it lists or copies, and a session already past them ends.
///
/// Ending bumps the generation first, cancels every provider call in flight
/// or queued (listings too), clears a password BarShelf put on the clipboard
/// if it is still there, and then queues a provider lock behind the
/// cancelled calls, also when only an unlock was pending. Work that finishes
/// later checks the generation and the deadlines again and publishes nothing.
///
/// Touch ID resume (opt-in at the password prompt): the session key is also
/// sealed to a Secure Enclave key that needs current biometrics
/// (`SecureEnclaveSealer`), in memory only, for 8 hours from the password
/// unlock. Then idle, the session cap, a stricter grant, screen lock and sleep
/// end the session *softly*: the plaintext key and everything above go, but
/// bw is not locked, so Touch ID can reopen it. Lock, quit, widget changes,
/// the 8 hours running out, a provider that reports the session invalid, and
/// a Touch ID lockout or enrollment change end it *hard*: the sealed copy is
/// discarded and bw is locked. A soft lock protects the key BarShelf keeps;
/// it does not revoke the CLI session, which is why it is opt-in.
///
/// On quit, memory is dropped synchronously, but the provider lock runs as
/// a child process and may not finish before BarShelf exits; the CLI's own
/// session then stays until bw is locked or its session key is discarded.
@MainActor
final class VaultBroker {
    struct Session {
        var key: String
        var generation: UUID
        var unlockedAt: TimeInterval
        var lastUserActionAt: TimeInterval
        var idle: TimeInterval
        var max: TimeInterval
        /// Widget instance → opaque handle → item id, for this session.
        var handles: [String: [String: String]] = [:]

        func expired(at now: TimeInterval) -> Bool {
            now - lastUserActionAt >= idle || now - unlockedAt >= max
        }
    }

    /// A session key sealed for Touch ID resume, and the limits it carries.
    struct Resume {
        let id: UUID
        let provider: String
        let sealed: SealedSecret
        /// Password unlock + `resumeWindow`; a resume never moves it.
        let deadline: TimeInterval
        /// The tightest idle/max limits the session had; a resume never loosens them.
        var idle: TimeInterval
        var max: TimeInterval

        var aad: Data { Self.aad(provider: provider, id: id, deadline: deadline) }

        /// Binds the envelope to this provider, resume and deadline.
        static func aad(provider: String, id: UUID, deadline: TimeInterval) -> Data {
            Data("barshelf.vault.resume.v1|\(provider)|\(id.uuidString)|\(deadline)".utf8)
        }
    }

    /// What the host password prompt returns.
    struct PasswordAnswer {
        var password: String
        /// The user ticked "Reopen with Touch ID".
        var touchID: Bool
    }

    static let resumeWindow: TimeInterval = 8 * 3600

    /// What the host sign-in prompt returns.
    struct SignInAnswer {
        var server: String
        var email: String
        var password: String
        var touchID: Bool
    }

    /// A two-step login answer. An empty code with the email method asks
    /// Bitwarden to send one; `useAPIKey` switches to API-key sign-in.
    struct TwoFactorAnswer {
        var method: Int
        var code: String
        var useAPIKey = false
    }

    private var sessions: [String: Session] = [:]
    /// Provider → BarShelf's own profile as last seen: account, last sync, server.
    private var statuses: [String: VaultStatus] = [:]
    private func account(_ provider: String) -> VaultAccount { statuses[provider]?.account ?? .unknown }
    private var resumes: [String: Resume] = [:]
    /// Providers whose pending unlock is a password unlock already sent to
    /// the provider: ending it voids any older sealed key, so it ends hard.
    private var pendingPasswordUnlocks: Set<String> = []
    /// Provider → generation of the unlock now being asked for.
    private var pendingUnlocks: [String: UUID] = [:]
    /// Provider → the current generation; bumped by every end.
    private var generations: [String: UUID] = [:]
    /// Provider → how to cancel each call in flight or queued.
    private var operations: [String: [UUID: () -> Void]] = [:]
    /// Provider → the tail of its serial call chain.
    private var chains: [String: Task<Void, Never>] = [:]
    /// The pasteboard change BarShelf made with a vault field, if any.
    private var ownedChangeCount: Int?

    private var screenLocked = false
    private var sleeping = false
    private var terminating = false
    private var blocked: Bool { screenLocked || sleeping || terminating }

    private let provider: VaultProvider
    private let sealer: VaultKeySealer
    private let now: () -> TimeInterval
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sweepTimer: Timer?

    /// Asks the runtime to redraw vault widgets after a state change.
    var onChange: (() -> Void)?
    /// Records what happened, never what was in it: event, widget, and
    /// details such as provider, method, duration and item count.
    var audit: (_ event: String, _ widgetID: String, _ detail: [String: JSONValue]) -> Void = { _, _, _ in }
    var toast: (String) -> Void = { message in ToastCenter.shared.show(message) }
    /// The host-owned password prompt; nil means cancelled. Swappable in tests.
    var promptForPassword: (_ title: String, _ message: String, _ offerTouchID: Bool, _ touchIDDefault: Bool) -> PasswordAnswer?
        = VaultBroker.securePrompt
    /// The host-owned sign-in prompt (server, email, master password); nil
    /// means cancelled. Swappable in tests.
    var promptForSignIn: (_ message: String, _ server: String?, _ email: String?,
                          _ offerTouchID: Bool, _ touchIDDefault: Bool) -> SignInAnswer? = VaultBroker.signInPrompt
    /// The host-owned two-step code prompt; `emailSent` once a code went out.
    var promptForTwoFactor: (_ emailSent: Bool) -> TwoFactorAnswer? = VaultBroker.twoFactorPrompt
    /// The host-owned API-key prompt (client_id, client_secret).
    var promptForAPIKey: () -> (id: String, secret: String)? = VaultBroker.apiKeyPrompt
    /// Remembers the Touch ID checkbox per provider; a private suite in tests.
    var defaults: UserDefaults = .standard
    /// Where copied fields go; a private pasteboard in tests.
    var pasteboard: NSPasteboard = .general

    /// The default clock keeps counting through sleep and ignores wall-clock
    /// changes, so the 8-hour resume window includes a night asleep.
    init(provider: VaultProvider = BitwardenCLIProvider(),
         sealer: VaultKeySealer = SecureEnclaveSealer(),
         now: @escaping () -> TimeInterval = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }) {
        self.provider = provider
        self.sealer = sealer
        self.now = now
    }

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor () -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { body() }
            }))
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.screenLocked = true
            self?.lockAll(hard: false)
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.screenLocked = false }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.sleeping = true
            self?.lockAll(hard: false)
        }
        // No timer runs during sleep: the resume window is checked on wake.
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.sleeping = false
            self?.sweep()
        }
        // Memory goes now; the provider lock is best effort (see above).
        observe(NotificationCenter.default, NSApplication.willTerminateNotification) { [weak self] in
            self?.terminating = true
            self?.lockAll(hard: true)
        }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    /// For tests: what the screen-lock, sleep and quit notifications set.
    func setBlocked(screenLocked: Bool = false, sleeping: Bool = false) {
        self.screenLocked = screenLocked
        self.sleeping = sleeping
        if blocked { lockAll(hard: false) }
    }

    func isUnlocked(_ permission: Manifest.VaultPermission) -> Bool {
        sweep()
        return sessions[permission.provider] != nil
    }

    /// Touch ID can reopen this provider's vault (a sealed copy is kept).
    func isResumable(_ permission: Manifest.VaultPermission) -> Bool {
        sweep()
        return resumes[permission.provider] != nil
    }

    // MARK: User actions

    /// Reopens with Touch ID when a sealed copy exists and Touch ID is
    /// available, unless `usePassword`; otherwise asks for the master password.
    func unlock(widgetID: String, permission: Manifest.VaultPermission, widgetName: String, usePassword: Bool = false) {
        let provider = permission.provider
        sweep()
        guard !blocked, sessions[provider] == nil, pendingUnlocks[provider] == nil else { return }
        let biometry = sealer.biometry
        if resumes[provider] != nil, biometry == .invalid {
            // Locked out or every finger removed: the sealed copy is void.
            end(provider: provider)
            toast(String(localized: "Touch ID can no longer reopen the vault. Unlock with the master password."))
        }
        if !usePassword, let resume = resumes[provider], biometry == .available {
            reopen(resume, widgetID: widgetID, permission: permission, widgetName: widgetName)
            return
        }
        if account(provider) == .signedOut {
            signIn(widgetID: widgetID, permission: permission, widgetName: widgetName)
            return
        }
        let generation = UUID()
        generations[provider] = generation
        pendingUnlocks[provider] = generation
        let offerTouchID = biometry == .available
        let rememberKey = "vault.touchID.\(provider)"
        let title = String(localized: "Unlock Bitwarden")
        var message = String(localized: "\(widgetName) asks BarShelf to unlock your vault. BarShelf passes the master password to the Bitwarden CLI, keeps only the session it returns, and locks again after \(Int(permission.idleSeconds / 60)) minutes without use.")
        if offerTouchID {
            message += "\n\n" + String(localized: "With Touch ID on, the Bitwarden CLI stays unlocked for up to 8 hours so Touch ID can reopen it here; Lock ends that at once.")
        }
        let answer = promptForPassword(title, message, offerTouchID, defaults.bool(forKey: rememberKey))
        // The prompt is modal: anything may have happened while it was open.
        guard pendingUnlocks[provider] == generation, !blocked, let answer, !answer.password.isEmpty else {
            if pendingUnlocks[provider] == generation { pendingUnlocks[provider] = nil }
            return
        }
        if offerTouchID { defaults.set(answer.touchID, forKey: rememberKey) }
        let wantsResume = offerTouchID && answer.touchID
        let password = answer.password
        let vault = self.provider
        pendingPasswordUnlocks.insert(provider)
        let startedAt = now()
        let work = enqueue(provider, generation: generation) { try await vault.unlock(password: password) }
        // The card shows Unlocking… while bw derives the key.
        onChange?()
        Task { @MainActor [weak self] in
            do {
                let key = try await work.value
                guard let self else { return }
                self.audit("vault.unlocked", widgetID, ["provider": .string(provider), "method": .string("password"),
                                                         "ms": .number(((self.now() - startedAt) * 1000).rounded())])
                // Ended meanwhile: end already queued a provider lock behind
                // this unlock. Queuing another here could land after a newer
                // unlock and lock that session instead.
                self.install(key, provider: provider, generation: generation, permission: permission,
                             wantsResume: wantsResume, syncAfter: true)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.pendingUnlocks[provider] == generation else { return }
                self.pendingUnlocks[provider] = nil
                self.pendingPasswordUnlocks.remove(provider)
                let vaultError = (error as? VaultError) ?? .unlockFailed
                if vaultError == .signedOut {
                    // BarShelf's own profile has no account yet: sign in instead.
                    self.statuses[provider, default: .unknown].account = .signedOut
                    self.onChange?()
                    self.signIn(widgetID: widgetID, permission: permission, widgetName: widgetName)
                    return
                }
                self.audit("vault.unlock_failed", widgetID, ["provider": .string(provider), "method": .string("password"),
                                                              "reason": .string("\(vaultError)"),
                                                              "ms": .number(((self.now() - startedAt) * 1000).rounded())])
                self.toast(vaultError.message)
                self.onChange?()
            }
        }
    }

    /// Installs a session a password unlock or sign-in returned, unless the
    /// attempt ended meanwhile (end then already queued a provider lock).
    private func install(_ key: String, provider: String, generation: UUID,
                         permission: Manifest.VaultPermission, wantsResume: Bool, syncAfter: Bool) {
        guard pendingUnlocks[provider] == generation, generations[provider] == generation, !blocked else { return }
        pendingUnlocks[provider] = nil
        pendingPasswordUnlocks.remove(provider)
        statuses[provider, default: .unknown].account = .signedIn
        let at = now()
        sessions[provider] = Session(key: key, generation: generation, unlockedAt: at, lastUserActionAt: at,
                                     idle: permission.idleSeconds, max: permission.maxSeconds)
        // bw issued a new session key: an older sealed copy is void.
        resumes[provider] = nil
        if wantsResume { sealForResume(key, provider: provider, permission: permission, at: at) }
        onChange?()
        // Unlocking only decrypts the local copy: fetch what changed on the
        // server (sign-in already did), then redraw. A failure keeps the
        // local copy (offline is fine).
        guard syncAfter else { return }
        let vault = self.provider
        let sync = enqueue(provider, generation: generation) { try await vault.sync(session: key) }
        Task { @MainActor [weak self] in
            guard (try? await sync.value) != nil, let self, self.isCurrent(provider, generation) else { return }
            await self.refreshStatus(provider)
            self.onChange?()
        }
    }

    /// Signs BarShelf's own profile in (once), which also unlocks it. The
    /// server and email are suggested from the user's own CLI profile; a
    /// two-step code is asked for when the account needs one.
    func signIn(widgetID: String, permission: Manifest.VaultPermission, widgetName: String) {
        let provider = permission.provider
        guard !blocked, sessions[provider] == nil, pendingUnlocks[provider] == nil else { return }
        let generation = UUID()
        generations[provider] = generation
        pendingUnlocks[provider] = generation
        let vault = self.provider
        let offerTouchID = sealer.biometry == .available
        let rememberKey = "vault.touchID.\(provider)"
        var message = String(localized: "\(widgetName) asks BarShelf to sign in to Bitwarden. BarShelf keeps its own sign-in, separate from the bw you use in Terminal, so neither locks the other. The master password goes to the Bitwarden CLI and is not kept.")
        if offerTouchID {
            message += "\n\n" + String(localized: "With Touch ID on, the Bitwarden CLI stays unlocked for up to 8 hours so Touch ID can reopen it here; Lock ends that at once.")
        }
        let defaults = self.defaults
        Task { @MainActor [weak self] in
            let suggestion = await vault.suggestedAccount()
            guard let self else { return }
            @MainActor func stillPending() -> Bool { self.pendingUnlocks[provider] == generation && !self.blocked }
            @MainActor func giveUp() {
                if self.pendingUnlocks[provider] == generation {
                    self.pendingUnlocks[provider] = nil
                    self.pendingPasswordUnlocks.remove(provider)
                    self.onChange?()
                }
            }
            guard stillPending(),
                  let answer = self.promptForSignIn(message, suggestion.server, suggestion.email,
                                                    offerTouchID, defaults.bool(forKey: rememberKey)),
                  stillPending(), !answer.email.isEmpty, !answer.password.isEmpty else { return giveUp() }
            if offerTouchID { defaults.set(answer.touchID, forKey: rememberKey) }
            let wantsResume = offerTouchID && answer.touchID
            var request = VaultSignIn(server: answer.server.isEmpty ? nil : answer.server,
                                      email: answer.email, password: answer.password)
            self.pendingPasswordUnlocks.insert(provider)
            self.onChange?()
            let startedAt = self.now()
            while true {
                do {
                    let attempt = request
                    let key = try await self.enqueue(provider, generation: generation) { try await vault.signIn(attempt) }.value
                    self.audit("vault.signed_in", widgetID, ["provider": .string(provider),
                                                              "ms": .number(((self.now() - startedAt) * 1000).rounded())])
                    self.install(key, provider: provider, generation: generation, permission: permission,
                                 wantsResume: wantsResume, syncAfter: false)
                    // Sign-in synced: pick up its time and server for the card.
                    await self.refreshStatus(provider)
                    self.onChange?()
                    return
                } catch VaultError.twoFactorRequired where (request.code ?? "").isEmpty && request.clientID == nil {
                    // Asked for a code (or, by email, just sent one).
                    guard stillPending(), let factor = self.promptForTwoFactor(request.method == 1), stillPending() else {
                        return giveUp()
                    }
                    if factor.useAPIKey {
                        guard let key = self.promptForAPIKey(), stillPending(), !key.id.isEmpty, !key.secret.isEmpty else {
                            return giveUp()
                        }
                        request.clientID = key.id
                        request.clientSecret = key.secret
                        request.method = nil
                        request.code = nil
                        continue
                    }
                    request.method = factor.method
                    request.code = factor.code.isEmpty ? nil : factor.code
                    if request.code == nil, factor.method != 1 {
                        giveUp()
                        self.toast(String(localized: "Enter the code to sign in."))
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.pendingUnlocks[provider] == generation else { return }
                    let vaultError = (error as? VaultError) ?? .signInFailed
                    self.audit("vault.sign_in_failed", widgetID, ["provider": .string(provider), "reason": .string("\(vaultError)")])
                    giveUp()
                    self.toast(vaultError == .twoFactorRequired ? VaultError.signInFailed.message : vaultError.message)
                    return
                }
            }
        }
    }

    private func sealForResume(_ key: String, provider: String, permission: Manifest.VaultPermission, at: TimeInterval) {
        let id = UUID()
        let deadline = at + Self.resumeWindow
        guard let sealed = try? sealer.seal(Data(key.utf8), aad: Resume.aad(provider: provider, id: id, deadline: deadline)) else {
            toast(String(localized: "Touch ID couldn't be set up; the vault will ask for the master password next time."))
            return
        }
        resumes[provider] = Resume(id: id, provider: provider, sealed: sealed, deadline: deadline,
                                   idle: permission.idleSeconds, max: permission.maxSeconds)
    }

    /// Touch ID, then the Secure Enclave opens the sealed key. Tracked like
    /// provider work: ending the session cancels the prompt.
    private func reopen(_ resume: Resume, widgetID: String, permission: Manifest.VaultPermission, widgetName: String) {
        let provider = permission.provider
        let generation = UUID()
        generations[provider] = generation
        pendingUnlocks[provider] = generation
        let sealer = self.sealer
        let sealed = resume.sealed
        let aad = resume.aad
        let reason = String(localized: "unlock Bitwarden for \(widgetName)")
        let startedAt = now()
        let work = Task { await sealer.open(sealed, aad: aad, reason: reason) }
        let id = UUID()
        operations[provider, default: [:]][id] = { work.cancel() }
        onChange?()
        Task { @MainActor [weak self] in
            let outcome = await work.value
            guard let self else { return }
            self.operations[provider]?[id] = nil
            // Checked again after the Secure Enclave, right before installing;
            // the sweep hard-ends a copy whose 8 hours ran out meanwhile.
            self.sweep()
            guard self.pendingUnlocks[provider] == generation, self.generations[provider] == generation, !self.blocked,
                  let live = self.resumes[provider], live.id == resume.id, self.now() < live.deadline else {
                if self.pendingUnlocks[provider] == generation {
                    self.pendingUnlocks[provider] = nil
                    self.onChange?()
                }
                return
            }
            self.pendingUnlocks[provider] = nil
            switch outcome {
            case let .success(data):
                guard let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                    self.end(provider: provider)
                    return
                }
                let at = self.now()
                self.sessions[provider] = Session(key: key, generation: generation, unlockedAt: at, lastUserActionAt: at,
                                                  idle: min(live.idle, permission.idleSeconds),
                                                  max: min(live.max, permission.maxSeconds))
                self.audit("vault.unlocked", widgetID, ["provider": .string(provider), "method": .string("touchID"),
                                                         "ms": .number(((self.now() - startedAt) * 1000).rounded())])
                self.onChange?()
            case .failure(.cancelled):
                self.onChange?()
            case .failure(.fallback):
                self.unlock(widgetID: widgetID, permission: permission, widgetName: widgetName, usePassword: true)
            case .failure(.unavailable):
                self.toast(String(localized: "Touch ID isn't available right now. Use the master password."))
                self.onChange?()
            case .failure(.invalid):
                self.end(provider: provider)
                self.toast(String(localized: "Touch ID can no longer reopen the vault. Unlock with the master password."))
            }
        }
    }

    /// Copies one field of the item a handle names to the pasteboard, marked
    /// concealed and transient, and clears it after `clearAfter` seconds if
    /// it is still there. Counts as a user action.
    func copy(widgetID: String, permission: Manifest.VaultPermission, handle: String, field: VaultField, clearAfter: Int = 30) {
        let provider = permission.provider
        guard var session = admit(permission), let itemID = session.handles[widgetID]?[handle] else {
            toast(VaultError.locked.message)
            return
        }
        session.lastUserActionAt = now()
        sessions[provider] = session
        let generation = session.generation
        let key = session.key
        let vault = self.provider
        let work = enqueue(provider, generation: generation) { try await vault.value(of: field, itemID: itemID, session: key) }
        Task { @MainActor [weak self] in
            do {
                let value = try await work.value
                guard let self, self.isCurrent(provider, generation) else { return }
                let pasteboard = self.pasteboard
                pasteboard.clearContents()
                pasteboard.declareTypes([.string, Self.concealedType, Self.transientType], owner: nil)
                pasteboard.setString(value, forType: .string)
                pasteboard.setString("", forType: Self.concealedType)
                pasteboard.setString("", forType: Self.transientType)
                let changeCount = pasteboard.changeCount
                self.ownedChangeCount = changeCount
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(max(clearAfter, 5))) { [weak self] in
                    MainActor.assumeIsolated { self?.clearOwnedPasteboard(ifChangeCount: changeCount) }
                }
                self.toast(Self.copiedMessage(field))
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrent(provider, generation) else { return }
                self.toast(((error as? VaultError) ?? .failed).message)
            }
        }
    }

    func lock(_ permission: Manifest.VaultPermission) {
        end(provider: permission.provider)
    }

    /// The host-owned confirmation before signing out; swappable in tests.
    var confirmSignOut: () -> Bool = VaultBroker.signOutPrompt

    /// Signs BarShelf's own profile out once the user confirms: the session
    /// and any sealed copy end hard (bw is locked), then the provider signs
    /// out behind that lock. The bw the user runs in Terminal is a separate
    /// profile and stays as it is. The next Unlock asks to sign in again.
    func signOut(widgetID: String, permission: Manifest.VaultPermission) {
        let provider = permission.provider
        sweep()
        guard !blocked, pendingUnlocks[provider] == nil, account(provider) != .signedOut,
              confirmSignOut(), !blocked, pendingUnlocks[provider] == nil else { return }
        end(provider: provider)
        let vault = self.provider
        let work = serialTask(provider, generation: nil) { try await vault.signOut() }
        Task { @MainActor [weak self] in
            let done = (try? await work.value) != nil
            guard let self else { return }
            await self.refreshStatus(provider)
            if done {
                self.audit("vault.signed_out", widgetID, ["provider": .string(provider)])
                self.toast(String(localized: "Signed out of Bitwarden in BarShelf"))
            } else {
                self.toast(VaultError.failed.message)
            }
            self.onChange?()
        }
    }

    // MARK: For the workflow source

    /// The vault's state and item metadata for a widget's `vault.items`
    /// source. Not a user action: a refresh never keeps a vault unlocked.
    func itemsSource(widgetID: String, permission: Manifest.VaultPermission) async -> JSONValue {
        let provider = permission.provider
        guard let session = admit(permission) else {
            if pendingUnlocks[provider] == nil { await refreshStatus(provider) }
            return lockedState(provider)
        }
        let generation = session.generation
        let key = session.key
        let vault = self.provider
        let startedAt = now()
        let work = enqueue(provider, generation: generation) { try await vault.items(session: key) }
        do {
            let items = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            audit("vault.listed", widgetID, ["provider": .string(provider), "count": .number(Double(items.count)),
                                             "ms": .number(((now() - startedAt) * 1000).rounded())])
            guard isCurrent(provider, generation), var current = sessions[provider] else { return lockedState(provider) }
            let limit = 500
            var handles: [String: String] = [:]
            var rows: [JSONValue] = []
            for item in items.prefix(limit) {
                let handle = UUID().uuidString
                handles[handle] = item.id
                rows.append(.object([
                    "handle": .string(handle), "name": .string(item.name),
                    "username": item.username.map(JSONValue.string) ?? .null,
                    "host": item.host.map(JSONValue.string) ?? .null,
                    "totp": .bool(item.hasTOTP), "hasUsername": .bool(!(item.username ?? "").isEmpty),
                ]))
            }
            current.handles[widgetID] = handles
            sessions[provider] = current
            return .object(["state": .string("unlocked"), "items": .array(rows),
                            "count": .number(Double(items.count)), "truncated": .bool(items.count > limit),
                            "resumable": .bool(resumes[provider] != nil),
                            "account": .string(VaultAccount.signedIn.rawValue),
                            "lastSync": statuses[provider]?.lastSync.map(JSONValue.string) ?? .null,
                            "server": statuses[provider]?.server.map(JSONValue.string) ?? .null])
        } catch {
            guard isCurrent(provider, generation) else { return lockedState(provider) }
            let vaultError = (error as? VaultError) ?? .failed
            if vaultError == .locked {
                // The session is invalid, and so is its sealed copy.
                end(provider: provider, runProviderLock: false)
                return lockedState(provider)
            }
            return .object(["state": .string("error"), "items": .array([]), "error": .string(vaultError.message)])
        }
    }

    /// BarShelf's own profile as `bw status` reads it (no session, no
    /// secret), behind any provider call already queued. An unreadable
    /// answer keeps what was known.
    private func refreshStatus(_ provider: String) async {
        let vault = self.provider
        guard let status = try? await serialTask(provider, generation: nil, { await vault.status() }).value else { return }
        if status.account != .unknown || statuses[provider] == nil { statuses[provider] = status }
    }

    /// What a locked vault shows: whether it is being unlocked, whether
    /// BarShelf's profile needs signing in, and whether Touch ID can reopen it now.
    private func lockedState(_ provider: String) -> JSONValue {
        .object(["state": .string(pendingUnlocks[provider] != nil ? "unlocking" : "locked"), "items": .array([]),
                 "account": .string(account(provider).rawValue),
                 "lastSync": statuses[provider]?.lastSync.map(JSONValue.string) ?? .null,
                 "server": statuses[provider]?.server.map(JSONValue.string) ?? .null,
                 "resumable": .bool(resumes[provider] != nil),
                 "biometry": sealer.biometry == .available ? .string("touchID") : .null])
    }

    // MARK: Ending sessions

    /// Ends every session and pending unlock: softly on screen lock and
    /// sleep (a sealed copy survives), hard on quit.
    func lockAll(hard: Bool = true) {
        var providers = Set(sessions.keys).union(pendingUnlocks.keys).union(operations.keys)
        if hard { providers.formUnion(resumes.keys) }
        for provider in providers { end(provider: provider, hard: hard) }
    }

    /// Ends the session a vault widget uses (it was disabled, removed,
    /// reloaded or revoked). Shared: every copy of the widget loses it.
    func endWidget(_ widgetID: String, permission: Manifest.VaultPermission?) {
        guard let permission else { return }
        end(provider: permission.provider)
    }

    /// The generation moves first, then calls in flight or queued are
    /// cancelled, a clipboard copy cleared and memory dropped. A soft end
    /// (only when a sealed copy exists, and no password unlock was under
    /// way) stops there and tightens the copy's limits. A hard end also
    /// discards the sealed copy and queues a provider lock behind the
    /// cancelled calls, so it runs once they stopped.
    func end(provider: String, hard: Bool = true, runProviderLock: Bool = true) {
        generations[provider] = UUID()
        let hadPending = pendingUnlocks.removeValue(forKey: provider) != nil
        let passwordUnderWay = pendingPasswordUnlocks.remove(provider) != nil
        for cancel in operations.removeValue(forKey: provider)?.values ?? [:].values { cancel() }
        clearOwnedPasteboard(ifChangeCount: nil)
        let session = sessions.removeValue(forKey: provider)
        if !hard, !passwordUnderWay, var resume = resumes[provider] {
            if let session {
                resume.idle = min(resume.idle, session.idle)
                resume.max = min(resume.max, session.max)
                resumes[provider] = resume
            }
            if session != nil || hadPending {
                audit("vault.locked", "vault:\(provider)", ["provider": .string(provider), "hard": .bool(false)])
                onChange?()
            }
            return
        }
        let resume = resumes.removeValue(forKey: provider)
        guard session != nil || hadPending || resume != nil else { return }
        audit("vault.locked", "vault:\(provider)", ["provider": .string(provider), "hard": .bool(true)])
        if runProviderLock {
            // Without a key too: a cancelled unlock may have unlocked bw, and
            // a sealed copy's session is still open in bw.
            let vault = self.provider
            let key = session?.key
            _ = serialTask(provider, generation: nil) { await vault.lock(session: key) }
        }
        onChange?()
    }

    private func sweep() {
        let at = now()
        for (provider, resume) in resumes where at >= resume.deadline {
            end(provider: provider)
        }
        for (provider, session) in sessions where session.expired(at: at) {
            end(provider: provider, hard: false)
        }
    }

    /// The session a widget may use now: its grant's limits tighten the
    /// shared session's, and a session already past them ends.
    private func admit(_ permission: Manifest.VaultPermission) -> Session? {
        let provider = permission.provider
        sweep()
        guard !blocked, var session = sessions[provider] else { return nil }
        session.idle = min(session.idle, permission.idleSeconds)
        session.max = min(session.max, permission.maxSeconds)
        // Stored first, so a soft end hands the tightened limits to the sealed copy.
        sessions[provider] = session
        if session.expired(at: now()) {
            end(provider: provider, hard: false)
            return nil
        }
        return session
    }

    /// The session started under `generation` is still the one, still
    /// within its lifetimes, and nothing is blocking vault work.
    private func isCurrent(_ provider: String, _ generation: UUID) -> Bool {
        sweep()
        guard !blocked, let session = sessions[provider], session.generation == generation else { return false }
        if session.expired(at: now()) {
            end(provider: provider, hard: false)
            return false
        }
        return true
    }

    private func clearOwnedPasteboard(ifChangeCount expected: Int?) {
        guard let owned = ownedChangeCount else { return }
        if let expected, expected != owned { return }
        if pasteboard.changeCount == owned { pasteboard.clearContents() }
        ownedChangeCount = nil
    }

    // MARK: Provider work

    /// Queues a provider call behind the earlier ones, at once (so call
    /// order is the order of these calls). With a generation, the call is
    /// skipped if that generation is no longer current when its turn comes.
    private func serialTask<T: Sendable>(_ provider: String, generation: UUID?,
                                         _ operation: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let previous = chains[provider]
        let task = Task<T, Error> { @MainActor [weak self] in
            await previous?.value
            try Task.checkCancellation()
            if let generation {
                guard let self, self.generations[provider] == generation, !self.blocked else { throw CancellationError() }
            }
            return try await operation()
        }
        chains[provider] = Task { _ = try? await task.value }
        return task
    }

    /// A serial call that ending the session cancels, queued or running.
    private func enqueue<T: Sendable>(_ provider: String, generation: UUID,
                                      _ operation: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let task = serialTask(provider, generation: generation, operation)
        let id = UUID()
        operations[provider, default: [:]][id] = { task.cancel() }
        Task { @MainActor [weak self] in
            _ = try? await task.value
            self?.operations[provider]?[id] = nil
        }
        return task
    }

    // MARK: Pieces

    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copiedMessage(_ field: VaultField) -> String {
        switch field {
        case .username: return String(localized: "Username copied")
        case .password: return String(localized: "Password copied · clears in 30 s")
        case .totp: return String(localized: "Code copied · clears in 30 s")
        }
    }

    /// Host-owned sign-in fields: server, email, master password (secure).
    static func signInPrompt(message: String, server: String?, email: String?,
                             offerTouchID: Bool, touchIDDefault: Bool) -> SignInAnswer? {
        NotificationCenter.default.post(name: PopoverSurface.dismissAll, object: nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign In to Bitwarden")
        alert.informativeText = message
        let width: CGFloat = 300
        func field(_ placeholder: String, _ value: String?, secure: Bool = false) -> NSTextField {
            let field = secure ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
            field.placeholderString = placeholder
            field.stringValue = value ?? ""
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            return field
        }
        let serverField = field(String(localized: "Server (empty for bitwarden.com)"),
                                server.flatMap { $0 == "https://bitwarden.com" ? nil : $0 })
        let emailField = field(String(localized: "Email"), email)
        let passwordField = field(String(localized: "Master password"), nil, secure: true)
        let stack = NSStackView(views: [serverField, emailField, passwordField])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: width, height: 88)
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Sign In"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if offerTouchID {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Reopen with Touch ID for the next 8 hours")
            alert.suppressionButton?.state = touchIDDefault ? .on : .off
        }
        alert.window.initialFirstResponder = (email ?? "").isEmpty ? emailField : passwordField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        defer { passwordField.stringValue = "" }
        return SignInAnswer(server: serverField.stringValue.trimmingCharacters(in: .whitespaces),
                            email: emailField.stringValue.trimmingCharacters(in: .whitespaces),
                            password: passwordField.stringValue,
                            touchID: offerTouchID && alert.suppressionButton?.state == .on)
    }

    /// Host-owned two-step prompt: the method and its code.
    static func twoFactorPrompt(emailSent: Bool) -> TwoFactorAnswer? {
        NotificationCenter.default.post(name: PopoverSurface.dismissAll, object: nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Two-Step Login")
        alert.informativeText = emailSent
            ? String(localized: "Bitwarden sent a code to your email. Enter it here.")
            : String(localized: "Enter the code from your authenticator app or security key, or from an email Bitwarden already sent (choose Email). To have one emailed, choose Email and leave the code empty.\n\nNo two-step login on your account? Bitwarden is checking this new device by email, which only works with an API key here: choose Use API Key.")
        let methods: [(Int, String)] = [(0, String(localized: "Authenticator app")),
                                        (1, String(localized: "Email")),
                                        (3, String(localized: "YubiKey OTP"))]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        methods.forEach { popup.addItem(withTitle: $0.1) }
        if emailSent { popup.selectItem(at: 1) }
        let code = NSTextField(frame: .zero)
        code.placeholderString = String(localized: "Code")
        let stack = NSStackView(views: [popup, code])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        code.translatesAutoresizingMaskIntoConstraints = false
        code.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Use API Key…"))
        alert.window.initialFirstResponder = code
        let response = alert.runModal()
        if response == .alertThirdButtonReturn { return TwoFactorAnswer(method: 0, code: "", useAPIKey: true) }
        guard response == .alertFirstButtonReturn else { return nil }
        return TwoFactorAnswer(method: methods[max(popup.indexOfSelectedItem, 0)].0,
                               code: code.stringValue.trimmingCharacters(in: .whitespaces))
    }

    /// Asks before signing out: signing back in takes the master password
    /// and, for most accounts, a two-step code.
    static func signOutPrompt() -> Bool {
        NotificationCenter.default.post(name: PopoverSurface.dismissAll, object: nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign Out of Bitwarden in BarShelf?")
        alert.informativeText = String(localized: "BarShelf locks the vault and forgets its Bitwarden sign-in. The bw you use in Terminal stays signed in. To use the vault here again, sign in with your server, email and master password.")
        alert.addButton(withTitle: String(localized: "Sign Out"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Host-owned API-key fields; the secret is a secure field.
    static func apiKeyPrompt() -> (id: String, secret: String)? {
        NotificationCenter.default.post(name: PopoverSurface.dismissAll, object: nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign In with an API Key")
        alert.informativeText = String(localized: "In the Bitwarden web vault, open Settings ▸ Security ▸ Keys ▸ View API Key. BarShelf passes the key to the Bitwarden CLI for this sign-in only and does not keep it; your master password then unlocks.")
        let id = NSTextField(frame: .zero)
        id.placeholderString = "client_id"
        let secret = NSSecureTextField(frame: .zero)
        secret.placeholderString = "client_secret"
        for field in [id, secret] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        let stack = NSStackView(views: [id, secret])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Sign In"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = id
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        defer { secret.stringValue = "" }
        return (id.stringValue.trimmingCharacters(in: .whitespaces), secret.stringValue.trimmingCharacters(in: .whitespaces))
    }

    /// A host-owned secure field: widget code never sees it or what is typed.
    static func securePrompt(title: String, message: String, offerTouchID: Bool, touchIDDefault: Bool) -> PasswordAnswer? {
        // The card's popup floats above modal panels and would cover the prompt.
        NotificationCenter.default.post(name: PopoverSurface.dismissAll, object: nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = String(localized: "Master password")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Unlock"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if offerTouchID {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Reopen with Touch ID for the next 8 hours")
            alert.suppressionButton?.state = touchIDDefault ? .on : .off
        }
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        field.stringValue = ""
        return PasswordAnswer(password: value, touchID: offerTouchID && alert.suppressionButton?.state == .on)
    }
}
