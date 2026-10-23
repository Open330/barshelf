import Foundation

/// `localizations` in widget.json: a widget's display text in other
/// languages, keyed by language and then by the exact English text it
/// replaces.
///
/// ```json
/// "localizations": {
///   "ko": {
///     "Recent Files": "최근 파일",
///     "${count(sources.files.items)} files": "파일 ${count(sources.files.items)}개"
///   }
/// }
/// ```
///
/// Workflow templates are translated before expansion, as whole strings, so
/// a translation can reorder an expression but never sees the user's data.
/// Only display text is looked up — the widget's name, setting titles and
/// option titles, and the workflow's view text, titles, labels, placeholders,
/// accessibility labels and status label/tooltip. Commands, actions, paths,
/// URLs, setting values and the permission set are never touched, so the
/// permission hash and everything a widget runs stay the same in every
/// language.
///
/// Decoded leniently: a language that is not an object, or an entry that is
/// not a non-empty string, is dropped.
public struct WidgetLocalizations: Codable, Equatable, Sendable {
    /// Language (`ko`, `ko-KR`) → English text → translated text.
    public var tables: [String: [String: String]]

    public init(_ tables: [String: [String: String]] = [:]) {
        self.tables = tables
    }

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode([String: JSONValue].self)) ?? [:]
        var tables: [String: [String: String]] = [:]
        for (language, value) in raw {
            guard case let .object(entries) = value else { continue }
            var table: [String: String] = [:]
            for (source, translation) in entries {
                if case let .string(text) = translation, !text.isEmpty { table[source] = text }
            }
            if !table.isEmpty { tables[language] = table }
        }
        self.tables = tables
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tables)
    }

    /// The table for `language`: an exact match (`ko-KR`), then its base
    /// language (`ko`), then any regional table of that language. Nil means
    /// the English text stands.
    public func localization(for language: String) -> WidgetLocalization? {
        let wanted = Self.normalized(language)
        let base = Self.baseLanguage(wanted)
        let keyed = tables.map { (key: Self.normalized($0.key), table: $0.value) }
            .sorted { $0.key < $1.key }
        let table = keyed.first { $0.key == wanted }?.table
            ?? keyed.first { $0.key == base }?.table
            ?? keyed.first { Self.baseLanguage($0.key) == base }?.table
        return table.map { WidgetLocalization(table: $0) }
    }

    private static func normalized(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func baseLanguage(_ language: String) -> String {
        String(language.split(separator: "-", maxSplits: 1).first ?? Substring(language))
    }
}

/// One language's table, applied to a manifest or workflow.
public struct WidgetLocalization: Equatable, Sendable {
    public let table: [String: String]

    public init(table: [String: String]) {
        self.table = table
    }

    /// The language BarShelf's own interface is shown in, so a widget never
    /// speaks a different language than the app around it.
    public static var appLanguage: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// The translation of `text`, or `text` itself. A translated template must
    /// use exactly the same `${…}` expressions as its source: one that drops,
    /// adds or alters an expression is ignored rather than shown.
    public func text(_ text: String) -> String {
        guard let translated = table[text] else { return text }
        guard text.contains("${") || translated.contains("${") else { return translated }
        return Self.expressions(in: text) == Self.expressions(in: translated) ? translated : text
    }

    // MARK: Manifest

    /// The manifest with its display text translated: the name, setting
    /// titles/labels and option titles. Everything else is the original.
    public func manifest(_ manifest: Manifest) -> Manifest {
        var localized = manifest
        localized.name = text(manifest.name)
        localized.settings = manifest.settings.map { settings($0) }
        return localized
    }

    /// Setting titles, labels and option titles. Stored option values stay as
    /// they are; when the author gave no option titles, translated values
    /// become the titles shown for them.
    public func settings(_ settings: [Manifest.Setting]) -> [Manifest.Setting] {
        settings.map { setting in
            var localized = setting
            localized.title = setting.title.map(text)
            localized.label = setting.label.map(text)
            if let titles = setting.optionTitles {
                localized.optionTitles = titles.map(text)
            } else if let options = setting.options, options.contains(where: { table[$0] != nil }) {
                localized.optionTitles = options.map(text)
            }
            return localized
        }
    }

    // MARK: Workflow

    /// View-tree keys whose string values are display text.
    static let textKeys: Set<String> = [
        "text", "title", "subtitle", "label", "searchPlaceholder", "accessibilityLabel", "hint",
    ]
    /// Subtrees that carry behavior or data, never display text.
    static let skippedKeys: Set<String> = ["action", "source", "drag", "value"]

    /// The workflow with its view, empty state and status text translated.
    /// Sources, transforms and storage are the original.
    public func workflow(_ definition: WorkflowDefinition) -> WorkflowDefinition {
        var localized = definition
        localized.view = view(definition.view)
        localized.empty = definition.empty.map { view($0) }
        if var status = definition.status {
            status.label = status.label.map(text)
            status.tooltip = status.tooltip.map(text)
            status.prefix = status.prefix.map(text)
            status.metrics = status.metrics?.map { metric in
                var metric = metric
                metric.label = metric.label.map(text)
                metric.accessibilityLabel = metric.accessibilityLabel.map(text)
                return metric
            }
            localized.status = status
        }
        return localized
    }

    /// A view tree (or template) with display text translated.
    public func view(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .array(items):
            return .array(items.map { view($0) })
        case let .object(object):
            var out: [String: JSONValue] = [:]
            for (key, item) in object {
                if Self.skippedKeys.contains(key) {
                    out[key] = item
                } else if Self.textKeys.contains(key), case let .string(string) = item {
                    out[key] = .string(text(string))
                } else {
                    out[key] = view(item)
                }
            }
            return .object(out)
        default:
            return value
        }
    }

    /// The `${…}` expressions in a template, sorted so a translation may
    /// reorder them. Mirrors the engine: an expression ends at the first `}`.
    static func expressions(in template: String) -> [String] {
        var found: [String] = []
        var rest = Substring(template)
        while let start = rest.range(of: "${") {
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else {
                found.append(String(rest[start.lowerBound...]))
                break
            }
            found.append(String(rest[start.upperBound..<end]))
            rest = rest[rest.index(after: end)...]
        }
        return found.sorted()
    }
}

extension Manifest {
    /// This manifest's table for `language` (default: the app's language).
    public func localization(for language: String = WidgetLocalization.appLanguage) -> WidgetLocalization? {
        localizations?.localization(for: language)
    }

    /// The name shown to the user in `language`.
    public func localizedName(for language: String = WidgetLocalization.appLanguage) -> String {
        localization(for: language)?.text(name) ?? name
    }
}
