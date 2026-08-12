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

        public var errorDescription: String? {
            switch self {
            case .missingPath: return "fs.directory needs a non-empty \"path\""
            case let .notADirectory(path): return "not a directory: \(path)"
            case let .unauthorizedPath(path):
                return "path is not covered by permissions.readPaths: \(path)"
            case let .posix(path, code):
                return "filesystem access failed for \(path): \(String(cString: strerror(code)))"
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
