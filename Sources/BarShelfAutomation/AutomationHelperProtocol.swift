import Foundation
import MenubucketCore
import notify

/// How the app and the keyboard helper process talk.
///
/// The helper is the app's own executable started with `automation-helper`.
/// It has to outlive an app crash and be found again by the next app
/// instance, so nothing here depends on a pipe or a connection that dies with
/// either side: a request file and a status file in the app support folder,
/// and Darwin notifications that say "look again".
package struct AutomationHelperChannel {
    package let directory: URL
    /// Prefix of the Darwin notification names; tests use their own.
    package let prefix: String

    package init(directory: URL, prefix: String) {
        self.directory = directory
        self.prefix = prefix
    }

    package static var standard: Self {
        .init(directory: BarShelfDirectories.applicationSupport, prefix: "dev.barshelf.automation")
    }

    package var requestURL: URL { directory.appendingPathComponent("automation-request.json") }
    package var statusURL: URL { directory.appendingPathComponent("automation-status.json") }
    package var lockURL: URL { directory.appendingPathComponent("automation-helper.lock") }

    /// The app wrote a request.
    package var requestName: String { prefix + ".request" }
    /// The helper wrote its status.
    package var statusName: String { prefix + ".status" }
    /// The helper was asked to quit as if it were the app (it shares the
    /// app's name and bundle); the app should quit instead.
    package var quitAppName: String { prefix + ".quit-app" }
    /// Likewise for "open BarShelf" (a double click in Finder): macOS may
    /// hand it to the helper, and the app should show its window.
    package var reopenAppName: String { prefix + ".reopen-app" }

    package func post(_ name: String) { notify_post(name) }

    /// Calls `handler` on the main queue each time `name` is posted. Returns
    /// a token for `cancel`.
    package func observe(_ name: String, _ handler: @escaping () -> Void) -> Int32 {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        notify_register_dispatch(name, &token, .main) { _ in handler() }
        return token
    }

    package func cancel(_ token: Int32) {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }

    package func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    package func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Version and source commit of the running build. A helper left over
    /// from another build is replaced rather than adopted.
    package static var currentBuild: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let commit = info["BarShelfSourceCommit"] as? String ?? "unknown"
        return "\(version)+\(commit)"
    }

    package static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}

package struct AutomationHelperRequest: Codable, Equatable {
    package enum Kind: String, Codable {
        /// Replace the running extension with `source`, enabled.
        case apply
        /// A (new) app instance takes the helper over.
        case adopt
        /// Stop and exit. Obeyed only from the helper's current owner, so an
        /// app that is quitting cannot stop a helper its successor adopted.
        case stop
    }

    package var id: String
    package var kind: Kind
    package var appPID: Int32
    package var source: String?
    /// When it was written. The file outlives the processes; a helper never
    /// acts on a request that was waiting there before it started.
    package var sentAt: Date

    package init(id: String = UUID().uuidString, kind: Kind, appPID: Int32, source: String? = nil,
                 sentAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.appPID = appPID
        self.source = source
        self.sentAt = sentAt
    }

    /// How long a request stays valid. Answers take milliseconds.
    package static let lifetime: TimeInterval = 15
}

package struct AutomationHelperStatus: Codable, Equatable {
    package struct Binding: Codable, Equatable {
        package var keyCode: UInt32
        package var modifiers: UInt32
        package var text: String
    }

    package struct Reply: Codable, Equatable {
        package var id: String
        package var ok: Bool
    }

    package var pid: Int32
    package var ownerPID: Int32
    package var build: String
    package var isRunning: Bool
    package var enabled: Bool
    package var source: String
    package var message: String?
    package var bindings: [Binding]
    /// "idle", "checking", "changed" or "needsAttention".
    package var inputSource: String
    package var inputSourceMessage: String?
    package var reply: Reply?

    package var inputSourceStatus: AutomationInputSource.Status {
        switch inputSource {
        case "checking": return .checking
        case "changed": return .changed
        case "needsAttention": return .needsAttention(inputSourceMessage ?? "")
        default: return .idle
        }
    }

    package static func encode(_ status: AutomationInputSource.Status) -> (String, String?) {
        switch status {
        case .idle: return ("idle", nil)
        case .checking: return ("checking", nil)
        case .changed: return ("changed", nil)
        case .needsAttention(let message): return ("needsAttention", message)
        }
    }
}
