import Darwin
import Foundation

/// `fs.directory` workflow source: lists a directory into the item shape the
/// DSL contract promises (`id path name modifiedAt size isDirectory ext`).
public enum FileSource {
    /// An already-open directory that was proven to be the same filesystem
    /// object as, or a descendant of, one of the declared read roots. Keeping
    /// the descriptor open binds subsequent listing/watching to that object,
    /// even if a path component is replaced with a symlink afterwards.
    public final class AuthorizedDirectory: @unchecked Sendable {
        public let path: String
        fileprivate let fileDescriptor: Int32

        fileprivate init(path: String, fileDescriptor: Int32) {
            self.path = path
            self.fileDescriptor = fileDescriptor
        }

        public func duplicateFileDescriptor() throws -> Int32 {
            let duplicate = fcntl(fileDescriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else {
                throw FileSourceError.posix(path, errno)
            }
            return duplicate
        }

        deinit {
            Darwin.close(fileDescriptor)
        }
    }

    public struct AuthorizedListing: Sendable {
        public let value: JSONValue
        public let directory: AuthorizedDirectory
    }

    public struct Params: Sendable {
        public var path: String
        public var skipHidden: Bool
        public var sortBy: String
        public var sortDirection: String
        public var limit: Int?
        public var watch: Bool

        public init(from params: JSONValue) throws {
            guard let object = params.objectValue,
                  let path = object["path"]?.stringValue, !path.isEmpty else {
                throw FileSourceError.missingPath
            }
            self.path = (path as NSString).expandingTildeInPath
            self.skipHidden = object["skipHidden"]?.boolValue ?? true
            self.sortBy = object["sortBy"]?.stringValue ?? "modifiedAt"
            self.sortDirection = object["sortDirection"]?.stringValue ?? "descending"
            // `Int(count)` traps on non-finite or out-of-range values; a JSON
            // `1e19` is representable as Double but exceeds `Int.max`.
            if let count = object["limit"]?.numberValue, count.isFinite, count > 0 {
                self.limit = count >= Double(Int.max) ? Int.max : Int(count)
            } else {
                self.limit = nil
            }
            self.watch = object["watch"]?.boolValue ?? false
        }
    }

    public enum FileSourceError: Error, LocalizedError, Equatable {
        case missingPath
        case notADirectory(String)
        case unauthorizedPath(String)
        case posix(String, Int32)
        case notARegularFile(String)
        case tooLarge(String, Int)
        case badFileName(String)
        case badMaxBytes(Int)

        public var errorDescription: String? {
            switch self {
            case .missingPath: return "fs.directory needs a non-empty \"path\""
            case let .notADirectory(path): return "not a directory: \(path)"
            case let .unauthorizedPath(path):
                return "path is not covered by permissions.readPaths: \(path)"
            case let .posix(path, code):
                return "filesystem access failed for \(path): \(String(cString: strerror(code)))"
            case let .notARegularFile(path): return "not a regular file: \(path)"
            case let .tooLarge(path, limit): return "\(path) is larger than \(limit) bytes"
            case let .badFileName(path): return "fs.json needs a file path, got \(path)"
            case let .badMaxBytes(cap): return "fs.json maxBytes must be a whole number from 1 to \(cap)"
            }
        }
    }

    /// Returns `{ "items": [...], "path": "<resolved>" }`.
    public static func list(_ params: Params) throws -> JSONValue {
        let directory = try openDirectory(path: params.path)
        return try list(params, in: directory)
    }

    /// Opens and authorizes the requested directory as one operation. Both
    /// target and allowlist roots are compared by device/inode while open, so
    /// no canonical-path check is separated from a later raw-path open.
    public static func openAuthorizedDirectory(
        path: String,
        readPaths: [String]
    ) throws -> AuthorizedDirectory {
        let directory = try openDirectory(path: path)
        guard readPaths.contains(where: { contains(directory, inRootAtPath: $0) }) else {
            throw FileSourceError.unauthorizedPath(path)
        }
        return directory
    }

    /// Runtime entry point for an authorized `fs.directory` source. The
    /// returned handle is the same handle used to produce the listing and can
    /// be retained by the watcher without reopening the manifest path.
    public static func list(
        _ params: Params,
        authorizedBy readPaths: [String]
    ) throws -> AuthorizedListing {
        let directory = try openAuthorizedDirectory(path: params.path, readPaths: readPaths)
        return AuthorizedListing(value: try list(params, in: directory), directory: directory)
    }

    /// Lists relative to the authorized descriptor. Exposed so tests and the
    /// watcher boundary can prove that a later symlink substitution does not
    /// change the object being accessed.
    public static func list(_ params: Params, in directory: AuthorizedDirectory) throws -> JSONValue {
        let listingDescriptor = Darwin.openat(
            directory.fileDescriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard listingDescriptor >= 0 else {
            throw FileSourceError.posix(directory.path, errno)
        }
        guard let stream = fdopendir(listingDescriptor) else {
            let code = errno
            Darwin.close(listingDescriptor)
            throw FileSourceError.posix(directory.path, code)
        }
        defer { closedir(stream) }

        var items: [JSONValue] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || (params.skipHidden && name.hasPrefix(".")) {
                continue
            }

            var status = stat()
            let statusResult = name.withCString {
                fstatat(directory.fileDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0 else { continue }

            let fileURL = URL(fileURLWithPath: directory.path, isDirectory: true)
                .appendingPathComponent(name)
            let modifiedMs = (
                Double(status.st_mtimespec.tv_sec)
                    + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
            ) * 1000
            items.append(.object([
                "id": .string(fileURL.path),
                "path": .string(fileURL.path),
                "name": .string(name),
                "modifiedAt": .number(modifiedMs),
                "size": .number(Double(status.st_size)),
                "isDirectory": .bool((status.st_mode & S_IFMT) == S_IFDIR),
                "ext": .string(fileURL.pathExtension),
            ]))
        }

        let descending = params.sortDirection == "descending"
        let by = params.sortBy
        items.sort { lhs, rhs in
            let left = lhs.objectValue?[by] ?? .null
            let right = rhs.objectValue?[by] ?? .null
            let ascending: Bool
            if let ln = left.numberValue, let rn = right.numberValue {
                ascending = ln < rn
            } else {
                ascending = (left.stringValue ?? "") < (right.stringValue ?? "")
            }
            return descending ? !ascending : ascending
        }

        if let limit = params.limit {
            items = Array(items.prefix(limit))
        }
        return .object(["items": .array(items), "path": .string(params.path)])
    }

    // MARK: - fs.json

    /// `fs.json` parameters: one small JSON file a widget reads instead of
    /// spawning a process to `cat` it.
    public struct JSONFileParams: Sendable, Equatable {
        public static let defaultMaxBytes = 1 << 20
        public static let maxBytesCap = 5 << 20

        public var path: String
        public var maxBytes: Int

        public init(from params: JSONValue) throws {
            guard let object = params.objectValue,
                  let path = object["path"]?.stringValue, !path.isEmpty else {
                throw FileSourceError.missingPath
            }
            guard !path.contains("\0") else { throw FileSourceError.badFileName(path) }
            self.path = (path as NSString).expandingTildeInPath
            switch object["maxBytes"] {
            case nil, .some(.null):
                self.maxBytes = Self.defaultMaxBytes
            case let .some(.number(limit))
                where limit.isFinite && limit >= 1 && limit == limit.rounded() && limit <= Double(Self.maxBytesCap):
                self.maxBytes = Int(limit)
            default:
                throw FileSourceError.badMaxBytes(Self.maxBytesCap)
            }
        }
    }

    /// Reads one JSON file under `readPaths`.
    ///
    /// A missing or unparsable file is a reading, not an error: a widget that
    /// watches another program's state file has to say "not installed" or
    /// "garbled" rather than fail. The result is always
    /// `{ exists, valid, value, modifiedAt, size, path }`.
    ///
    /// Access is bound the way `fs.directory` binds it: the parent directory
    /// is opened and proven to sit inside a read root by device/inode, then
    /// the file is opened relative to that descriptor without following a
    /// symlink. No pathname is reopened after the check. A parent that does
    /// not exist yet can't be walked, so it counts as missing only when the
    /// path lies lexically inside a root; anything else is unauthorized, as
    /// it would be if the folder existed.
    public static func readJSON(
        _ params: JSONFileParams,
        authorizedBy readPaths: [String]
    ) throws -> JSONValue {
        let url = URL(fileURLWithPath: params.path).standardizedFileURL
        let name = url.lastPathComponent
        guard !params.path.hasSuffix("/"), !name.isEmpty, name != ".", name != "..", name != "/" else {
            throw FileSourceError.badFileName(params.path)
        }
        let parentPath = url.deletingLastPathComponent().path
        let directory: AuthorizedDirectory
        do {
            directory = try openAuthorizedDirectory(path: parentPath, readPaths: readPaths)
        } catch FileSourceError.notADirectory {
            guard missingIsAuthorized(url, readPaths: readPaths) else {
                throw FileSourceError.unauthorizedPath(params.path)
            }
            return missing(params.path)
        }
        return try readJSON(named: name, in: directory, displayPath: params.path, maxBytes: params.maxBytes)
    }

    /// Reads `name` relative to an authorized directory. Exposed for tests.
    public static func readJSON(
        named name: String,
        in directory: AuthorizedDirectory,
        displayPath: String,
        maxBytes: Int
    ) throws -> JSONValue {
        let descriptor = name.withCString {
            Darwin.openat(directory.fileDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return missing(displayPath)
            // A symlink (ELOOP with O_NOFOLLOW), or a socket or device
            // that refuses a plain open: not a file this source reads.
            case ELOOP, EOPNOTSUPP, ENXIO, ENODEV: throw FileSourceError.notARegularFile(displayPath)
            default: throw FileSourceError.posix(displayPath, errno)
            }
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw FileSourceError.posix(displayPath, errno) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw FileSourceError.notARegularFile(displayPath) }
        guard status.st_size <= off_t(maxBytes) else { throw FileSourceError.tooLarge(displayPath, maxBytes) }

        // Read to EOF but never past the cap: the file can grow between the
        // fstat and the read.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw FileSourceError.posix(displayPath, errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.count > maxBytes { throw FileSourceError.tooLarge(displayPath, maxBytes) }
        }

        let modifiedMs = (
            Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
        ) * 1000
        let value = try? JSONValue.parse(data)
        return .object([
            "exists": .bool(true),
            "valid": .bool(value != nil),
            "value": value ?? .null,
            "modifiedAt": .number(modifiedMs),
            "size": .number(Double(data.count)),
            "path": .string(displayPath),
        ])
    }

    private static func missing(_ path: String) -> JSONValue {
        .object([
            "exists": .bool(false), "valid": .bool(false), "value": .null,
            "modifiedAt": .null, "size": .null, "path": .string(path),
        ])
    }

    /// A file whose folder does not exist is "missing" only when it would be
    /// readable if it did. The path has to lie inside a root by name, and the
    /// nearest folder on the way that does exist must either pass the same
    /// device/inode check as a real read (it sits at or under the root) or be
    /// a folder above a root that is itself absent, so nothing under the root
    /// can exist yet. That is the "app not installed" case: its whole support
    /// folder is gone.
    private static func missingIsAuthorized(_ url: URL, readPaths: [String]) -> Bool {
        let target = url.pathComponents
        let roots = readPaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.pathComponents
        }
        let covering = roots.filter { target.count > $0.count && Array(target.prefix($0.count)) == $0 }
        guard !covering.isEmpty else { return false }

        var ancestor = url.deletingLastPathComponent()
        while ancestor.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: ancestor.path, isDirectory: &isDirectory) { break }
            ancestor = ancestor.deletingLastPathComponent()
        }
        let depth = ancestor.pathComponents.count
        if covering.contains(where: { depth < $0.count }) {
            // Above a root, so that root is absent.
            return true
        }
        return (try? openAuthorizedDirectory(path: ancestor.path, readPaths: readPaths)) != nil
    }

    private static func openDirectory(path: String) throws -> AuthorizedDirectory {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                throw FileSourceError.notADirectory(path)
            }
            throw FileSourceError.posix(path, errno)
        }
        return AuthorizedDirectory(path: path, fileDescriptor: descriptor)
    }

    /// Walks from the bound target descriptor to the filesystem root using
    /// `openat("..")`, comparing stable device/inode identities to the open
    /// allowlist root. No pathname is reopened after authorization succeeds.
    private static func contains(
        _ target: AuthorizedDirectory,
        inRootAtPath rootPath: String
    ) -> Bool {
        guard let root = try? openDirectory(
            path: (rootPath as NSString).expandingTildeInPath
        ),
        let rootIdentity = identity(of: root.fileDescriptor),
        var current = try? target.duplicateFileDescriptor()
        else { return false }
        defer { Darwin.close(current) }

        while let currentIdentity = identity(of: current) {
            if currentIdentity == rootIdentity { return true }
            let parent = Darwin.openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0, let parentIdentity = identity(of: parent) else {
                if parent >= 0 { Darwin.close(parent) }
                return false
            }
            if parentIdentity == currentIdentity {
                Darwin.close(parent)
                return false
            }
            Darwin.close(current)
            current = parent
        }
        return false
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func identity(of descriptor: Int32) -> FileIdentity? {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return nil }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }
}
