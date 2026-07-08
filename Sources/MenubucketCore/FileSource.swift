import Foundation

/// `fs.directory` workflow source: lists a directory into the item shape the
/// DSL contract promises (`id path name modifiedAt size isDirectory ext`).
public enum FileSource {
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
            if let count = object["limit"]?.numberValue, count > 0 {
                self.limit = Int(count)
            } else {
                self.limit = nil
            }
            self.watch = object["watch"]?.boolValue ?? false
        }
    }

    public enum FileSourceError: Error, LocalizedError, Equatable {
        case missingPath
        case notADirectory(String)

        public var errorDescription: String? {
            switch self {
            case .missingPath: return "fs.directory needs a non-empty \"path\""
            case let .notADirectory(path): return "not a directory: \(path)"
            }
        }
    }

    /// Returns `{ "items": [...], "path": "<resolved>" }`.
    public static func list(_ params: Params) throws -> JSONValue {
        let url = URL(fileURLWithPath: params.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FileSourceError.notADirectory(params.path)
        }

        let keys: [URLResourceKey] = [.nameKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: params.skipHidden ? [.skipsHiddenFiles] : []
        )

        var items: [JSONValue] = contents.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { return nil }
            let modifiedMs = (values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000
            return .object([
                "id": .string(fileURL.path),
                "path": .string(fileURL.path),
                "name": .string(values.name ?? fileURL.lastPathComponent),
                "modifiedAt": .number(modifiedMs),
                "size": .number(Double(values.fileSize ?? 0)),
                "isDirectory": .bool(values.isDirectory ?? false),
                "ext": .string(fileURL.pathExtension),
            ])
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
}
