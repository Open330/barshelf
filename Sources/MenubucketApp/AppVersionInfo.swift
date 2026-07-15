import Foundation

/// Display-safe version metadata from the running app bundle.
///
/// Packaged builds receive both values from `scripts/Info.plist.template`.
/// Plain `swift run barshelf-app` builds do not have those keys, so the
/// settings UI explicitly identifies them as development builds.
struct AppVersionInfo: Equatable {
    let version: String?
    let build: String?

    static var current: AppVersionInfo {
        AppVersionInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        version = Self.nonEmptyString(
            infoDictionary["CFBundleShortVersionString"]
        )
        build = Self.nonEmptyString(infoDictionary["CFBundleVersion"])
    }

    var versionLabel: String {
        version ?? "Development build"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
