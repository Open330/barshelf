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
    func lock(session: String) async
}

/// The Bitwarden CLI, run directly (no shell), from a known install location
/// (not PATH or the widget's folder), with a minimal environment. The master
/// password goes through stdin (`--passwordfile /dev/stdin`), never argv or
/// the environment; the session through `BW_SESSION` to this child only.
/// stderr is discarded, stdout bounded, the run timed out and killed, and
/// cancelling the calling task kills it too.
///
/// Bitwarden keeps one session per CLI profile: unlocking here replaces a
/// session unlocked in a terminal, and locking here locks the CLI for both.
/// BarShelf trusts the bw it finds (and, for npm installs, the node next to
/// it) as it trusts any software the user installed; a process already
/// running as the user can read its memory, which no app can prevent.
struct BitwardenCLIProvider: VaultProvider {
    static let timeout: TimeInterval = 30
    static let killGrace: TimeInterval = 2
    static let maxOutputBytes = 16 << 20
    static let maxPasswordBytes = 1024

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

    func lock(session: String) async {
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

    /// The running child, so cancellation can kill it.
    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func attach(_ process: Process) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.process = process
                return true
            }
        }

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            let running: Process? = lock.withLock {
                cancelled = true
                return process
            }
            if let running { BitwardenCLIProvider.stop(running) }
        }
    }

    /// SIGTERM, then SIGKILL if it is still there after the grace period.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func run(_ arguments: [String], stdin: Data?, session: String?, failure: VaultError) async throws -> Data {
        guard let executable = Self.executable() else { throw VaultError.notInstalled }
        let child = Child()
        let result: Result<Data, VaultError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.runSync(executable: executable, arguments: arguments,
                                                                stdin: stdin, session: session,
                                                                failure: failure, child: child))
                }
            }
        } onCancel: {
            child.cancel()
        }
        try Task.checkCancellation()
        return try result.get()
    }

    private static func runSync(executable: URL, arguments: [String], stdin: Data?, session: String?,
                                failure: VaultError, child: Child) -> Result<Data, VaultError> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var environment = [
            "HOME": NSHomeDirectory(),
            // bw from npm is a node script: its own folder holds node.
            "PATH": executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "BW_NOINTERACTION": "true",
            "LANG": "en_US.UTF-8",
        ]
        if let session { environment["BW_SESSION"] = session }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do { try process.run() } catch { return .failure(.notInstalled) }
        guard child.attach(process) else {
            stop(process)
            process.waitUntilExit()
            return .failure(failure)
        }
        // The timeout starts before anything that could block.
        var timedOut = false
        let deadline = DispatchWorkItem {
            timedOut = true
            stop(process)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        if let stdin {
            // On its own queue: a child that never reads cannot block us.
            let writer = input.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }
        var data = Data()
        var overflow = false
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            if !overflow {
                data.append(chunk)
                if data.count > maxOutputBytes {
                    overflow = true
                    data = Data()
                    stop(process)
                }
            }
        }
        process.waitUntilExit()
        deadline.cancel()
        if child.isCancelled { return .failure(failure) }
        if overflow { return .failure(.tooLarge) }
        if timedOut { return .failure(.timedOut) }
        return process.terminationStatus == 0 ? .success(data) : .failure(failure)
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
/// stops or reloads a vault widget. Ending bumps the generation first,
/// cancels the provider work in flight, clears a password BarShelf put on the
/// clipboard if it is still there, and then asks the provider to lock. Work
/// that finishes later checks the generation and the deadlines again, and
/// publishes nothing.
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

    private var sessions: [String: Session] = [:]
    /// Provider → generation of the unlock now being asked for.
    private var pendingUnlocks: [String: UUID] = [:]
    /// Provider → the current generation; bumped by every end.
    private var generations: [String: UUID] = [:]
    /// Provider → provider work in flight, cancelled when the session ends.
    private var operations: [String: [UUID: Task<Void, Never>]] = [:]
    /// Provider → the tail of its serial call chain.
    private var chains: [String: Task<Void, Never>] = [:]
    /// The pasteboard change BarShelf made with a vault field, if any.
    private var ownedChangeCount: Int?

    private var screenLocked = false
    private var sleeping = false
    private var terminating = false
    private var blocked: Bool { screenLocked || sleeping || terminating }

    private let provider: VaultProvider
    private let now: () -> TimeInterval
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sweepTimer: Timer?

    /// Asks the runtime to redraw vault widgets after a state change.
    var onChange: (() -> Void)?
    var toast: (String) -> Void = { message in ToastCenter.shared.show(message) }
    /// The host-owned password prompt; nil means cancelled. Swappable in tests.
    var promptForPassword: (_ title: String, _ message: String) -> String? = VaultBroker.securePrompt
    /// Where copied fields go; a private pasteboard in tests.
    var pasteboard: NSPasteboard = .general

    init(provider: VaultProvider = BitwardenCLIProvider(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.provider = provider
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
            self?.lockAll()
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.screenLocked = false }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.sleeping = true
            self?.lockAll()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.sleeping = false }
        observe(NotificationCenter.default, NSApplication.willTerminateNotification) { [weak self] in
            self?.terminating = true
            self?.lockAll()
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
        if blocked { lockAll() }
    }

    func isUnlocked(_ permission: Manifest.VaultPermission) -> Bool {
        sweep()
        return sessions[permission.provider] != nil
    }

    // MARK: User actions

    func unlock(widgetID: String, permission: Manifest.VaultPermission, widgetName: String) {
        let provider = permission.provider
        sweep()
        guard !blocked, sessions[provider] == nil, pendingUnlocks[provider] == nil else { return }
        let generation = UUID()
        generations[provider] = generation
        pendingUnlocks[provider] = generation
        let title = String(localized: "Unlock Bitwarden")
        let message = String(localized: "\(widgetName) asks BarShelf to unlock your vault. BarShelf passes the master password to the Bitwarden CLI, keeps only the session it returns, and locks again after \(Int(permission.idleSeconds / 60)) minutes without use.")
        let password = promptForPassword(title, message)
        // The prompt is modal: anything may have happened while it was open.
        guard pendingUnlocks[provider] == generation, !blocked, let password, !password.isEmpty else {
            if pendingUnlocks[provider] == generation { pendingUnlocks[provider] = nil }
            return
        }
        let vault = self.provider
        track(provider) { [weak self] in
            do {
                let key = try await self?.serial(provider) { try await vault.unlock(password: password) }
                guard let self, let key else { return }
                guard self.pendingUnlocks[provider] == generation, self.generations[provider] == generation, !self.blocked else {
                    _ = try? await self.serial(provider) { await vault.lock(session: key) }
                    return
                }
                self.pendingUnlocks[provider] = nil
                let at = self.now()
                self.sessions[provider] = Session(key: key, generation: generation, unlockedAt: at, lastUserActionAt: at,
                                                  idle: permission.idleSeconds, max: permission.maxSeconds)
                self.onChange?()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.pendingUnlocks[provider] == generation else { return }
                self.pendingUnlocks[provider] = nil
                self.toast(((error as? VaultError) ?? .unlockFailed).message)
            }
        }
    }

    /// Copies one field of the item a handle names to the pasteboard, marked
    /// concealed and transient, and clears it after `clearAfter` seconds if
    /// it is still there. Counts as a user action.
    func copy(widgetID: String, permission: Manifest.VaultPermission, handle: String, field: VaultField, clearAfter: Int = 30) {
        let provider = permission.provider
        sweep()
        guard !blocked, var session = sessions[provider], let itemID = session.handles[widgetID]?[handle] else {
            toast(VaultError.locked.message)
            return
        }
        session.lastUserActionAt = now()
        sessions[provider] = session
        let generation = session.generation
        let key = session.key
        let vault = self.provider
        track(provider) { [weak self] in
            do {
                let value = try await self?.serial(provider) { try await vault.value(of: field, itemID: itemID, session: key) }
                guard let self, let value, self.isCurrent(provider, generation) else { return }
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
        sweep()
        let lockedValue: JSONValue = .object(["state": .string("locked"), "items": .array([])])
        guard !blocked, let session = sessions[provider] else { return lockedValue }
        let generation = session.generation
        let key = session.key
        let vault = self.provider
        do {
            let items = try await serial(provider) { try await vault.items(session: key) }
            guard isCurrent(provider, generation), var current = sessions[provider] else { return lockedValue }
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
                            "count": .number(Double(items.count)), "truncated": .bool(items.count > limit)])
        } catch {
            guard isCurrent(provider, generation) else { return lockedValue }
            let vaultError = (error as? VaultError) ?? .failed
            if vaultError == .locked {
                end(provider: provider, runProviderLock: false)
                return lockedValue
            }
            return .object(["state": .string("error"), "items": .array([]), "error": .string(vaultError.message)])
        }
    }

    // MARK: Ending sessions

    /// Ends every session and pending unlock (screen lock, sleep, quit).
    func lockAll() {
        let providers = Set(sessions.keys).union(pendingUnlocks.keys).union(operations.keys)
        for provider in providers { end(provider: provider) }
    }

    /// Ends the session a vault widget uses (it was disabled, removed,
    /// reloaded or revoked). Shared: every copy of the widget loses it.
    func endWidget(_ widgetID: String, permission: Manifest.VaultPermission?) {
        guard let permission else { return }
        end(provider: permission.provider)
    }

    /// The generation moves first, then work in flight is cancelled, a
    /// clipboard copy cleared, memory dropped, and the provider asked to lock.
    func end(provider: String, runProviderLock: Bool = true) {
        generations[provider] = UUID()
        pendingUnlocks[provider] = nil
        for task in operations.removeValue(forKey: provider)?.values ?? [:].values { task.cancel() }
        clearOwnedPasteboard(ifChangeCount: nil)
        guard let session = sessions.removeValue(forKey: provider) else { return }
        if runProviderLock {
            let vault = self.provider
            let key = session.key
            Task { _ = try? await self.serial(provider) { await vault.lock(session: key) } }
        }
        onChange?()
    }

    private func sweep() {
        let at = now()
        for (provider, session) in sessions where session.expired(at: at) {
            end(provider: provider)
        }
    }

    /// The session started under `generation` is still the one, still
    /// within its lifetimes, and nothing is blocking vault work.
    private func isCurrent(_ provider: String, _ generation: UUID) -> Bool {
        guard !blocked, let session = sessions[provider], session.generation == generation else { return false }
        if session.expired(at: now()) {
            end(provider: provider)
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

    /// Runs provider calls one at a time per provider.
    private func serial<T: Sendable>(_ provider: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = chains[provider]
        let task = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        chains[provider] = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Keeps a task so ending the session can cancel it.
    private func track(_ provider: String, _ body: @escaping @MainActor () async -> Void) {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await body()
            self?.operations[provider]?[id] = nil
        }
        operations[provider, default: [:]][id] = task
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
    static func securePrompt(title: String, message: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = String(localized: "Master password")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Unlock"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        field.stringValue = ""
        return value
    }
}
