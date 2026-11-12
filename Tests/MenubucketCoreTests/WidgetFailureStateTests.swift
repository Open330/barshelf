import XCTest
@testable import MenubucketCore

/// Bundled widgets whose data can fail (offline, a bad setting, a refused
/// Automation prompt) used to render the failure as data: a null price with
/// ▼, "0 open" reminders, every snowfall as "Storm". These run the shipped
/// workflows with fake sources and `errors.<id>` the way the host fills them.
final class WidgetFailureStateTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func evaluate(
        _ name: String, sources: [String: JSONValue] = [:], errors: [String: JSONValue] = [:],
        settings: [String: JSONValue] = [:], locale: String? = nil
    ) throws -> WorkflowEngine.Output {
        let dir = Self.root.appendingPathComponent("widgets/\(name)")
        let manifest = try Manifest.decode(from: Data(contentsOf: dir.appendingPathComponent("widget.json")))
        let workflow = try WorkflowDefinition.decode(from: Data(contentsOf: dir.appendingPathComponent("workflow.json")))
        let definition = locale.flatMap { manifest.localization(for: $0) }?.workflow(workflow) ?? workflow
        var merged = manifest.settingsDefaults().objectValue ?? [:]
        for (key, value) in settings { merged[key] = value }
        let widget: JSONValue = locale.map { .object(["locale": .string($0)]) } ?? .object([:])
        return try WorkflowEngine.evaluate(
            definition, sources: sources, settings: .object(merged), widget: widget, errors: errors
        )
    }

    private func texts(_ node: UINode) -> [String] {
        [node.text, node.title, node.subtitle].compactMap { $0 }
            + ((node.children ?? []) + (node.items ?? [])).flatMap(texts)
    }

    private func failure(_ kind: String, code: Int? = nil, message: String = "boom") -> JSONValue {
        var object: [String: JSONValue] = ["kind": .string(kind), "message": .string(message)]
        if let code { object["code"] = .number(Double(code)) }
        return .object(object)
    }

    // MARK: Weather

    private func weather(_ code: Double, isDay: Double = 1) throws -> WorkflowEngine.Output {
        try evaluate("weather", sources: ["data": .object([
            "current": .object(["temperature_2m": .number(3.4), "weather_code": .number(code), "is_day": .number(isDay)]),
        ])])
    }

    func testWeatherNamesEveryWMOGroup() throws {
        let expected: [(Double, String, String)] = [
            (0, "Clear", "sun.max.fill"), (2, "Partly cloudy", "cloud.sun.fill"), (3, "Cloudy", "cloud.fill"),
            (45, "Fog", "cloud.fog.fill"), (48, "Fog", "cloud.fog.fill"), (55, "Rain", "cloud.rain.fill"),
            (66, "Rain", "cloud.rain.fill"), (71, "Snow", "cloud.snow.fill"), (77, "Snow", "cloud.snow.fill"),
            (80, "Showers", "cloud.heavyrain.fill"), (82, "Showers", "cloud.heavyrain.fill"),
            (85, "Snow showers", "cloud.snow.fill"), (86, "Snow showers", "cloud.snow.fill"),
            (95, "Thunderstorm", "cloud.bolt.rain.fill"), (99, "Thunderstorm", "cloud.bolt.rain.fill"),
        ]
        for (code, word, icon) in expected {
            let output = try weather(code)
            XCTAssertTrue(texts(output.viewTree).contains(word), "\(code): \(texts(output.viewTree))")
            XCTAssertFalse(word != "Thunderstorm" && texts(output.viewTree).contains("Thunderstorm"), "\(code)")
            XCTAssertEqual(output.statusIcon, icon, "\(code)")
            XCTAssertEqual(output.statusLabel, "3°", "\(code)")
        }
        XCTAssertEqual(try weather(0, isDay: 0).statusIcon, "moon.stars.fill")
    }

    func testWeatherFailuresSaySoAndLeaveTheMenuBarEmpty() throws {
        let offline = try evaluate("weather", sources: ["data": .null], errors: ["data": failure("offline")])
        XCTAssertTrue(texts(offline.viewTree).contains("You’re offline"), "\(texts(offline.viewTree))")
        XCTAssertEqual(offline.statusLabel, "")
        XCTAssertFalse(texts(offline.viewTree).contains { $0.contains("°") })

        let badPlace = try evaluate(
            "weather", sources: ["data": .null],
            errors: ["data": failure("unreachable", code: 400, message: "http source failed (HTTP 400)")],
            settings: ["lat": .string("999")], locale: "ko"
        )
        let shown = texts(badPlace.viewTree)
        XCTAssertTrue(shown.contains("위치를 확인하세요"), "\(shown)")
        XCTAssertNotEqual(shown.first, "http source failed (HTTP 400)", "the raw message is never the headline")
    }

    func testWeatherAsksForFahrenheitWhenChosen() throws {
        let workflow = try WorkflowDefinition.decode(from: Data(contentsOf: Self.root.appendingPathComponent("widgets/weather/workflow.json")))
        let params = try WorkflowEngine.resolvedSourceParams(workflow, settings: .object([
            "lat": .string("1"), "lon": .string("2"), "unit": .string("fahrenheit"),
        ]))
        XCTAssertTrue(params["data"]?.objectValue?["url"]?.stringValue?.contains("temperature_unit=fahrenheit") == true)
        let output = try evaluate("weather", sources: ["data": .object([
            "current": .object(["temperature_2m": .number(46.9), "weather_code": .number(1), "is_day": .number(1)]),
        ])], settings: ["unit": .string("fahrenheit")])
        XCTAssertTrue(output.statusTooltip?.contains("46.9°F") == true, output.statusTooltip ?? "")
    }

    // MARK: Stock

    func testStockShowsCurrencyAndPercentAndTintsTheMenuBar() throws {
        let output = try evaluate("stock", sources: ["data": .object(["chart": .object(["result": .array([
            .object(["meta": .object([
                "symbol": .string("005930.KS"), "currency": .string("KRW"),
                "regularMarketPrice": .number(55_300), "chartPreviousClose": .number(56_000),
            ])]),
        ])])])], settings: ["symbol": .string("005930.KS")])
        let shown = texts(output.viewTree)
        XCTAssertTrue(shown.contains("55,300.00"), "\(shown)")
        XCTAssertTrue(shown.contains("KRW"), "\(shown)")
        XCTAssertTrue(shown.contains("▼ 700 (-1.25%)"), "\(shown)")
        XCTAssertEqual(output.statusPrefix, "005930.KS")
        XCTAssertEqual(output.statusLabel, "55,300.00")
        XCTAssertEqual(output.statusTint, "danger")
    }

    func testAnUnknownTickerIsNotAPrice() throws {
        // Yahoo answers an unknown symbol with 404, or with a result of null.
        for (sources, errors) in [
            (["data": JSONValue.null], ["data": failure("notFound", code: 404)]),
            (["data": .object(["chart": .object(["result": .null])])], [:]),
        ] {
            let output = try evaluate("stock", sources: sources, errors: errors, settings: ["symbol": .string("NOPEXX")])
            let shown = texts(output.viewTree)
            XCTAssertTrue(shown.contains("No quote for this ticker"), "\(shown)")
            XCTAssertFalse(shown.contains { $0.contains("▼") || $0.contains("▲") }, "\(shown)")
            XCTAssertEqual(output.statusLabel, "")
            XCTAssertEqual(output.statusTint, "")
        }
        let offline = try evaluate("stock", sources: ["data": .null], errors: ["data": failure("offline")])
        XCTAssertTrue(texts(offline.viewTree).contains("You’re offline"))
    }

    // MARK: Exchange

    func testExchangeFollowsThePairAndGroupsDigits() throws {
        let output = try evaluate("exchange", sources: ["data": .object([
            "result": .string("success"), "rates": .object(["JPY": .number(154.237), "KRW": .number(1337.4)]),
            "time_last_update_unix": .number(1_794_441_751),
        ])], settings: ["base": .string("USD"), "quote": .string("JPY")])
        XCTAssertTrue(texts(output.viewTree).contains("¥154.24"), "\(texts(output.viewTree))")
        XCTAssertTrue(texts(output.viewTree).contains("USD → JPY"))
        XCTAssertEqual(output.statusLabel, "¥154")

        let won = try evaluate("exchange", sources: ["data": .object([
            "result": .string("success"), "rates": .object(["KRW": .number(1337.4)]),
        ])])
        XCTAssertEqual(won.statusLabel, "₩1,337")

        let unknown = try evaluate("exchange", sources: ["data": .object([
            "result": .string("error"), "error-type": .string("unsupported-code"),
        ])], locale: "ko")
        XCTAssertTrue(texts(unknown.viewTree).contains("이 통화 쌍의 환율이 없습니다"), "\(texts(unknown.viewTree))")
        XCTAssertEqual(unknown.statusLabel, "")
    }

    // MARK: Crypto

    func testCryptoRateLimitIsNotAnEmptyCoinList() throws {
        let output = try evaluate("crypto", sources: ["data": .null], errors: ["data": failure("rateLimited", code: 429)])
        let shown = texts(output.viewTree)
        XCTAssertTrue(shown.contains("CoinGecko is limiting requests"), "\(shown)")
        XCTAssertFalse(shown.contains("No coins found"), "\(shown)")
        XCTAssertFalse(output.usedEmpty)
        XCTAssertEqual(output.statusLabel, "")
    }

    func testCryptoMenuBarNamesTheCoinAndFits() throws {
        let output = try evaluate("crypto", sources: ["data": .array([.object([
            "id": .string("bitcoin"), "name": .string("Bitcoin"), "symbol": .string("btc"),
            "current_price": .number(140_250_000), "price_change_percentage_24h": .number(1.2),
            "sparkline_in_7d": .object(["price": .array([1, 2, 3].map { .number($0) })]),
        ])])], settings: ["currency": .string("krw"), "sparkline": .bool(true)])
        XCTAssertEqual(output.statusPrefix, "BTC")
        XCTAssertEqual(output.statusLabel, "₩140.3M")
        XCTAssertTrue(texts(output.viewTree).contains("₩140,250,000"))
        func sparklines(_ node: UINode) -> [UINode] {
            (node.type == "sparkline" ? [node] : []) + ((node.children ?? []) + (node.items ?? [])).flatMap(sparklines)
        }
        XCTAssertEqual(sparklines(output.viewTree).count, 1)
    }

    // MARK: Reminders

    func testRemindersFailureIsNeverZeroOpen() throws {
        let denied = try evaluate("reminders", sources: ["data": .null], errors: ["data": failure(
            "exit", code: 1, message: "execution error: Not authorized to send Apple events to Reminders. (-1743)"
        )])
        let shown = texts(denied.viewTree)
        XCTAssertTrue(shown.contains("Allow BarShelf to read Reminders"), "\(shown)")
        XCTAssertFalse(shown.contains("0"), "\(shown)")
        XCTAssertEqual(denied.statusLabel, "")
        func urls(_ node: UINode) -> [String] {
            [node.action?.url].compactMap { $0 } + ((node.children ?? []) + (node.items ?? [])).flatMap(urls)
        }
        XCTAssertTrue(urls(denied.viewTree).contains { $0.contains("Privacy_Automation") })

        let slow = try evaluate("reminders", sources: ["data": .null], errors: ["data": failure("timeout")])
        XCTAssertTrue(texts(slow.viewTree).contains("Reminders didn’t answer in time"))
        XCTAssertFalse(urls(slow.viewTree).contains { $0.contains("Privacy_Automation") }, "only a denial sends you to Privacy")

        let fine = try evaluate("reminders", sources: ["data": .object(["count": .number(0)])])
        XCTAssertTrue(texts(fine.viewTree).contains("0"))
        XCTAssertEqual(fine.statusLabel, "0")
    }

    // MARK: Codex Reset

    func testCodexResetAlertsAtTheThresholdAndSaysDays() throws {
        func forecast(_ score: Double) -> [String: JSONValue] {
            ["api": .object(["forecast": .object([
                "score": .number(score), "hoursSinceReset": .number(1750.5), "horizonHours": .number(48),
            ])])]
        }
        // Opt-in: off by default, so updating never starts notifications.
        let off = try evaluate("codex-reset", sources: forecast(72))
        XCTAssertNil(off.alerts.first?.active)
        XCTAssertTrue(texts(off.viewTree).contains("Last reset 73 days ago · alerts off"), "\(texts(off.viewTree))")

        let on: [String: JSONValue] = ["notify": .bool(true)]
        let low = try evaluate("codex-reset", sources: forecast(16), settings: on)
        XCTAssertEqual(low.statusPrefix, "Codex")
        XCTAssertEqual(low.statusLabel, "16%")
        XCTAssertTrue(texts(low.viewTree).contains("Last reset 73 days ago · alert at 70%"), "\(texts(low.viewTree))")
        XCTAssertTrue(texts(low.viewTree).contains("Next 48 h"))
        XCTAssertEqual(low.alerts.first?.active, false)
        XCTAssertEqual(try evaluate("codex-reset", sources: forecast(72), settings: on).alerts.first?.active, true)

        let offline = try evaluate("codex-reset", sources: ["api": .null], errors: ["api": failure("offline")], settings: on)
        XCTAssertNil(offline.alerts.first?.active, "offline neither fires nor re-arms")
        XCTAssertEqual(offline.statusLabel, "")
    }

    // MARK: GitHub Status

    func testGitHubListsIncidentsAndTintsOnlyThen() throws {
        let output = try evaluate("github-status", sources: ["github": .object([
            "status": .object(["indicator": .string("minor"), "description": .string("Minor Service Outage")]),
            "incidents": .array([.object([
                "id": .string("abc"), "name": .string("Actions delays"), "status": .string("investigating"),
                "impact": .string("minor"), "shortlink": .string("https://stspg.io/abc"),
                "updated_at": .string("2026-11-12T01:00:00Z"),
            ])]),
        ])], settings: ["notifyIncidents": .bool(true)])
        XCTAssertTrue(texts(output.viewTree).contains("Actions delays"))
        XCTAssertEqual(output.statusTint, "warning")
        XCTAssertEqual(output.alerts.first?.active, true)
        XCTAssertEqual(output.alerts.first?.body, "Actions delays")

        let quiet = try evaluate("github-status", sources: ["github": .object([
            "status": .object(["indicator": .string("minor"), "description": .string("x")]), "incidents": .array([]),
        ])])
        XCTAssertNil(quiet.alerts.first?.active, "the alert is opt-in")

        let offline = try evaluate("github-status", sources: ["github": .null], errors: ["github": failure("offline")],
                                   settings: ["notifyIncidents": .bool(true)])
        XCTAssertTrue(texts(offline.viewTree).contains("You’re offline"))
        XCTAssertEqual(offline.statusLabel, "")
        XCTAssertNil(offline.alerts.first?.active)
    }

    // MARK: Quick Note, Countdown

    func testAnEmptyNoteLeavesTheMenuBarEmpty() throws {
        XCTAssertEqual(try evaluate("quick-note").statusLabel, "")
        XCTAssertEqual(try evaluate("quick-note", settings: ["note": .string("Buy milk")]).statusLabel, "Buy milk")
    }

    func testCountdownStartsEmptyAndCanRemindEarly() throws {
        let fresh = try evaluate("countdown", sources: ["clock": .object(["today": .string("2026-11-12T00:00:00Z")])])
        XCTAssertEqual(fresh.viewTree.type, "empty")
        XCTAssertEqual(fresh.statusLabel, "")

        let soon = try evaluate("countdown", sources: ["clock": .object(["today": .string("2026-11-12T00:00:00Z")])],
                                settings: ["title1": .string("Trip"), "date1": .string("2026-11-15"), "remindDays": .number(3)])
        XCTAssertEqual(soon.statusLabel, "D-3")
        XCTAssertEqual(soon.alerts.first { $0.id == "soon1" }?.active, true)
        let off = try evaluate("countdown", sources: ["clock": .object(["today": .string("2026-11-12T00:00:00Z")])],
                               settings: ["title1": .string("Trip"), "date1": .string("2026-11-15")])
        XCTAssertNil(off.alerts.first { $0.id == "soon1" }?.active)
    }

    // MARK: World Clock

    func testWorldClockWarnsAboutAnUnknownZone() throws {
        let city: JSONValue = .object([
            "time": .string("17:42"), "hour": .number(117), "ymd": .number(20261111), "wd": .number(3), "off": .string("-0800"),
        ])
        let output = try evaluate("world-clock", sources: ["clock": .object([
            "local": .object(["time": .string("10:42"), "hour": .number(110), "ymd": .number(20261112), "wd": .number(4), "off": .string("+0900")]),
            "z1": city, "z2": .object(["invalid": .bool(true)]), "z3": .null, "z4": .null, "z5": .null,
        ])], settings: [
            "zone1": .string("America/Los_Angeles"), "label1": .string("SF"),
            "zone2": .string("Mars/Base"), "label2": .string("Mars"),
            "zone3": .string(""), "zone4": .string(""), "menuBarCity": .string("1"),
        ])
        let shown = texts(output.viewTree)
        XCTAssertTrue(shown.contains("Unknown time zone: Mars/Base"), "\(shown)")
        XCTAssertTrue(shown.contains { $0.contains("time zone name not recognized") }, "\(shown)")
        XCTAssertTrue(shown.contains("17:42"))
        XCTAssertEqual(output.statusPrefix, "SF")
        XCTAssertEqual(output.statusLabel, "17:42")
    }
}

/// World Clock runs one command for every city. An empty city slot must still
/// be an argument, or the argv no longer matches the approved pattern.
final class WorldClockCommandTests: XCTestCase {
    func testEmptyCitySlotsStillMatchTheAllowlist() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets/world-clock")
        let manifest = try Manifest.decode(from: Data(contentsOf: dir.appendingPathComponent("widget.json")))
        let workflow = try WorkflowDefinition.decode(from: Data(contentsOf: dir.appendingPathComponent("workflow.json")))
        for settings in [manifest.settingsDefaults(), .object([:]), .object(["zone1": .string("Asia/Seoul"), "zone5": .string("")])] {
            let params = try WorkflowEngine.resolvedSourceParams(workflow, settings: settings)
            let command = try XCTUnwrap(params["clock"]?.objectValue?["command"]?.arrayValue).compactMap(\.stringValue)
            XCTAssertEqual(command.count, 9, "\(settings)") // sh, -c, script, $0, five cities
            XCTAssertTrue(ExecAllowlist.permits(command: command, permissions: manifest.permissions?.exec), "\(settings)")
        }
    }
}
