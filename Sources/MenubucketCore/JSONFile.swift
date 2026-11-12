import Foundation

/// Reading and writing the JSON files that hold what the user set up:
/// widget preferences, permission decisions, app preferences, stats.
///
/// Each store used to hand-roll `try? Data(contentsOf:)` + `decode`, and on
/// any failure start from defaults. The next save then wrote those defaults
/// over the user's file. A file from a newer build with one value this build
/// cannot read was enough. Here a file that exists but cannot be decoded is
/// moved aside first (`prefs.json.corrupt-20261112-191600`), so starting
/// fresh never destroys it, and a failed write is logged and announced
/// (`problemNotification`) instead of vanishing in a `try?`.
public enum JSONFile {
    /// Posted (on any thread) when a file could not be read and was moved
    /// aside, or could not be written. `userInfo` carries a `Problem`.
    public static let problemNotification = Notification.Name("dev.barshelf.jsonFile.problem")

    public struct Problem: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// The file could not be decoded; it now lives at `movedTo`.
            case unreadable(movedTo: URL?)
            case writeFailed
        }

        public let kind: Kind
        public let file: URL
        public let message: String
    }

    public static let problemKey = "problem"

    /// A write refused because the file there could not be read or moved
    /// aside, so writing would replace what the user had.
    public struct ProtectedFileError: LocalizedError, Sendable {
        public let file: URL
        public var errorDescription: String? {
            "\(file.lastPathComponent) could not be read or set aside, so it was not replaced."
        }
    }

    /// Files whose load failed without a copy being kept. Writing to one is
    /// refused until it can be moved aside (permissions fixed, say).
    private final class Protected: @unchecked Sendable {
        let lock = NSLock()
        var paths: Set<String> = []
    }
    private static let protected = Protected()

    private static func protect(_ url: URL) {
        protected.lock.lock(); defer { protected.lock.unlock() }
        protected.paths.insert(url.standardizedFileURL.path)
    }

    /// Whether `url` may be written: not protected, or now moved aside.
    private static func clearToWrite(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        protected.lock.lock(); defer { protected.lock.unlock() }
        guard protected.paths.contains(path) else { return true }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            protected.paths.remove(path)
            return true
        }
        guard moveAside(url) != nil else { return false }
        protected.paths.remove(path)
        return true
    }

    /// The decoded file, or nil when there is none or it could not be
    /// decoded. A file that is there but undecodable is moved aside before
    /// returning nil, so the caller's defaults never overwrite it.
    public static func load<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        decoder: JSONDecoder = JSONDecoder(),
        now: Date = Date()
    ) -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if !isMissing(error) {
                // Present but unreadable (permissions, I/O): set aside like an
                // undecodable one. If even that fails, no write replaces it.
                let movedTo = moveAside(url, now: now)
                if movedTo == nil { protect(url) }
                let message = String(describing: error)
                NSLog("barshelf: could not read \(url.path), moved to \(movedTo?.path ?? "nowhere"): \(message)")
                post(Problem(kind: .unreadable(movedTo: movedTo), file: url, message: message))
            }
            return nil
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let movedTo = moveAside(url, now: now)
            if movedTo == nil { protect(url) }
            let message = String(describing: error)
            NSLog("barshelf: could not decode \(url.path), moved to \(movedTo?.path ?? "nowhere"): \(message)")
            post(Problem(kind: .unreadable(movedTo: movedTo), file: url, message: message))
            return nil
        }
    }

    /// Encodes `value` and writes it atomically, creating the directory.
    public static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = JSONEncoder()) throws {
        try write(encoder.encode(value), to: url)
    }

    public static func write(_ data: Data, to url: URL) throws {
        guard clearToWrite(url) else { throw ProtectedFileError(file: url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// `write`, for callers with nowhere to throw to: a failure is logged
    /// and, when `announce` is true, posted as a `Problem`. Returns whether
    /// the file was written.
    @discardableResult
    public static func save<T: Encodable>(
        _ value: T, to url: URL, encoder: JSONEncoder = JSONEncoder(), announce: Bool = true
    ) -> Bool {
        do {
            try write(value, to: url, encoder: encoder)
            return true
        } catch {
            reportWriteFailure(url, error: error, announce: announce)
            return false
        }
    }

    public static func reportWriteFailure(_ url: URL, error: Error, announce: Bool = true) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        NSLog("barshelf: could not write \(url.path): \(error)")
        if announce { post(Problem(kind: .writeFailed, file: url, message: message)) }
    }

    /// Renames `url` to `<name>.corrupt-<yyyyMMdd-HHmmss>` beside it (with a
    /// counter if that exists). Returns the new location, or nil if the move
    /// failed.
    @discardableResult
    public static func moveAside(_ url: URL, now: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.path + ".corrupt-" + formatter.string(from: now)
        let fm = FileManager.default
        var candidate = base
        var counter = 2
        while fm.fileExists(atPath: candidate) {
            candidate = base + "-\(counter)"
            counter += 1
        }
        do {
            try fm.moveItem(atPath: url.path, toPath: candidate)
            return URL(fileURLWithPath: candidate)
        } catch {
            NSLog("barshelf: could not move \(url.path) aside: \(error)")
            return nil
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissing(underlying)
        }
        return false
    }

    private static func post(_ problem: Problem) {
        NotificationCenter.default.post(
            name: problemNotification, object: nil, userInfo: [problemKey: problem]
        )
    }
}

/// An array decoded element by element: one element this build cannot read
/// is dropped instead of failing the whole array.
public struct LenientArray<Element: Decodable>: Decodable {
    public let elements: [Element]

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            // A decoder of its own per element always moves on, even past a
            // value nothing can decode (`1e400`): decoding the element from
            // the container directly would not, and loop forever.
            let element = try container.superDecoder()
            if let value = try? Element(from: element) {
                elements.append(value)
            }
        }
        self.elements = elements
    }
}

/// A string-keyed dictionary decoded entry by entry: one entry this build
/// cannot read is dropped instead of failing the whole dictionary.
public struct LenientDictionary<Value: Decodable>: Decodable {
    public let entries: [String: Value]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var entries: [String: Value] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) {
                entries[key.stringValue] = value
            }
        }
        self.entries = entries
    }
}

extension KeyedDecodingContainer {
    /// The value at `key`, or nil when it is missing, null, or of a type this
    /// build cannot read: one bad field never costs the rest of the file.
    public func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// A dictionary at `key`, keeping every entry this build can read.
    public func lenientDictionary<V: Decodable>(_ type: V.Type, forKey key: Key) -> [String: V]? {
        lenient(LenientDictionary<V>.self, forKey: key)?.entries
    }

    /// An array at `key`, keeping every element this build can read.
    public func lenientArray<E: Decodable>(_ type: E.Type, forKey key: Key) -> [E]? {
        lenient(LenientArray<E>.self, forKey: key)?.elements
    }
}
