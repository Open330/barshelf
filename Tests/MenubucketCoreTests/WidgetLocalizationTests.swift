import XCTest
@testable import MenubucketCore

/// `localizations` in widget.json: the starter widgets read in Korean, while
/// everything they run, open or store stays exactly as written.
final class WidgetLocalizationTests: XCTestCase {
    private var widgetsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets")
    }

    private func starter(_ name: String) throws -> (manifest: Manifest, workflow: WorkflowDefinition) {
        let directory = widgetsRoot.appendingPathComponent(name)
        return (
            try Manifest.decode(from: Data(contentsOf: directory.appendingPathComponent("widget.json"))),
            try WorkflowDefinition.decode(from: Data(contentsOf: directory.appendingPathComponent("workflow.json")))
        )
    }

    private func texts(_ node: UINode) -> [String] {
        [node.text, node.title, node.subtitle, node.label, node.searchPlaceholder, node.accessibilityLabel]
            .compactMap { $0 }
            + (node.children ?? []).flatMap(texts) + (node.items ?? []).flatMap(texts)
    }

    private func actions(_ node: UINode) -> [NodeAction] {
        [node.action].compactMap { $0 }
            + (node.children ?? []).flatMap(actions) + (node.items ?? []).flatMap(actions)
    }

    // MARK: Starters

    func testEveryStarterHasAKoreanName() throws {
        for (name, korean) in [("today", "오늘"), ("recent-files-grid", "최근 파일"), ("quick-shelf", "빠른 선반")] {
            let manifest = try starter(name).manifest
            XCTAssertEqual(manifest.localizedName(for: "ko"), korean, name)
            XCTAssertEqual(manifest.localizedName(for: "ko-KR"), korean, name)
            XCTAssertEqual(manifest.localizedName(for: "en"), manifest.name, name)
        }
    }

    func testTodayReadsInKoreanDateOrder() throws {
        let (manifest, workflow) = try starter("today")
        let localized = try XCTUnwrap(manifest.localization(for: "ko")).workflow(workflow)
        let output = try WorkflowEngine.evaluate(
            localized,
            sources: ["data": .object([
                "weekday": .string("토요일"), "month": .string("10월"), "day": .string("24"),
                "time": .string("09:30"), "year": .string("2026"),
            ])],
            settings: .object([:]),
            widget: .object(["size": .string("L")])
        )
        XCTAssertEqual(output.statusTooltip, "10월 24일 토요일")
        XCTAssertEqual(output.statusLabel, "09:30")
        // The command it runs is the original, so its permission still matches.
        XCTAssertEqual(localized.sources, workflow.sources)
    }

    func testRecentFilesEmptyStateAndSettingsAreKorean() throws {
        let (manifest, workflow) = try starter("recent-files-grid")
        let localization = try XCTUnwrap(manifest.localization(for: "ko"))
        let output = try WorkflowEngine.evaluate(
            localization.workflow(workflow),
            sources: ["files": .object(["items": .array([])])],
            settings: manifest.settingsDefaults()
        )
        let shown = texts(output.viewTree)
        XCTAssertTrue(shown.contains("파일 없음"), "\(shown)")
        XCTAssertTrue(shown.contains("이 폴더에 추가된 파일이 여기에 표시됩니다."), "\(shown)")
        XCTAssertEqual(output.statusTooltip, "Downloads의 파일 0개")

        let settings = localization.settings(manifest.settings ?? [])
        XCTAssertEqual(settings.map(\.title), ["폴더", "최대 파일 수", "보기", "썸네일 크기"])
        let view = try XCTUnwrap(settings.first { $0.key == "viewMode" })
        XCTAssertEqual(view.options, ["Grid", "List"], "stored values never change")
        XCTAssertEqual(view.optionTitles, ["격자", "목록"])
        XCTAssertEqual(settings.map(\.key), manifest.settings?.map(\.key))
        XCTAssertEqual(settings.map(\.defaultValue), manifest.settings?.map(\.defaultValue))
    }

    func testQuickShelfIsKoreanAndOpensTheSameThings() throws {
        let (manifest, workflow) = try starter("quick-shelf")
        let localization = try XCTUnwrap(manifest.localization(for: "ko"))
        let settings = manifest.settingsDefaults()
        let english = try WorkflowEngine.evaluate(workflow, sources: [:], settings: settings)
        let korean = try WorkflowEngine.evaluate(localization.workflow(workflow), sources: [:], settings: settings)

        let shown = texts(korean.viewTree)
        for expected in ["바로가기 6개", "바로가기 찾기", "캘린더", "앱", "즐겨 쓰는 앱", "폴더", "응용 프로그램", "웹사이트"] {
            XCTAssertTrue(shown.contains(expected), "missing \(expected) in \(shown)")
        }
        for english in ["6 shortcuts", "Find a shortcut", "Favorite app", "Folder", "Website", "App"] {
            XCTAssertFalse(shown.contains(english), "\(english) left untranslated")
        }
        XCTAssertEqual(korean.statusTooltip, "앱, 폴더, 웹사이트 열기")
        // Bundle IDs, paths and URLs — and the actions around them — are untouched.
        XCTAssertEqual(actions(korean.viewTree), actions(english.viewTree))
        XCTAssertFalse(actions(korean.viewTree).isEmpty)
    }

    func testLocalizingNeverChangesWhatTheWidgetMayDo() throws {
        for name in ["today", "recent-files-grid", "quick-shelf"] {
            let manifest = try starter(name).manifest
            let localized = try XCTUnwrap(manifest.localization(for: "ko")).manifest(manifest)
            XCTAssertNotEqual(localized.name, manifest.name, name)
            XCTAssertEqual(localized.permissions, manifest.permissions, name)
            XCTAssertEqual(PermissionStore.permissionsHash(of: localized), PermissionStore.permissionsHash(of: manifest), name)
            XCTAssertEqual(localized.entry, manifest.entry, name)
            XCTAssertEqual(localized.source, manifest.source, name)
            XCTAssertEqual(localized.bucket, manifest.bucket, "the page key stays stable: \(name)")
            XCTAssertEqual(localized.id, manifest.id, name)
        }
    }

    // MARK: Every bundled widget

    /// Folders under widgets/ holding a widget, with its workflow when it has
    /// one (script and command widgets render their own text).
    private func bundledWidgets() throws -> [(name: String, manifest: Manifest, workflow: WorkflowDefinition?)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: widgetsRoot.path).sorted()
        return try names.compactMap { name -> (name: String, manifest: Manifest, workflow: WorkflowDefinition?)? in
            let directory = widgetsRoot.appendingPathComponent(name)
            let manifestURL = directory.appendingPathComponent("widget.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            let workflowURL = directory.appendingPathComponent("workflow.json")
            let workflow = FileManager.default.fileExists(atPath: workflowURL.path)
                ? try WorkflowDefinition.decode(from: Data(contentsOf: workflowURL)) : nil
            return (name, try Manifest.decode(from: Data(contentsOf: manifestURL)), workflow)
        }
    }

    private static let displayKeys = WidgetLocalization.textKeys.union(["tooltip", "prefix"])

    private func json<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Display strings in a view, empty state or status, as the translator
    /// sees them: behavior and data subtrees are skipped.
    private func displayStrings(_ value: JSONValue) -> [String] {
        switch value {
        case let .array(items):
            return items.flatMap(displayStrings)
        case let .object(object):
            return object.sorted { $0.key < $1.key }.flatMap { key, item -> [String] in
                if WidgetLocalization.skippedKeys.contains(key) { return [] }
                if Self.displayKeys.contains(key), case let .string(text) = item { return [text] }
                return displayStrings(item)
            }
        default:
            return []
        }
    }

    /// The same tree with every display string blanked: what is left is what
    /// the widget runs, opens, stores and lays out.
    private func withoutDisplayText(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .array(items):
            return .array(items.map(withoutDisplayText))
        case let .object(object):
            var out: [String: JSONValue] = [:]
            for (key, item) in object {
                if WidgetLocalization.skippedKeys.contains(key) {
                    out[key] = item
                } else if Self.displayKeys.contains(key), case .string = item {
                    out[key] = .string("")
                } else {
                    out[key] = withoutDisplayText(item)
                }
            }
            return .object(out)
        default:
            return value
        }
    }

    func testEveryBundledWidgetHasAKoreanTableThatOnlyChangesDisplayText() throws {
        let widgets = try bundledWidgets()
        XCTAssertGreaterThan(widgets.count, 20)
        for (name, manifest, workflow) in widgets {
            let localization = try XCTUnwrap(manifest.localization(for: "ko"), "\(name) has no Korean table")
            XCTAssertNotEqual(manifest.localizedName(for: "ko"), manifest.name, name)

            // Every entry replaces text the widget shows, keeps its exact
            // expressions, and is actually used (no stale keys).
            var shown = [manifest.name]
            for setting in manifest.settings ?? [] {
                shown += [setting.title, setting.label].compactMap { $0 }
                shown += setting.optionTitles ?? setting.options ?? []
            }
            if let workflow {
                shown += displayStrings(workflow.view) + (workflow.empty.map(displayStrings) ?? [])
                if let status = workflow.status { shown += displayStrings(try json(status)) }
            }
            for (source, translated) in localization.table {
                XCTAssertTrue(shown.contains(source), "\(name): \"\(source)\" is not text this widget shows")
                XCTAssertEqual(
                    WidgetLocalization.expressions(in: source), WidgetLocalization.expressions(in: translated),
                    "\(name): \"\(source)\" changes its expressions"
                )
                XCTAssertEqual(localization.text(source), translated, name)
            }

            let localized = localization.manifest(manifest)
            XCTAssertEqual(localized.id, manifest.id, name)
            XCTAssertEqual(localized.permissions, manifest.permissions, name)
            XCTAssertEqual(PermissionStore.permissionsHash(of: localized), PermissionStore.permissionsHash(of: manifest), name)
            XCTAssertEqual(localized.entry, manifest.entry, name)
            XCTAssertEqual(localized.bucket, manifest.bucket, "the page key stays stable: \(name)")
            XCTAssertEqual(localized.settings?.map(\.key), manifest.settings?.map(\.key), name)
            XCTAssertEqual(localized.settings?.map(\.defaultValue), manifest.settings?.map(\.defaultValue), name)
            XCTAssertEqual(localized.settings?.map(\.options), manifest.settings?.map(\.options), "stored values: \(name)")

            guard let workflow else { continue }
            let translated = localization.workflow(workflow)
            XCTAssertEqual(translated.sources, workflow.sources, name)
            XCTAssertEqual(translated.transforms, workflow.transforms, name)
            XCTAssertEqual(translated.store, workflow.store, name)
            XCTAssertEqual(
                withoutDisplayText(try json(translated)), withoutDisplayText(try json(workflow)),
                "\(name): only display text may differ"
            )
        }
    }

    /// Words that used to sit inside an expression (and so could not be
    /// translated) are plain view text behind a `switch` now.
    func testConditionWordsReadInKorean() throws {
        func render(_ name: String, sources: [String: JSONValue], settings: JSONValue = .object([:])) throws -> (english: [String], korean: [String]) {
            let (manifest, workflow) = try starter(name)
            let localized = try XCTUnwrap(manifest.localization(for: "ko")).workflow(workflow)
            return (
                texts(try WorkflowEngine.evaluate(workflow, sources: sources, settings: settings).viewTree),
                texts(try WorkflowEngine.evaluate(
                    localized, sources: sources, settings: settings, widget: .object(["locale": .string("ko")])
                ).viewTree)
            )
        }
        for (code, english, korean) in [(0.0, "Clear", "맑음"), (10, "Cloudy", "흐림"), (51, "Rain", "비"), (95, "Storm", "폭풍우")] {
            let shown = try render("weather", sources: ["data": .object([
                "current": .object(["temperature_2m": .number(20), "weather_code": .number(code)]),
            ])], settings: .object(["place": .string("서울"), "lat": .string("37.57"), "lon": .string("126.98")]))
            XCTAssertTrue(shown.english.contains(english), "\(code): \(shown.english)")
            XCTAssertTrue(shown.korean.contains(korean), "\(code): \(shown.korean)")
            XCTAssertFalse(shown.korean.contains(english), "\(code): \(shown.korean)")
        }

        let offline = try render("network", sources: ["data": .object(["network": .object([
            "available": .bool(false), "interface": .null, "address": .null, "download": .null, "upload": .null, "received": .number(8_000_000), "sent": .number(2_000_000),
        ])])], settings: .object(["menuBarDisplay": .string("activity"), "interface": .string("all")]))
        XCTAssertTrue(offline.korean.contains("오프라인"), "\(offline.korean)")
        XCTAssertTrue(offline.korean.contains("로컬 주소 없음"), "\(offline.korean)")
        let online = try render("network", sources: ["data": .object(["network": .object([
            "available": .bool(true), "interface": .string("all"), "address": .string("192.168.0.8"),
            "download": .null, "upload": .null, "received": .number(8_000_000), "sent": .number(2_000_000),
        ])])], settings: .object(["menuBarDisplay": .string("activity"), "interface": .string("all")]))
        XCTAssertTrue(online.korean.contains("모든 인터페이스"), "\(online.korean)")
        XCTAssertTrue(online.korean.contains("192.168.0.8"), "addresses are data: \(online.korean)")
        XCTAssertTrue(online.english.contains("All interfaces"), "\(online.english)")

        let charging = try render("battery-meter", sources: ["data": .object(["pct": .number(80), "state": .string("charging")])])
        XCTAssertTrue(charging.korean.contains("충전 중"), "\(charging.korean)")
        XCTAssertTrue(charging.english.contains("charging"), "\(charging.english)")
        let unknown = try render("battery-meter", sources: ["data": .object(["pct": .number(80), "state": .string("unknown")])])
        XCTAssertTrue(unknown.korean.contains("unknown"), "an unlisted state shows as reported: \(unknown.korean)")

        for (indicator, english, korean) in [("none", "OK", "정상"), ("minor", "Minor", "경미"), ("critical", "Critical", "심각")] {
            let github = try render("github-status", sources: ["github": .object([
                "status": .object(["indicator": .string(indicator), "description": .string("All Systems Operational")]),
            ])])
            XCTAssertTrue(github.english.contains(english), "\(indicator): \(github.english)")
            XCTAssertTrue(github.korean.contains(korean), "\(indicator): \(github.korean)")
            XCTAssertTrue(github.korean.contains("All Systems Operational"), "the provider's own words stay")
        }
        let unlisted = try render("github-status", sources: ["github": .object([
            "status": .object(["indicator": .string("maintenance"), "description": .string("Scheduled")]),
        ])])
        XCTAssertTrue(unlisted.korean.contains("maintenance"), "an unlisted indicator shows as sent: \(unlisted.korean)")

        let calendar = try render("calendar", sources: ["data": .object([
            "today": .number(24), "month": .string("10월"), "cells": .array([.number(0), .number(1)]),
        ])])
        for day in ["일", "월", "화", "수", "목", "금", "토"] {
            XCTAssertTrue(calendar.korean.contains(day), "\(calendar.korean)")
        }
    }

    // MARK: Menu bar and accessibility text (`widget.locale`)

    /// A bundled workflow as BarShelf runs it in `locale`: its table applied
    /// and `widget.locale` set. Nil runs it as a host without either would.
    private func evaluate(
        _ name: String, sources: [String: JSONValue], settings: JSONValue = .object([:]), locale: String?
    ) throws -> WorkflowEngine.Output {
        let (manifest, workflow) = try starter(name)
        let definition = locale.flatMap { manifest.localization(for: $0) }?.workflow(workflow) ?? workflow
        let widget: JSONValue = locale.map { .object(["locale": .string($0)]) } ?? .object([:])
        return try WorkflowEngine.evaluate(definition, sources: sources, settings: settings, widget: widget)
    }

    private let systemSources: [String: JSONValue] = [
        "data": .object([
            "memory": .object([
                "usage": .number(50), "used": .number(12e9), "free": .number(4e9),
                "pressure": .string("warning"), "swap": .object(["used": .number(1.5e9)]),
            ]),
            "disk": .object(["usage": .number(61), "free": .number(245e9), "read": .number(3_400_000), "write": .null]),
            "cpu": .object(["usage": .number(12), "user": .number(8), "system": .number(4), "coreMax": .number(97)]),
        ]),
    ]

    func testSystemMenuBarReadsInKoreanWithTheSameNumbers() throws {
        let settings: JSONValue = .object([
            "menuBarMetric": .string("pressure"), "menuBarSecondary": .string("diskFree"),
        ])
        let korean = try evaluate("system", sources: systemSources, settings: settings, locale: "ko")
        XCTAssertEqual(korean.statusLabel, "경고")
        XCTAssertEqual(korean.statusPrefix, "RAM")
        XCTAssertEqual(korean.statusMetrics?.map(\.label), ["RAM", "여유"])
        XCTAssertEqual(korean.statusMetrics?.first?.value, "경고")
        XCTAssertEqual(korean.statusMetrics?.last?.number, 245e9, "measurements are not text")
        XCTAssertEqual(korean.statusMetrics?.map(\.id), ["pressure", "diskFree"], "ids are not text")
        XCTAssertEqual(korean.statusTint, "warning", "colour is decided on the reading, not the label")
        XCTAssertEqual(
            korean.statusTooltip,
            "메모리 압력 경고 · 디스크 여유 공간 245 GB\nCPU 12% · 메모리 50% · 디스크 61%"
        )

        let read = try evaluate("system", sources: systemSources, settings: .object([
            "menuBarMetric": .string("diskRead"), "menuBarSecondary": .string("cpuUser"),
        ]), locale: "ko-KR")
        XCTAssertEqual(read.statusMetrics?.map(\.label), ["읽기", "사용자"])
        XCTAssertEqual(read.statusLabel, "3.4 MB/s")
        XCTAssertTrue(read.statusTooltip?.hasPrefix("디스크 읽기 3.4 MB/s · CPU 사용자 8%") == true, "\(read.statusTooltip ?? "")")

        // English, another language, and a host that sends no locale all
        // read exactly as before.
        for locale in ["en", "fr", nil] as [String?] {
            let english = try evaluate("system", sources: systemSources, settings: settings, locale: locale)
            XCTAssertEqual(english.statusLabel, "Warning", "\(locale ?? "none")")
            XCTAssertEqual(english.statusMetrics?.map(\.label), ["RAM", "Free"], "\(locale ?? "none")")
            XCTAssertEqual(
                english.statusTooltip,
                "Memory pressure Warning · Disk free 245 GB\nCPU 12% · Memory 50% · Disk 61%",
                "\(locale ?? "none")"
            )
            XCTAssertEqual(english.statusTint, korean.statusTint)
        }
    }

    func testNetworkAccessibilityReadsInKorean() throws {
        func sources(available: Bool, download: JSONValue, upload: JSONValue, address: JSONValue) -> [String: JSONValue] {
            ["data": .object(["network": .object([
                "available": .bool(available), "interface": .string("all"), "address": address,
                "download": download, "upload": upload, "received": .number(8_000_000), "sent": .number(2_000_000),
            ])])]
        }
        let settings: JSONValue = .object(["menuBarDisplay": .string("speed"), "interface": .string("all")])
        let live = sources(available: true, download: .number(1_500_000), upload: .null, address: .string("192.168.0.8"))
        let korean = try evaluate("network", sources: live, settings: settings, locale: "ko")
        XCTAssertEqual(korean.statusMetrics?.map(\.accessibilityLabel), ["다운로드 1.5 MB/s", "업로드 측정 대기 중"])
        XCTAssertEqual(korean.statusMetrics?.map(\.value), ["1.5 MB/s", "—"], "rates are not text")
        XCTAssertEqual(korean.statusTooltip, "다운로드 1.5 MB/s · 업로드 측정 대기 중 · 192.168.0.8")
        let english = try evaluate("network", sources: live, settings: settings, locale: nil)
        XCTAssertEqual(english.statusMetrics?.map(\.accessibilityLabel), ["Download 1.5 MB/s", "Upload waiting for sample"])
        XCTAssertEqual(english.statusTooltip, "Download 1.5 MB/s · Upload waiting for sample · 192.168.0.8")

        let offline = sources(available: false, download: .null, upload: .null, address: .null)
        XCTAssertEqual(
            try evaluate("network", sources: offline, settings: settings, locale: "ko").statusTooltip,
            "다운로드 정보 없음 · 업로드 정보 없음 · 로컬 주소 없음"
        )
        XCTAssertEqual(
            try evaluate("network", sources: offline, settings: settings, locale: "en").statusTooltip,
            "Download unavailable · Upload unavailable · No local address"
        )
    }

    func testSensorsStatusReadsInKorean() throws {
        let readings: [String: JSONValue] = ["data": .object(["sensors": .object([
            "available": .bool(true), "cpu": .number(60), "cpuMax": .number(78), "gpu": .number(50), "gpuMax": .null,
            "battery": .number(30), "peak": .number(81), "power": .number(12.4), "fanCount": .number(1),
            "fans": .array([.object(["rpm": .number(2400), "usage": .number(40)])]),
            "picked": .null, "pickedList": .array([]),
        ])])]
        let settings: JSONValue = .object([
            "menuBarSensor": .string("cpu"), "menuBarSecondary": .string("fan"),
            "aggregate": .string("average"), "unit": .string("celsius"),
        ])
        let korean = try evaluate("sensors", sources: readings, settings: settings, locale: "ko")
        XCTAssertEqual(korean.statusTooltip, "CPU 온도 60°C · 팬 속도 2400 rpm")
        XCTAssertEqual(korean.statusMetrics?.map(\.label), ["CPU", "팬"])
        XCTAssertEqual(korean.statusMetrics?.map(\.accessibilityLabel), ["CPU 온도 60 °C", "팬 속도 2400 rpm"])
        XCTAssertEqual(korean.statusLabel, "60°", "the reading itself")
        let english = try evaluate("sensors", sources: readings, settings: settings, locale: "en")
        XCTAssertEqual(english.statusTooltip, "CPU temperature 60°C · Fan speed 2400 rpm")
        XCTAssertEqual(english.statusMetrics?.map(\.label), ["CPU", "Fan"])

        let none: [String: JSONValue] = ["data": .object(["sensors": .object([
            "available": .bool(false), "fans": .array([]), "picked": .null, "pickedList": .array([]),
        ])])]
        XCTAssertEqual(try evaluate("sensors", sources: none, settings: settings, locale: "ko").statusTooltip, "사용할 수 있는 센서 없음")
        XCTAssertEqual(try evaluate("sensors", sources: none, settings: settings, locale: nil).statusTooltip, "No sensors available")
        let missing: [String: JSONValue] = ["data": .object(["sensors": .object([
            "available": .bool(true), "cpu": .null, "fans": .array([]), "picked": .null, "pickedList": .array([]),
        ])])]
        XCTAssertEqual(try evaluate("sensors", sources: missing, settings: settings, locale: "ko").statusTooltip, "CPU 온도 값 없음")
        XCTAssertEqual(try evaluate("sensors", sources: missing, settings: settings, locale: "en").statusTooltip, "CPU temperature unavailable")
    }

    func testGitHubAndBatteryStatusReadInKorean() throws {
        let github: [String: JSONValue] = ["github": .object([
            "status": .object(["indicator": .string("major"), "description": .string("Partial outage")]),
        ])]
        let korean = try evaluate("github-status", sources: github, locale: "ko")
        XCTAssertEqual(korean.statusLabel, "GitHub 주요 장애")
        XCTAssertEqual(korean.statusTooltip, "GitHub 상태: Partial outage", "the provider's words stay")
        XCTAssertEqual(try evaluate("github-status", sources: github, locale: nil).statusLabel, "GitHub Major")

        let battery: [String: JSONValue] = ["data": .object(["pct": .number(80), "state": .string("discharging")])]
        XCTAssertEqual(try evaluate("battery-meter", sources: battery, locale: "ko").statusTooltip, "배터리 80% — 배터리 사용 중")
        XCTAssertEqual(try evaluate("battery-meter", sources: battery, locale: "en").statusTooltip, "Battery 80% — discharging")
        let odd: [String: JSONValue] = ["data": .object(["pct": .number(80), "state": .string("unknown")])]
        XCTAssertEqual(try evaluate("battery-meter", sources: odd, locale: "ko").statusTooltip, "배터리 80% — unknown")
    }

    // MARK: Lookup rules

    func testLanguageFallsBackFromRegionToLanguageAndThenToEnglish() {
        let tables = WidgetLocalizations(["ko": ["Today": "오늘"], "pt-BR": ["Today": "Hoje"]])
        XCTAssertEqual(tables.localization(for: "ko-KR")?.text("Today"), "오늘")
        XCTAssertEqual(tables.localization(for: "ko_KR")?.text("Today"), "오늘")
        XCTAssertEqual(tables.localization(for: "KO")?.text("Today"), "오늘")
        XCTAssertEqual(tables.localization(for: "pt")?.text("Today"), "Hoje", "any regional table of the language")
        XCTAssertNil(tables.localization(for: "fr"))
        XCTAssertNil(tables.localization(for: "en"))

        let exact = WidgetLocalizations(["zh": ["Today": "今天"], "zh-Hant": ["Today": "今日"]])
        XCTAssertEqual(exact.localization(for: "zh-Hant")?.text("Today"), "今日")
        XCTAssertEqual(exact.localization(for: "zh-Hans")?.text("Today"), "今天")
    }

    func testAWidgetWithoutTranslationsIsUnchanged() throws {
        let (manifest, _) = try starter("today")
        var plain = manifest
        plain.localizations = nil
        XCTAssertNil(plain.localization(for: "ko"))
        XCTAssertEqual(plain.localizedName(for: "ko"), "Today")
    }

    func testATranslationThatChangesAnExpressionIsIgnored() {
        let localization = WidgetLocalization(table: [
            "${count(items)} files": "${count(items)}개 파일",
            "${a} of ${b}": "${b} 중 ${a}",
            "${name}": "${secrets.token}",
            "Done": "${settings.token}",
            "Plain": "보통",
        ])
        XCTAssertEqual(localization.text("${count(items)} files"), "${count(items)}개 파일")
        XCTAssertEqual(localization.text("${a} of ${b}"), "${b} 중 ${a}", "reordering is fine")
        XCTAssertEqual(localization.text("${name}"), "${name}", "a different expression is refused")
        XCTAssertEqual(localization.text("Done"), "Done", "an added expression is refused")
        XCTAssertEqual(localization.text("Plain"), "보통")
        XCTAssertEqual(localization.text("Unknown"), "Unknown")
    }

    func testOnlyDisplayKeysAreTranslated() {
        let localization = WidgetLocalization(table: ["Open": "열기", "https://example.com": "https://evil.example"])
        let view: JSONValue = .object([
            "type": .string("button"),
            "title": .string("Open"),
            "action": .object(["type": .string("openURL"), "url": .string("https://example.com"), "label": .string("Open")]),
            "children": .array([.object(["type": .string("text"), "text": .string("https://example.com")])]),
            "id": .string("Open"),
        ])
        guard case let .object(out) = localization.view(view) else { return XCTFail("not an object") }
        XCTAssertEqual(out["title"], .string("열기"))
        XCTAssertEqual(out["id"], .string("Open"), "ids are not display text")
        XCTAssertEqual(out["action"], view.objectValue?["action"], "actions are never touched")
        XCTAssertEqual(
            out["children"], .array([.object(["type": .string("text"), "text": .string("https://evil.example")])]),
            "visible text is author-translated like any other"
        )
    }

    // MARK: Decoding

    func testMalformedTranslationsNeverRefuseTheWidget() throws {
        let json = #"""
        {"schemaVersion":1,"id":"x","name":"X","entry":{"kind":"workflow"},
         "localizations":{"ko":"bad","ja":{"X":1,"Y":"ワイ","Z":""},"fr":[]}}
        """#
        let manifest = try Manifest.decode(from: Data(json.utf8))
        XCTAssertEqual(manifest.localizations?.tables, ["ja": ["Y": "ワイ"]])

        let wrongType = #"{"schemaVersion":1,"id":"x","name":"X","entry":{"kind":"workflow"},"localizations":[1]}"#
        XCTAssertEqual(try Manifest.decode(from: Data(wrongType.utf8)).localizations?.tables, [:])
        let absent = #"{"schemaVersion":1,"id":"x","name":"X","entry":{"kind":"workflow"}}"#
        XCTAssertNil(try Manifest.decode(from: Data(absent.utf8)).localizations)
    }
}
