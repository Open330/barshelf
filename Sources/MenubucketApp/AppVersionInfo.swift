import Foundation

/// Display-safe version metadata from the running app bundle.
///
/// Packaged builds receive both values from `scripts/Info.plist.template`.
/// Plain `swift run barshelf-app` builds do not have those keys, so the
/// settings UI explicitly identifies them as development builds.
struct AppVersionInfo: Equatable {
    let version: String?
    let build: String?
    /// Git commit the packaged build came from (`BarShelfSourceCommit`), so a
    /// binary can be traced back to source. Absent for `swift run` builds and
    /// for anything packaged before provenance was recorded.
    let sourceCommit: String?

    static var current: AppVersionInfo {
        AppVersionInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        version = Self.nonEmptyString(
            infoDictionary["CFBundleShortVersionString"]
        )
        build = Self.nonEmptyString(infoDictionary["CFBundleVersion"])
        sourceCommit = Self.nonEmptyString(infoDictionary["BarShelfSourceCommit"])
    }

    var versionLabel: String {
        version ?? "Development build"
    }

    /// True when the build was packaged from a working tree with uncommitted
    /// changes. `build_app.sh` records that rather than hiding it.
    var isFromDirtyTree: Bool {
        sourceCommit?.hasSuffix("-dirty") == true
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
