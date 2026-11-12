import Foundation
import MenubucketCore

/// `barshelf usage [--days N] [--json]` — what BarShelf counted about its own
/// use on this Mac (`UsageStore`), the same list as Settings ▸ Privacy.
/// Reads the file only; the CLI never counts anything itself.
public enum UsageCommand {
    public static let usage = "usage: barshelf usage [--days N] [--json]"

    public static func run(arguments: [String]) -> Int32 {
        var days = 30
        var json = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                json = true
            case "--days":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), (1...UsageLog.keepDays).contains(value) else {
                    printError("barshelf: --days takes a number from 1 to \(UsageLog.keepDays)")
                    return 1
                }
                days = value
            default:
                printError(usage)
                return 1
            }
            index += 1
        }
        let output = render(
            log: UsageStore.load(from: UsageStore.defaultFileURL()),
            widgets: installedWidgets(in: HeadlessInstaller.defaultWidgetsDirectory),
            days: days, json: json, today: UsageDay.key(Date(), calendar: .current), calendar: .current
        )
        print(output, terminator: "")
        return 0
    }

    /// Instance id → name for every widget in the folder, the way the app
    /// names instances (`<manifest id>--<suffix>` directories).
    public static func installedWidgets(in widgetsDir: URL) -> [String: String] {
        guard let discovery = try? WidgetDiscovery.discover(under: widgetsDir) else { return [:] }
        var names: [String: String] = [:]
        for candidate in discovery.candidates {
            let id = candidate.manifest.id
            let directory = candidate.directory.lastPathComponent
            let instance = directory.hasPrefix(id + "--") && directory.count > id.count + 2 ? directory : id
            names[instance] = candidate.manifest.name
        }
        return names
    }

    public static func render(
        log: UsageLog, widgets: [String: String], days: Int, json: Bool,
        today: String, calendar: Calendar
    ) -> String {
        let summary = log.summary(days: days, today: today, calendar: calendar, known: widgets.keys.sorted())
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = (try? encoder.encode(summary)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        var lines: [String] = []
        if log.days.isEmpty {
            lines.append("nothing counted yet (\(UsageStore.defaultFileURL().path))")
            lines.append("counting is local to this Mac; turn it on or off in Settings ▸ Privacy")
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("last \(summary.days) days (\(summary.from) – \(summary.to)), \(summary.activeDays) with use")
        lines.append("shelf opened \(summary.popupOpens) times")
        lines.append("")
        let used = summary.rows.filter { !$0.neverUsed }
        if !used.isEmpty {
            lines.append(["uses", "seen", "pressed", "menubar", "widget"].joined(separator: "\t"))
            for row in used {
                let name = widgets[row.widgetID].map { "\($0) (\(row.widgetID))" } ?? "\(row.widgetID) (not installed)"
                lines.append([
                    "\(row.usage.interactions)", "\(row.usage.views)", "\(row.usage.actions)",
                    "\(row.usage.menuBarClicks + row.usage.menuBarCardOpens)", name,
                ].joined(separator: "\t"))
            }
        }
        let idle = summary.neverUsed
        if !idle.isEmpty {
            if !used.isEmpty { lines.append("") }
            lines.append("not used in \(summary.days) days:")
            for row in idle {
                lines.append("  " + (widgets[row.widgetID].map { "\($0) (\(row.widgetID))" } ?? row.widgetID))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
