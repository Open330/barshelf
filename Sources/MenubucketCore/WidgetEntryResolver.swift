import Foundation

/// Resolves a manifest entry file without allowing absolute paths, `..`, or
/// symlink escapes outside the widget package.
public enum WidgetEntryResolver {
    public enum ResolutionError: Error, LocalizedError, Equatable {
        case invalid(String)
        case outsidePackage(String)

        public var errorDescription: String? {
            switch self {
            case let .invalid(path):
                return "invalid entry.main \"\(path)\" (expected a relative package path)"
            case let .outsidePackage(path):
                return "entry.main \"\(path)\" resolves outside the widget package"
            }
        }
    }

    public static func resolve(
        directory: URL,
        main: String?,
        defaultName: String
    ) throws -> URL {
        let relative = (main ?? defaultName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relative.isEmpty, !relative.hasPrefix("/") else {
            throw ResolutionError.invalid(relative)
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard target.path != root.path, target.path.hasPrefix(root.path + "/") else {
            throw ResolutionError.outsidePackage(relative)
        }
        return target
    }
}
