#if DEBUG
import AppKit
import MenubucketCore
import SwiftUI
@testable import MenubucketApp

/// The demo shelf the landing-page media is recorded from: BarShelf's own
/// bundled widgets (their real manifests and `workflow.json`), evaluated by
/// the real `WorkflowEngine` against made-up source data — never this Mac's
/// readings, names or files — and staged into a real `WidgetRuntime`, so the
/// cards drawn are exactly the ones the app draws.
@MainActor
final class LandingDemo {
    let runtime: WidgetRuntime
    let pager = PagerState()
    /// The moment the demo is set at; every reading's age and countdown is
    /// measured from it.
    /// The staged menu bar's clock (`LandingMenuBar.clock`): Thu Nov 12,
    /// 4:48 PM, in this Mac's time zone, so times the widgets work out
    /// (Keep Awake's "until") agree with it.
    let now: Date = LandingDemo.stagedNow

    nonisolated static let stagedNow: Date = Calendar.current.date(from: DateComponents(
        year: 2026, month: 11, day: 12, hour: 16, minute: 48, second: 5
    )) ?? Date()

    /// Widget instance ids, in the order the menu bar cluster shows them.
    enum ID {
        static let system = "dev.barshelf.system"
        static let sensors = "dev.barshelf.sensors"
        static let keepAwake = "dev.barshelf.keep-awake"
        static let memory = "dev.barshelf.system--memory"
        static let today = "dev.barshelf.today"
        static let weather = "dev.barshelf.weather"
        static let battery = "dev.barshelf.battery-meter"
        static let calendar = "dev.barshelf.calendar"
        static let network = "dev.barshelf.network"
        static let clock = "dev.barshelf.clock"
    }

    static let clusterIDs = [ID.system, ID.sensors, ID.keepAwake, ID.memory]

    private struct Entry {
        let widget: LoadedWidget
        let workflow: WorkflowDefinition
        var settings: [String: JSONValue] = [:]
    }

    private var entries: [String: Entry] = [:]
    private(set) var widgets: [LoadedWidget] = []

    /// The repo's bundled widgets: next to the sources in a checkout, or in
    /// the app bundle.
    static var widgetsDirectory: URL? {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets", isDirectory: true)
        let candidates = [repo, Bundle.main.resourceURL?.appendingPathComponent("widgets", isDirectory: true)]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("system/widget.json").path)
        }
    }

    init?(runtime: WidgetRuntime) {
        self.runtime = runtime
        guard let root = Self.widgetsDirectory else {
            FileHandle.standardError.write(Data("landing-media: bundled widgets not found\n".utf8))
            return nil
        }
        // (directory, instance id, page, order, size)
        let layout: [(String, String, String, Int, String)] = [
            ("today", ID.today, "Today", 1, "M"),
            ("weather", ID.weather, "Today", 2, "S"),
            ("battery-meter", ID.battery, "Today", 3, "S"),
            ("calendar", ID.calendar, "Today", 4, "M"),
            ("system", ID.system, "System", 1, "M"),
            ("sensors", ID.sensors, "System", 2, "M"),
            ("network", ID.network, "System", 3, "S"),
            ("clock", ID.clock, "System", 4, "S"),
            ("keep-awake", ID.keepAwake, "System", 5, "M"),
            ("system", ID.memory, "System", 6, "M"),
        ]
        for (directory, id, page, order, size) in layout {
            let folder = root.appendingPathComponent(directory, isDirectory: true)
            guard var manifest = try? Manifest.decode(from: Data(contentsOf: folder.appendingPathComponent("widget.json"))),
                  let workflow = try? WorkflowDefinition.decode(
                      from: Data(contentsOf: folder.appendingPathComponent("workflow.json"))
                  )
            else {
                FileHandle.standardError.write(Data("landing-media: cannot load \(directory)\n".utf8))
                return nil
            }
            manifest.bucket = Manifest.Bucket(group: page, order: order, size: size)
            let widget = LoadedWidget(manifest: manifest, directory: folder, instanceID: id, loadRevision: "landing")
            entries[id] = Entry(widget: widget, workflow: workflow)
            widgets.append(widget)
        }
        // The memory chip: a second System, set to show memory, with the
        // chip icon a user would pick for it.
        entries[ID.memory]?.settings["menuBarMetric"] = .string("memory")
        runtime.prefs.dismissWelcome()
        for id in runtime.prefs.pinned { runtime.prefs.togglePin(id) }
        runtime.stagePreview(widgets: widgets, renders: widgets.map { render($0.id, at: 0) })
        pager.maxHeight = 460
    }

    func widget(_ id: String) -> LoadedWidget? { entries[id]?.widget }

    // MARK: - Readings over time

    /// A smooth, made-up reading that wanders around `base` — the same at
    /// the same `t` on every run.
    static func wander(_ t: Double, base: Double, swing: Double, seed: Double) -> Double {
        base + swing * (0.5 * sin(t * 0.37 + seed) + 0.32 * sin(t * 0.83 + seed * 1.7) + 0.18 * sin(t * 1.3 + seed * 0.3))
    }

    static func cpu(_ t: Double) -> Double { wander(t, base: 24, swing: 11, seed: 0.4) }
    static func memory(_ t: Double) -> Double { wander(t, base: 64, swing: 2.5, seed: 2.1) }
    static func temperature(_ t: Double) -> Double { wander(t, base: 61, swing: 4, seed: 4.2) }

    /// The trend beside the reading: one point every `step` seconds up to `t`,
    /// as the card's own `ReadingHistory` would have kept them.
    static func series(_ t: Double, step: Double = 1, count: Int = 48, _ reading: (Double) -> Double) -> [Double] {
        (0..<count).map { index in reading(t - Double(count - 1 - index) * step) }
    }

    /// Stages every widget's render and trend for time `t` (seconds into a
    /// clip). Readings update once a second, like a live meter.
    func stage(at t: Double) {
        let tick = floor(t)
        for widget in widgets {
            runtime.stageRender(render(widget.id, at: tick))
        }
        runtime.readingHistory.replace(ID.system, with: Self.series(t, Self.cpu))
        runtime.readingHistory.replace(ID.memory, with: Self.series(t, Self.memory))
        runtime.readingHistory.replace(ID.sensors, with: Self.series(t, Self.temperature))
    }

    /// The widget's real workflow, evaluated against made-up sources.
    func render(_ id: String, at t: Double) -> WidgetSnapshot {
        guard let entry = entries[id] else { return WidgetSnapshot(widgetID: id) }
        var settings = entry.widget.manifest.settingsDefaults().objectValue ?? [:]
        for (key, value) in entry.settings { settings[key] = value }
        let context: JSONValue = .object([
            "locale": .string("en"), "size": .string(entry.widget.size), "visible": .bool(true),
        ])
        let nowMs = now.timeIntervalSince1970 * 1000
        do {
            let output = try WorkflowEngine.evaluate(
                entry.workflow, sources: sources(for: entry.widget.manifest.id, t: t),
                settings: .object(settings), widget: context, nowMs: nowMs
            )
            return WidgetSnapshot(
                widgetID: id, viewTree: output.viewTree, updatedAt: now,
                statusLabel: output.statusLabel, statusMetrics: output.statusMetrics,
                statusTooltip: output.statusTooltip, statusPrefix: output.statusPrefix,
                statusIcon: output.statusIcon, statusTint: output.statusTint,
                statusPresentation: output.statusPresentation
            )
        } catch {
            FileHandle.standardError.write(Data("landing-media: \(id) failed: \(error)\n".utf8))
            return WidgetSnapshot(widgetID: id, error: "\(error)")
        }
    }

    // MARK: - Made-up sources

    private func sources(for manifestID: String, t: Double) -> [String: JSONValue] {
        let nowMs = now.timeIntervalSince1970 * 1000
        switch manifestID {
        case "dev.barshelf.system":
            let cpu = Self.cpu(t), memory = Self.memory(t)
            let total = 32e9
            return [
                "data": .object([
                    "cpu": .object([
                        "usage": .number(cpu), "user": .number(cpu * 0.64), "system": .number(cpu * 0.36),
                        "coreMax": .number(min(cpu * 2.6, 100)), "coreCount": .number(12),
                        "loadAverage": .object(["1m": .number(2.41)]),
                    ]),
                    "memory": .object([
                        "usage": .number(memory), "used": .number(total * memory / 100),
                        "free": .number(total * (100 - memory) / 100), "total": .number(total),
                        "pressure": .string("normal"), "swap": .object(["used": .number(0.4e9)]),
                    ]),
                    "disk": .object([
                        "usage": .number(58), "free": .number(412e9), "read": .null, "write": .null,
                    ]),
                ]),
                "top": .object([
                    "processes": .array([
                        Self.process(812, "Xcode", cpu: 5.6 + cpu * 0.04, memory: 3.1e9, bundle: "com.apple.dt.Xcode"),
                        Self.process(640, "Safari", cpu: 2.1, memory: 1.4e9, bundle: "com.apple.Safari"),
                        Self.process(533, "Music", cpu: 0.9, memory: 0.38e9, bundle: "com.apple.Music"),
                    ]),
                ]),
            ]
        case "dev.barshelf.sensors":
            let cpu = Self.temperature(t)
            let list: [(String, String, Double)] = [
                ("Tp01", "CPU performance core 1", cpu + 3.4),
                ("Tp05", "CPU performance core 2", cpu + 1.2),
                ("Tg0f", "GPU cluster", cpu - 8.6),
                ("Tm02", "Memory", cpu - 14.1),
                ("TB0T", "Battery", 31.4),
            ]
            let reading = { (key: String, name: String, value: Double) -> JSONValue in
                .object(["key": .string(key), "name": .string(name), "kind": .string("temperature"),
                         "value": .number(value), "unit": .string("°C")])
            }
            return [
                "data": .object([
                    "sensors": .object([
                        "available": .bool(true),
                        "cpu": .number(cpu), "gpu": .number(cpu - 8.6), "battery": .number(31.4),
                        "peak": .number(cpu + 3.4), "cpuMax": .number(cpu + 3.4), "gpuMax": .number(cpu - 6),
                        "batteryMax": .number(31.4), "power": .number(14.2),
                        "pickedList": .array([]), "picked": .null,
                        "fanCount": .number(1),
                        "fans": .array([.object([
                            "index": .number(0), "name": .string("Fan"), "rpm": .number(2140),
                            "min": .number(1200), "max": .number(5800), "usage": .number(20),
                        ])]),
                        "list": .array(list.map(reading)),
                    ]),
                ]),
            ]
        case "dev.barshelf.keep-awake":
            // PowerDisplayGuard's status file as the widget's `fs.json`
            // source reads it: an override 1 h 42 min from its end, lid
            // closed allowed, on battery.
            let iso = { (ms: Double) in ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000)) }
            let until = nowMs + (102 * 60 + 30) * 1000
            let status: JSONValue = .object([
                "version": .number(1), "updatedAt": .string(iso(nowMs - 1000)),
                "onAC": .bool(false), "phase": .string("override"), "holding": .bool(true),
                "sleepDisabled": .bool(false), "blockers": .array([]),
                "override": .object([
                    "id": .string("landing"), "until": .string(iso(until)),
                    "createdAt": .string(iso(until - 3 * 3600 * 1000)),
                    "lidClosed": .bool(true), "lidClosedEffective": .bool(true), "source": .string("barshelf"),
                ]),
            ])
            let file = { (value: JSONValue, name: String) -> JSONValue in
                .object([
                    "exists": .bool(value != .null), "valid": .bool(true), "value": value,
                    "modifiedAt": .number(nowMs - 1000), "size": .number(512),
                    "path": .string("~/Library/Application Support/PowerDisplayGuard/\(name)"),
                ])
            }
            return ["status": file(status, "status.json"), "pending": file(.null, "override.json")]
        case "dev.barshelf.today":
            return ["data": .object([
                "weekday": .string("Thursday"), "month": .string("Nov"), "day": .string("12"),
                "time": .string("16:48"), "year": .string("2026"),
            ])]
        case "dev.barshelf.clock":
            return ["data": .object([
                "h": .string("16"), "m": .string("48"), "s": .string("05"), "date": .string("Thu Nov 12"),
            ])]
        case "dev.barshelf.weather":
            return ["data": .object(["current": .object([
                "temperature_2m": .number(14.2), "weather_code": .number(2),
            ])])]
        case "dev.barshelf.battery-meter":
            return ["data": .object(["pct": .number(82), "state": .string("discharging")])]
        case "dev.barshelf.calendar":
            // November 2026 starts on a Sunday.
            return ["data": .object([
                "today": .number(12), "month": .string("November"),
                "cells": .array((1...30).map { .number(Double($0)) }),
            ])]
        case "dev.barshelf.network":
            return ["data": .object(["network": .object([
                "available": .bool(true), "interface": .string("en0"), "address": .string("192.168.0.24"),
                "download": .number(2.4e6 + 0.6e6 * sin(t)), "upload": .number(0.31e6),
            ])])]
        default:
            return [:]
        }
    }

    private static func process(_ pid: Double, _ name: String, cpu: Double, memory: Double, bundle: String) -> JSONValue {
        .object([
            "pid": .number(pid), "name": .string(name), "cpu": .number(cpu), "memory": .number(memory),
            "bundleID": .string(bundle), "isApp": .bool(true),
        ])
    }

    // MARK: - Menu bar cluster

    /// The chips the cluster draws for the staged widgets, through the real
    /// menu bar policy.
    func clusterChips() -> [ClusterChip] {
        let entries = Self.clusterIDs.compactMap { id -> MenuBarEntry? in
            guard let widget = widget(id) else { return nil }
            let snapshot = runtime.snapshots[id]
            return MenuBarPolicy.buildEntry(MenuBarEntryInputs(
                widgetID: id,
                name: id == ID.memory ? "Memory" : widget.displayName,
                manifestIcon: widget.manifest.icon,
                statusItem: widget.manifest.statusItem,
                placement: MenuBarPlacement(enabled: true, icon: id == ID.memory ? "memorychip" : nil),
                globalPresentation: runtime.appPrefs.preferences.menuBarPresentation,
                snapshot: snapshot,
                tooltip: snapshot?.statusTooltip,
                isSymbolName: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            )).entry
        }
        return MenuBarClusterPolicy.chips(from: entries) {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }

    /// Each chip's colour, as the status item picks it: the widget's accent,
    /// toned apart where two share one.
    func chipColors(_ chips: [ClusterChip]) -> [String: NSColor] {
        MenuBarController.clusterColors(chips) { [runtime] widgetID in
            guard let widget = runtime.widgets.first(where: { $0.id == widgetID }),
                  let color = runtime.prefs.effectiveAppearance(for: widget.manifest, widgetID: widgetID).accentColor
            else { return .controlAccentColor }
            return NSColor(color)
        }
    }
}
#endif
