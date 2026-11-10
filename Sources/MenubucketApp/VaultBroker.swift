import AppKit
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
/// item, and lock. Swappable in tests.
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
/// stderr is discarded and stdout bounded.
struct BitwardenCLIProvider: VaultProvider {
    static let timeout: TimeInterval = 30
    static let maxOutputBytes = 16 << 20

    /// Where bw is installed by Homebrew, npm (global or nvm), volta or bun.
    static func executable(home: String = NSHomeDirectory()) -> URL? {
        var candidates = ["/opt/homebrew/bin/bw", "/usr/local/bin/bw",
                          home + "/.npm-global/bin/bw", home + "/.volta/bin/bw", home + "/.bun/bin/bw"]
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            // Newest node first.
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append("\(nvm)/\(version)/bin/bw")
            }
        }
        return candidates.lazy.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func unlock(password: String) async throws -> String {
        let data = try await run(["unlock", "--passwordfile", "/dev/stdin", "--raw"],
                                 stdin: Data((password + "\n").utf8), session: nil,
                                 failure: .unlockFailed)
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

    func value(of field: VaultField, itemID: String, session: String) async throws -> String {
        let data = try await run(["get", field.rawValue, itemID], stdin: nil, session: session, failure: .failed)
        var text = String(decoding: data, as: UTF8.self)
        // bw ends its output with one newline: framing, not the secret.
        if text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty else { throw VaultError.failed }
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

    private func run(_ arguments: [String], stdin: Data?, session: String?, failure: VaultError) async throws -> Data {
        guard let executable = Self.executable() else { throw VaultError.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Self.runSync(executable: executable, arguments: arguments,
                                                       stdin: stdin, session: session, failure: failure))
            }
        }
    }

    private static func runSync(executable: URL, arguments: [String], stdin: Data?,
                                session: String?, failure: VaultError) -> Result<Data, VaultError> {
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
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maxOutputBytes {
                process.terminate()
                timer.cancel()
                return .failure(.tooLarge)
            }
        }
        process.waitUntilExit()
        let timedOut = !timer.isCancelled && process.terminationReason == .uncaughtSignal
        timer.cancel()
        if timedOut { return .failure(.timedOut) }
        return process.terminationStatus == 0 ? .success(data) : .failure(failure)
    }
}

// MARK: - Broker

/// Holds unlocked vault sessions for widget instances, in memory only, and
/// ends them. A widget gets item metadata and opaque handles; copying a field
/// is done here and the value goes straight to the pasteboard.
///
/// A session ends (memory dropped, provider lock attempted) after
/// `idleLockMinutes` without a user vault action — background refreshes do
/// not count — at `maxSessionMinutes` after unlock, on screen lock, sleep,
/// quit, and whenever the runtime stops the widget (disable, removal,
/// revoke, reload). Every end bumps a generation first, so a late unlock,
/// listing or copy cannot bring anything back.
@MainActor
final class VaultBroker {
    struct Session {
        var key: String
        var generation: UUID
        var unlockedAt: Date
        var lastUserActionAt: Date
        var idle: TimeInterval
        var max: TimeInterval
        /// Opaque handle → item id, for this session only.
        var handles: [String: String] = [:]
    }

    private var sessions: [String: Session] = [:]
    /// Bumped on every lock, so work started before it is discarded.
    private var generations: [String: UUID] = [:]
    private let provider: VaultProvider
    private let now: () -> Date
    private var observers: [NSObjectProtocol] = []
    private var sweepTimer: Timer?
    /// Asks the runtime to redraw the widget after a state change.
    var onChange: ((String) -> Void)?
    /// Shows a short message on the widget's behalf.
    var toast: (String) -> Void = { message in ToastCenter.shared.show(message) }
    /// The host-owned password prompt; nil means cancelled. Swappable in tests.
    var promptForPassword: (_ title: String, _ message: String) -> String? = VaultBroker.securePrompt
    /// Where copied fields go; a private pasteboard in tests.
    var pasteboard: NSPasteboard = .general

    init(provider: VaultProvider = BitwardenCLIProvider(), now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    func start() {
        guard observers.isEmpty else { return }
        let lockAll: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.lockAll() }
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockAll))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockAll))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main, using: lockAll))
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
    }

    func isUnlocked(_ widgetID: String) -> Bool {
        sweep()
        return sessions[widgetID] != nil
    }

    // MARK: User actions

    func unlock(widgetID: String, permission: Manifest.VaultPermission, widgetName: String) {
        guard sessions[widgetID] == nil else { return }
        let generation = generations[widgetID] ?? UUID()
        generations[widgetID] = generation
        let title = String(localized: "Unlock Bitwarden")
        let message = String(localized: "\(widgetName) asks BarShelf to unlock your vault. BarShelf passes the master password to the Bitwarden CLI, keeps only the session it returns, and locks again after \(Int(permission.idleSeconds / 60)) minutes without use.")
        guard let password = promptForPassword(title, message), !password.isEmpty else { return }
        let provider = self.provider
        Task {
            do {
                let key = try await provider.unlock(password: password)
                guard self.generations[widgetID] == generation else {
                    await provider.lock(session: key) // locked meanwhile: discard
                    return
                }
                let at = self.now()
                self.sessions[widgetID] = Session(key: key, generation: generation, unlockedAt: at,
                                                  lastUserActionAt: at, idle: permission.idleSeconds, max: permission.maxSeconds)
                self.onChange?(widgetID)
            } catch let error as VaultError {
                self.toast(error.message)
            } catch {
                self.toast(VaultError.unlockFailed.message)
            }
        }
    }

    /// Copies one field of the item a handle names to the pasteboard, marked
    /// concealed and transient, and clears it after `clearAfter` seconds if
    /// it is still there. Counts as a user action.
    func copy(widgetID: String, handle: String, field: VaultField, clearAfter: Int = 30) {
        sweep()
        guard var session = sessions[widgetID], let itemID = session.handles[handle] else {
            toast(VaultError.locked.message)
            return
        }
        session.lastUserActionAt = now()
        sessions[widgetID] = session
        let generation = session.generation
        let key = session.key
        let provider = self.provider
        Task {
            do {
                let value = try await provider.value(of: field, itemID: itemID, session: key)
                guard self.sessions[widgetID]?.generation == generation else { return }
                let pasteboard = self.pasteboard
                pasteboard.clearContents()
                pasteboard.declareTypes([.string, Self.concealedType, Self.transientType], owner: nil)
                pasteboard.setString(value, forType: .string)
                pasteboard.setString("", forType: Self.concealedType)
                pasteboard.setString("", forType: Self.transientType)
                let changeCount = pasteboard.changeCount
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(max(clearAfter, 5))) {
                    if pasteboard.changeCount == changeCount { pasteboard.clearContents() }
                }
                self.toast(Self.copiedMessage(field))
            } catch let error as VaultError {
                self.toast(error.message)
            } catch {
                self.toast(VaultError.failed.message)
            }
        }
    }

    func lock(widgetID: String) {
        end(widgetID, runProviderLock: true)
    }

    // MARK: For the workflow source

    /// The vault's state and item metadata for a widget's `vault.items`
    /// source. Not a user action: a refresh never keeps a vault unlocked.
    func itemsSource(widgetID: String) async -> JSONValue {
        sweep()
        guard let session = sessions[widgetID] else { return .object(["state": .string("locked"), "items": .array([])]) }
        let generation = session.generation
        do {
            let items = try await provider.items(session: session.key)
            guard var current = sessions[widgetID], current.generation == generation else {
                return .object(["state": .string("locked"), "items": .array([])])
            }
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
            current.handles = handles
            sessions[widgetID] = current
            return .object(["state": .string("unlocked"), "items": .array(rows),
                            "count": .number(Double(items.count)), "truncated": .bool(items.count > limit)])
        } catch let error as VaultError {
            if error == .locked { end(widgetID, runProviderLock: false) }
            return .object(["state": .string(error == .locked ? "locked" : "error"), "items": .array([]),
                            "error": .string(error.message)])
        } catch {
            return .object(["state": .string("error"), "items": .array([]), "error": .string(VaultError.failed.message)])
        }
    }

    // MARK: Ending sessions

    /// Ends every session (screen lock, sleep, quit).
    func lockAll() {
        for id in Array(sessions.keys) { end(id, runProviderLock: true) }
    }

    /// Ends one instance's session: the generation moves first, then memory
    /// is dropped, then the provider is asked to lock.
    func end(_ widgetID: String, runProviderLock: Bool) {
        generations[widgetID] = UUID()
        guard let session = sessions.removeValue(forKey: widgetID) else { return }
        if runProviderLock {
            let provider = self.provider
            let key = session.key
            Task { await provider.lock(session: key) }
        }
        onChange?(widgetID)
    }

    private func sweep() {
        let at = now()
        for (id, session) in sessions
        where at.timeIntervalSince(session.lastUserActionAt) >= session.idle
            || at.timeIntervalSince(session.unlockedAt) >= session.max {
            end(id, runProviderLock: true)
        }
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
