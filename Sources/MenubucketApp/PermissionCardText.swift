import Foundation
import MenubucketCore

/// The words on a permission card: what a widget asks to be allowed to do,
/// and what it is for.
enum PermissionCardText {
    /// What a widget is asking to be allowed to do, one line per capability,
    /// in words rather than raw commands. The approval card lists these.
    ///
    /// Every command is one row: what the commands do, each phrase once, with
    /// the exact command lines behind "Details". Two rows saying the same
    /// thing in different words read as two different permissions.
    static func requests(for widget: LoadedWidget) -> [PermissionRequest] {
        requests(for: widget.manifest)
    }

    static func requests(for manifest: Manifest, localization: WidgetLocalization?? = nil) -> [PermissionRequest] {
        var rows: [PermissionRequest] = []
        let permissions = manifest.permissions
        let table = localization ?? manifest.localization()
        let exec = ExecPermissionText.summary(for: manifest, localization: table)
        if let exec {
            rows.append(PermissionRequest(
                symbol: "terminal",
                description: exec.phrases.joined(separator: "\n"),
                details: exec.commandLines
            ))
        } else if manifest.entry.kind == "exec" {
            rows.append(PermissionRequest(
                symbol: "exclamationmark.triangle.fill",
                description: String(localized: "Blocked: this widget runs a command but does not say which"),
                isWarning: true
            ))
        }
        if permissions?.keychain == true {
            rows.append(PermissionRequest(symbol: "key.fill", description: String(localized: "Read and save passwords in your Keychain")))
        }
        if permissions?.notifications == true {
            rows.append(PermissionRequest(symbol: "bell.fill", description: String(localized: "Show notifications")))
        }
        if permissions?.quitApps == true {
            rows.append(PermissionRequest(symbol: "xmark.app.fill", description: String(localized: "Quit apps you choose, asking each time")))
        }
        if let net = permissions?.network, !net.isEmpty {
            let hosts = net.prefix(4).joined(separator: ", ")
            let suffix = net.count > 4 ? ", …" : ""
            rows.append(PermissionRequest(symbol: "network", description: String(localized: "Connect to \(hosts)\(suffix)")))
        }
        for path in permissions?.readPaths ?? [] {
            rows.append(PermissionRequest(symbol: "folder.fill", description: String(localized: "Read files in \(path)")))
        }
        if permissions?.storage?.granted == true {
            rows.append(PermissionRequest(symbol: "internaldrive.fill", description: String(localized: "Save a little data on this Mac", comment: "Permission: the widget keeps a small amount of its own data")))
        }
        // The widget's own variables and those a single command is handed.
        var env = permissions?.env ?? []
        for name in exec?.environment ?? [] where !env.contains(name) { env.append(name) }
        if !env.isEmpty {
            rows.append(PermissionRequest(
                symbol: "leaf.fill",
                description: String(localized: "Read settings from the environment: \(env.joined(separator: ", "))")
            ))
        }
        if let vault = permissions?.vault {
            rows.append(PermissionRequest(
                symbol: "lock.shield.fill",
                description: String(localized: "Unlock your Bitwarden vault when you ask; it locks after \(Int(vault.idleSeconds / 60)) minutes unused", comment: "Approval card: the vault permission, first of two rows")
            ))
            rows.append(PermissionRequest(
                symbol: "doc.on.doc",
                description: String(localized: "See item names and copy a username, password or code you pick", comment: "Approval card: the vault permission, second of two rows")
            ))
        }
        if rows.isEmpty {
            rows.append(PermissionRequest(symbol: "checkmark.seal.fill", description: String(localized: "No special permissions")))
        }
        return rows
    }

    /// One line on what the widget is for, shown above what it asks for: the
    /// widget.json `description` in the app's language, else the summary the
    /// gallery gives BarShelf's own widgets. The first sentence only.
    @MainActor static func purpose(for widget: LoadedWidget) -> String? {
        let key = widget.directory.path + "|" + widget.loadRevision
        if let cached = purposeCache[key] { return cached.isEmpty ? nil : cached }
        var text = widget.packageInfo.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            text = widget.manifest.localization()?.text(text) ?? text
        } else {
            text = GalleryEntryText.summary(forID: widget.manifest.id) ?? ""
        }
        text = firstSentence(text)
        purposeCache[key] = text
        return text.isEmpty ? nil : text
    }

    @MainActor private static var purposeCache: [String: String] = [:]

    static func firstSentence(_ text: String) -> String {
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
    }
}
