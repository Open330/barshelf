import Foundation

/// What BarShelf counts about its own use, on this Mac only.
///
/// The point is evidence for the owner: which widgets earn their place and
/// which have never been opened. Counts are per local day, kept for
/// `UsageLog.keepDays`, and written to `usage.json` beside the other
/// preferences. Nothing here touches the network, and no value a widget
/// shows is ever recorded — only that something was opened or pressed.
public enum UsageEvent: String, Codable, CaseIterable, Sendable {
    /// The shelf popup opened. Not tied to a widget.
    case popupOpen
    /// A widget's card was on the visible page when the shelf opened.
    case view
    /// A button or row in a widget ran an action (copy, open, run, …).
    case action
    /// The widget's own menu bar item or cluster chip was clicked and did
    /// what its settings say (refresh, open a target, the hub). A click that
    /// opens the card counts as `menuBarCardOpen` only, never as both.
    case menuBarClick
    /// The widget's card opened from the menu bar.
    case menuBarCardOpen
}

/// One widget's counts for one day (or summed over several).
public struct WidgetUsage: Codable, Equatable, Sendable {
    public var views: Int
    public var actions: Int
    public var menuBarClicks: Int
    public var menuBarCardOpens: Int

    public init(views: Int = 0, actions: Int = 0, menuBarClicks: Int = 0, menuBarCardOpens: Int = 0) {
        self.views = views
        self.actions = actions
        self.menuBarClicks = menuBarClicks
        self.menuBarCardOpens = menuBarCardOpens
    }

    /// Deliberate interactions; a view alone is not one.
    public var interactions: Int { actions + menuBarClicks + menuBarCardOpens }

    public var isEmpty: Bool { views == 0 && interactions == 0 }

    mutating func add(_ event: UsageEvent, count: Int = 1) {
        switch event {
        case .popupOpen: break
        case .view: views += count
        case .action: actions += count
        case .menuBarClick: menuBarClicks += count
        case .menuBarCardOpen: menuBarCardOpens += count
        }
    }

    mutating func add(_ other: WidgetUsage) {
        views += other.views
        actions += other.actions
        menuBarClicks += other.menuBarClicks
        menuBarCardOpens += other.menuBarCardOpens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        views = (try? c.decodeIfPresent(Int.self, forKey: .views)) ?? 0
        actions = (try? c.decodeIfPresent(Int.self, forKey: .actions)) ?? 0
        menuBarClicks = (try? c.decodeIfPresent(Int.self, forKey: .menuBarClicks)) ?? 0
        menuBarCardOpens = (try? c.decodeIfPresent(Int.self, forKey: .menuBarCardOpens)) ?? 0
    }
}

/// One local day.
public struct DayUsage: Codable, Equatable, Sendable {
    public var popupOpens: Int
    public var widgets: [String: WidgetUsage]

    public init(popupOpens: Int = 0, widgets: [String: WidgetUsage] = [:]) {
        self.popupOpens = popupOpens
        self.widgets = widgets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        popupOpens = (try? c.decodeIfPresent(Int.self, forKey: .popupOpens)) ?? 0
        widgets = (try? c.decodeIfPresent([String: WidgetUsage].self, forKey: .widgets)) ?? [:]
    }
}

/// The whole file: days keyed `yyyy-MM-dd` in the Mac's own time zone.
public struct UsageLog: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Days kept; older ones are dropped on the next write.
    public static let keepDays = 90
    /// A cap on widget entries per day, so a runaway caller (thousands of
    /// throwaway instance ids) cannot grow the file without bound.
    public static let maxWidgetsPerDay = 500

    public var version: Int
    /// The first day anything was counted, so "never used" can say since when.
    public var since: String?
    public var days: [String: DayUsage]

    public init(since: String? = nil, days: [String: DayUsage] = [:]) {
        self.version = Self.currentVersion
        self.since = since
        self.days = days
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        since = try? c.decodeIfPresent(String.self, forKey: .since)
        days = (try? c.decodeIfPresent([String: DayUsage].self, forKey: .days)) ?? [:]
    }

    /// Adds `count` of `event` on `day`. Widget events without an id are
    /// ignored, as is a new widget on a day already at the cap.
    public mutating func record(_ event: UsageEvent, widgetID: String?, day: String, count: Int = 1) {
        guard count > 0 else { return }
        if since == nil || (since ?? "") > day { since = day }
        var entry = days[day] ?? DayUsage()
        if event == .popupOpen {
            entry.popupOpens += count
        } else {
            guard let widgetID, !widgetID.isEmpty else { return }
            if entry.widgets[widgetID] == nil, entry.widgets.count >= Self.maxWidgetsPerDay { return }
            entry.widgets[widgetID, default: WidgetUsage()].add(event, count: count)
        }
        days[day] = entry
    }

    /// Drops days before the first of the last `keepDays` days ending `today`.
    public mutating func prune(today: String, calendar: Calendar, keepDays: Int = UsageLog.keepDays) {
        guard let todayDate = UsageDay.date(today, calendar: calendar),
              let cutoffDate = calendar.date(byAdding: .day, value: -(keepDays - 1), to: todayDate)
        else { return }
        let cutoff = UsageDay.key(cutoffDate, calendar: calendar)
        days = days.filter { $0.key >= cutoff }
        if let since, since < cutoff { self.since = cutoff }
    }

    /// Counts over the `days` days ending `today`, every widget in `known`
    /// listed even when it has no counts. Most used first; ties by id.
    public func summary(days window: Int, today: String, calendar: Calendar, known: [String] = []) -> UsageSummary {
        let window = max(1, window)
        let todayDate = UsageDay.date(today, calendar: calendar) ?? Date()
        let firstDate = calendar.date(byAdding: .day, value: -(window - 1), to: todayDate) ?? todayDate
        let first = UsageDay.key(firstDate, calendar: calendar)
        var popupOpens = 0
        var totals: [String: WidgetUsage] = [:]
        for id in known { totals[id] = WidgetUsage() }
        var activeDays = 0
        for (day, entry) in days where day >= first && day <= today {
            popupOpens += entry.popupOpens
            if entry.popupOpens > 0 || !entry.widgets.isEmpty { activeDays += 1 }
            for (id, usage) in entry.widgets { totals[id, default: WidgetUsage()].add(usage) }
        }
        let knownSet = Set(known)
        let rows = totals.map { UsageSummary.Row(widgetID: $0.key, usage: $0.value, installed: known.isEmpty || knownSet.contains($0.key)) }
            .sorted {
                if $0.usage.interactions != $1.usage.interactions { return $0.usage.interactions > $1.usage.interactions }
                if $0.usage.views != $1.usage.views { return $0.usage.views > $1.usage.views }
                return $0.widgetID < $1.widgetID
            }
        let start = max(first, since ?? today)
        return UsageSummary(from: start, to: today, days: window, popupOpens: popupOpens, activeDays: activeDays, rows: rows)
    }
}

/// What `UsageLog.summary` returns; also the shape of `barshelf usage --json`.
public struct UsageSummary: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var widgetID: String
        public var usage: WidgetUsage
        /// False for a widget that has counts but is no longer installed.
        public var installed: Bool

        /// Neither used nor even seen on an open shelf.
        public var neverUsed: Bool { usage.isEmpty }
        /// Seen on the shelf, never pressed or opened.
        public var onlySeen: Bool { usage.interactions == 0 && usage.views > 0 }

        enum CodingKeys: String, CodingKey { case widgetID = "widgetId", usage, installed, neverUsed, onlySeen }

        public init(widgetID: String, usage: WidgetUsage, installed: Bool) {
            self.widgetID = widgetID
            self.usage = usage
            self.installed = installed
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            widgetID = try c.decode(String.self, forKey: .widgetID)
            usage = try c.decode(WidgetUsage.self, forKey: .usage)
            installed = (try? c.decodeIfPresent(Bool.self, forKey: .installed)) ?? true
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(widgetID, forKey: .widgetID)
            try c.encode(usage, forKey: .usage)
            try c.encode(installed, forKey: .installed)
            try c.encode(neverUsed, forKey: .neverUsed)
            try c.encode(onlySeen, forKey: .onlySeen)
        }
    }

    /// First and last day covered (`yyyy-MM-dd`); `from` is never before
    /// counting started.
    public var from: String
    public var to: String
    public var days: Int
    public var popupOpens: Int
    /// Days in the window with anything counted.
    public var activeDays: Int
    public var rows: [Row]

    public init(from: String, to: String, days: Int, popupOpens: Int, activeDays: Int, rows: [Row]) {
        self.from = from
        self.to = to
        self.days = days
        self.popupOpens = popupOpens
        self.activeDays = activeDays
        self.rows = rows
    }

    public var neverUsed: [Row] { rows.filter { $0.installed && $0.neverUsed } }

    /// Whether counting has been going for the whole window. When it has
    /// not, "not used in 30 days" would claim more than is known: counts that
    /// began this week can only say "not used since Monday".
    public func coversWholeWindow(calendar: Calendar) -> Bool {
        guard let first = UsageDay.date(from, calendar: calendar),
              let last = UsageDay.date(to, calendar: calendar),
              let span = calendar.dateComponents([.day], from: first, to: last).day else { return true }
        return span + 1 >= days
    }
}

/// `yyyy-MM-dd` day keys in a given calendar, without a shared formatter.
public enum UsageDay {
    public static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// The file behind `UsageLog`, shared by the app (which writes) and the CLI
/// (which reads). Writes are batched: a burst of events costs one write a
/// few seconds later, and `flush()` writes at once (on quit, in tests).
public final class UsageStore: @unchecked Sendable {
    public static func defaultFileURL() -> URL {
        BarShelfDirectories.applicationSupport.appendingPathComponent("usage.json")
    }

    public let fileURL: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let writeDelay: TimeInterval
    private let queue = DispatchQueue(label: "dev.barshelf.usage")
    private let lock = NSLock()
    private var log: UsageLog
    private var dirty = false
    private var writeScheduled = false

    public init(
        fileURL: URL = UsageStore.defaultFileURL(),
        calendar: Calendar = .current,
        writeDelay: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.calendar = calendar
        self.writeDelay = writeDelay
        self.now = now
        self.log = Self.load(from: fileURL)
    }

    /// The file's contents; an unreadable or missing file is an empty log.
    public static func load(from fileURL: URL) -> UsageLog {
        guard let data = try? Data(contentsOf: fileURL),
              let log = try? JSONDecoder().decode(UsageLog.self, from: data)
        else { return UsageLog() }
        return log
    }

    public var today: String { UsageDay.key(now(), calendar: calendar) }

    public func record(_ event: UsageEvent, widgetID: String? = nil, count: Int = 1) {
        lock.lock()
        log.record(event, widgetID: widgetID, day: today, count: count)
        dirty = true
        let schedule = !writeScheduled
        writeScheduled = true
        lock.unlock()
        if schedule {
            queue.asyncAfter(deadline: .now() + writeDelay) { [weak self] in self?.flush() }
        }
    }

    public func snapshot() -> UsageLog {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    public func summary(days: Int = 30, known: [String] = []) -> UsageSummary {
        snapshot().summary(days: days, today: today, calendar: calendar, known: known)
    }

    /// Forgets everything and removes the file.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        log = UsageLog()
        dirty = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Writes pending counts now, dropping days past `UsageLog.keepDays`.
    /// The write happens under the lock so a `clear()` cannot be undone by a
    /// write already under way; the file is a few kilobytes.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        writeScheduled = false
        guard dirty else { return }
        log.prune(today: today, calendar: calendar)
        dirty = false
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(log)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("barshelf: usage counts write failed: \(error)")
        }
    }
}
