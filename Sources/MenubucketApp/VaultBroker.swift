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

    var message: String {
        switch self {
        case .notInstalled: return String(localized: "The Bitwarden CLI (bw) isn't installed.")
        case .unlockFailed: return String(localized: "Couldn't unlock. Check the master password and that bw is logged in.")
        case .locked: return String(localized: "The vault is locked.")
        case .timedOut: return String(localized: "Bitwarden took too long to answer.")
        case .tooLarge: return String(localized: "The vault answer was too large to read.")
        case .failed: return String(localized: "Bitwarden couldn't do that.")
        }
    }
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
/// Bitwarden keeps one session per CLI profile: unlocking here replaces a
/// session unlocked in a terminal, and locking here locks the CLI for both.
/// BarShelf trusts the bw it finds (and, for npm installs, the node next to
/// it) as it trusts any software the user installed; a process already
/// running as the user can read its memory, which no app can prevent.
struct BitwardenCLIProvider: VaultProvider {
    static let maxOutputBytes = 16 << 20
    static let maxPasswordBytes = 1024

    /// Tests point this at a synthetic helper; nil means the vetted locations.
    var executableOverride: URL?
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
        let data = try await run(["unlock", "--passwordfile", "/dev/stdin", "--raw"],
                                 stdin: input, session: nil, failure: .unlockFailed)
        let session = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // A session key is base64; anything else is not one.
        guard session.count >= 20, session.allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) }) else {
            throw VaultError.unlockFailed
        }
        return session
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
        let result = await ExecService.capture(
            command: [executable.path] + arguments, discover: nil,
            timeoutMs: Int(timeout * 1000), workingDirectory: URL(fileURLWithPath: home),
            extraEnvironment: environment, stdoutLimit: Self.maxOutputBytes, stdin: stdin)
        try Task.checkCancellation()
        switch result {
        case let .success(capture):
            guard capture.exitCode == 0 else { throw failure }
            return capture.stdout
        case .failure(.timeout):
            throw VaultError.timedOut
        case .failure(.outputTooLarge):
            throw VaultError.tooLarge
        case .failure(.binaryNotFound):
            throw VaultError.notInstalled
        case .failure:
            throw failure
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

    private var sessions: [String: Session] = [:]
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
    var toast: (String) -> Void = { message in ToastCenter.shared.show(message) }
    /// The host-owned password prompt; nil means cancelled. Swappable in tests.
    var promptForPassword: (_ title: String, _ message: String, _ offerTouchID: Bool, _ touchIDDefault: Bool) -> PasswordAnswer?
        = VaultBroker.securePrompt
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
        let work = enqueue(provider, generation: generation) { try await vault.unlock(password: password) }
        Task { @MainActor [weak self] in
            do {
                let key = try await work.value
                guard let self else { return }
                // Ended meanwhile: end already queued a provider lock behind
                // this unlock. Queuing another here could land after a newer
                // unlock and lock that session instead.
                guard self.pendingUnlocks[provider] == generation, self.generations[provider] == generation, !self.blocked else {
                    return
                }
                self.pendingUnlocks[provider] = nil
                self.pendingPasswordUnlocks.remove(provider)
                let at = self.now()
                self.sessions[provider] = Session(key: key, generation: generation, unlockedAt: at, lastUserActionAt: at,
                                                  idle: permission.idleSeconds, max: permission.maxSeconds)
                // bw issued a new session key: an older sealed copy is void.
                self.resumes[provider] = nil
                if wantsResume { self.sealForResume(key, provider: provider, permission: permission, at: at) }
                self.onChange?()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.pendingUnlocks[provider] == generation else { return }
                self.pendingUnlocks[provider] = nil
                self.pendingPasswordUnlocks.remove(provider)
                self.toast(((error as? VaultError) ?? .unlockFailed).message)
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
        let work = Task { await sealer.open(sealed, aad: aad, reason: reason) }
        let id = UUID()
        operations[provider, default: [:]][id] = { work.cancel() }
        Task { @MainActor [weak self] in
            let outcome = await work.value
            guard let self else { return }
            self.operations[provider]?[id] = nil
            // Checked again after the Secure Enclave, right before installing;
            // the sweep hard-ends a copy whose 8 hours ran out meanwhile.
            self.sweep()
            guard self.pendingUnlocks[provider] == generation, self.generations[provider] == generation, !self.blocked,
                  let live = self.resumes[provider], live.id == resume.id, self.now() < live.deadline else {
                if self.pendingUnlocks[provider] == generation { self.pendingUnlocks[provider] = nil }
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
                self.onChange?()
            case .failure(.cancelled):
                return
            case .failure(.fallback):
                self.unlock(widgetID: widgetID, permission: permission, widgetName: widgetName, usePassword: true)
            case .failure(.unavailable):
                self.toast(String(localized: "Touch ID isn't available right now. Use the master password."))
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

    // MARK: For the workflow source

    /// The vault's state and item metadata for a widget's `vault.items`
    /// source. Not a user action: a refresh never keeps a vault unlocked.
    func itemsSource(widgetID: String, permission: Manifest.VaultPermission) async -> JSONValue {
        let provider = permission.provider
        guard let session = admit(permission) else { return lockedState(provider) }
        let generation = session.generation
        let key = session.key
        let vault = self.provider
        let work = enqueue(provider, generation: generation) { try await vault.items(session: key) }
        do {
            let items = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
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
                            "resumable": .bool(resumes[provider] != nil)])
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

    /// What a locked vault shows: whether Touch ID can reopen it now.
    private func lockedState(_ provider: String) -> JSONValue {
        .object(["state": .string("locked"), "items": .array([]),
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
                onChange?()
            }
            return
        }
        let resume = resumes.removeValue(forKey: provider)
        guard session != nil || hadPending || resume != nil else { return }
        if runProviderLock {
            // Without a key too: a cancelled unlock may have unlocked bw, and
            // a sealed copy's session is still open in bw.
            let vault = self.provider
            let key = session?.key
            _ = serialTask(provider, generation: nil) { await vault.lock(session: key) }
        }
        if session != nil || resume != nil { onChange?() }
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

    /// A host-owned secure field: widget code never sees it or what is typed.
    static func securePrompt(title: String, message: String, offerTouchID: Bool, touchIDDefault: Bool) -> PasswordAnswer? {
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
