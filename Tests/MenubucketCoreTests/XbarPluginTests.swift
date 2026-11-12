import XCTest
@testable import MenubucketCore

final class XbarPluginTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xbar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Parsing

    func testTitlesThenBodyWithDepthAndSeparators() {
        let out = XbarPlugin.parse("""
        ☀️ 21°
        Second title
        ---
        Today
        --Morning | color=red
        ----Detail
        -----
        --Evening
        ---
        Refresh | refresh=true

        """)
        XCTAssertEqual(out.titles.map(\.text), ["☀️ 21°", "Second title"])
        XCTAssertEqual(out.items.map(\.depth), [0, 1, 2, 1, 1, 0, 0])
        XCTAssertEqual(out.items.map(\.isSeparator), [false, false, false, true, false, true, false])
        XCTAssertEqual(out.items[1].params["color"], "red")
    }

    func testTextEndsAtTheFirstPipeAndQuotedValuesKeepPipes() {
        let line = XbarPlugin.parseLine(#"a b | bash="/bin/echo" param1="x | y" param2='it is' Color=Blue href=https://x.y/?a=b"#)
        XCTAssertEqual(line.text, "a b")
        XCTAssertEqual(line.params["bash"], "/bin/echo")
        XCTAssertEqual(line.params["param1"], "x | y")
        XCTAssertEqual(line.params["param2"], "it is")
        XCTAssertEqual(line.params["color"], "Blue", "keys are lowercased, values are not")
        XCTAssertEqual(line.params["href"], "https://x.y/?a=b", "only the first = splits")
        XCTAssertFalse(line.malformed)
    }

    func testShellSyntaxStaysLiteral() {
        let line = XbarPlugin.parseLine(#"x | bash=/bin/echo param1="$(whoami)" param2=`id` param3=$HOME"#)
        XCTAssertEqual(line.params["param1"], "$(whoami)")
        XCTAssertEqual(line.params["param2"], "`id`")
        XCTAssertEqual(line.params["param3"], "$HOME")
    }

    func testUnclosedQuoteMakesTheLineInert() {
        let line = XbarPlugin.parseLine(#"Danger | bash=/bin/rm param1="-rf"#)
        XCTAssertTrue(line.malformed)
        XCTAssertNil(XbarPlugin.action(for: line, context: .init(selfCommand: "./p.sh")))
    }

    func testEscapedQuotesStayInsideTheValue() {
        let line = XbarPlugin.parseLine(#"Go | bash=/bin/echo param1="a\" param2=INJECTED" param3='it\'s' param4="c:\\dir\n""#)
        XCTAssertFalse(line.malformed)
        XCTAssertEqual(line.params["param1"], #"a" param2=INJECTED"#)
        XCTAssertNil(line.params["param2"])
        XCTAssertEqual(line.params["param3"], "it's")
        XCTAssertEqual(line.params["param4"], #"c:\dir\n"#, "an escaped backslash is one; other backslashes stay")
        XCTAssertTrue(XbarPlugin.parseLine(#"x | param1="ends escaped\""#).malformed, "an escaped final quote leaves it open")
        XCTAssertTrue(XbarPlugin.parseLine(#"x | param1="a"b"#).malformed, "a closing quote needs a boundary")
    }

    func testLongDepthPrefixIsCheap() {
        let start = Date()
        let line = XbarPlugin.parseLine(String(repeating: "--", count: 160_000) + "x")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(line.text, "x")
        XCTAssertEqual(line.depth, XbarPlugin.maxDepth + 1)
    }

    func testEmptyValuesBareWordsAndDuplicates() {
        let line = XbarPlugin.parseLine(#"x | color= stray color="green" param1="""#)
        XCTAssertEqual(line.params["color"], "green")
        XCTAssertEqual(line.params["param1"], "")
    }

    func testLineCap() {
        let many = (0..<1000).map { "line \($0)" }.joined(separator: "\n")
        let out = XbarPlugin.parse("t\n---\n" + many)
        XCTAssertEqual(out.titles.count + out.items.count + 1, XbarPlugin.maxLines)
    }

    // MARK: Actions

    private func action(_ raw: String, _ context: XbarPlugin.Context = .init(selfCommand: "./p.5m.sh")) -> XbarPlugin.LineAction? {
        XbarPlugin.action(for: XbarPlugin.parseLine(raw), context: context)
    }

    func testBashBecomesARunActionWithParamsInNumericOrder() {
        let result = action(#"Go | bash=/usr/bin/say param10=ten param2=two param0=zero param1=one param99=far refresh=true terminal=false"#)
        XCTAssertEqual(result, .action(NodeAction(type: "run", command: ["/usr/bin/say", "zero", "one", "two", "ten"], thenRefresh: true)))
        XCTAssertEqual(action("x | shell=/bin/ls"), .action(NodeAction(type: "run", command: ["/bin/ls"])))
    }

    func testHugeParamIndexIsDroppedNotPadded() {
        XCTAssertEqual(XbarPlugin.params(of: ["param999999999": "x", "param3": "y", "param03": "z", "paramx": "w"]), ["y"])
    }

    func testTerminalTrueIsShownNotRun() {
        XCTAssertEqual(action("x | bash=/bin/ls terminal=true"), .terminal)
    }

    func testOnlyHTTPLinksOpen() {
        XCTAssertEqual(action("x | href=https://example.com"), .action(NodeAction(type: "openURL", url: "https://example.com")))
        XCTAssertEqual(action("x | href=http://example.com"), .action(NodeAction(type: "openURL", url: "http://example.com")))
        XCTAssertNil(action("x | href=file:///Applications/Calculator.app"))
        XCTAssertNil(action("x | href=x-apple.systempreferences:foo"))
        XCTAssertNil(action("x | href=myapp://x-callback-url/do"))
        XCTAssertNil(action("x | href=javascript:alert(1)"))
    }

    func testBashWinsOverHrefAndRefreshAloneRefreshes() {
        XCTAssertEqual(action("x | href=https://a.b bash=/bin/ls"), .action(NodeAction(type: "run", command: ["/bin/ls"])))
        XCTAssertEqual(action("x | refresh=true"), .action(NodeAction(type: "refresh")))
        XCTAssertNil(action("just text"))
    }

    func testSelfCallRewriteNeedsTheSameFile() throws {
        let widget = tempDir.appendingPathComponent("w", isDirectory: true)
        let other = tempDir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let plugin = widget.appendingPathComponent("p.5m.sh")
        try Data("#!/bin/sh\n".utf8).write(to: plugin)
        try Data("#!/bin/sh\n".utf8).write(to: other.appendingPathComponent("p.5m.sh"))
        let link = tempDir.appendingPathComponent("link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plugin)
        let context = XbarPlugin.Context(selfCommand: "./p.5m.sh", pluginFile: plugin)

        func resolved(_ bash: String) -> String { XbarPlugin.resolveSelf(bash, context: context) }
        XCTAssertEqual(resolved(plugin.path), "./p.5m.sh", "$0 as an absolute path")
        XCTAssertEqual(resolved(other.path + "/../w/p.5m.sh"), "./p.5m.sh", "a .. path that lands on it")
        XCTAssertEqual(resolved(link.path), "./p.5m.sh", "a link to it")
        XCTAssertEqual(resolved("./p.5m.sh"), "./p.5m.sh")
        XCTAssertEqual(resolved(other.appendingPathComponent("p.5m.sh").path), other.appendingPathComponent("p.5m.sh").path,
                       "same name elsewhere is not the plugin")
        XCTAssertEqual(resolved("p.5m.sh"), "p.5m.sh", "a relative spelling other than the declared one is left alone")
        XCTAssertEqual(resolved(widget.path + "/../w/../other/p.5m.sh"), widget.path + "/../w/../other/p.5m.sh")
        // With a space in the path.
        let spaced = tempDir.appendingPathComponent("with space", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        let spacedPlugin = spaced.appendingPathComponent("p.sh")
        try Data().write(to: spacedPlugin)
        XCTAssertEqual(XbarPlugin.resolveSelf(spacedPlugin.path, context: .init(selfCommand: "./p.sh", pluginFile: spacedPlugin)), "./p.sh")
    }

    // MARK: Rendering

    /// A calendar plugin (xbar-plugins Time/cal.1d.sh) lines its columns up
    /// with spaces in a fixed-width font.
    func testFixedWidthLinesKeepTheirColumns() {
        let rendered = XbarPlugin.render(XbarPlugin.parse("""
        2026
        ---
            November 2026 | trim=false font=courier
        Su Mo Tu We Th Fr Sa | trim=false font=courier
         1  2  3  4  5  6  7 | trim=false font=courier
        Plain note
          Indented but trimmed | font=Menlo
        """), context: .init(selfCommand: "./cal.1d.sh"))
        let rows = (rendered.tree.children ?? []).filter { $0.type == "text" }
        let month = rows.first { $0.text?.contains("November") == true }
        XCTAssertEqual(month?.text, "    November 2026", "trim=false keeps the leading spaces")
        XCTAssertEqual(rows.first { $0.text?.contains("1  2") == true }?.text, " 1  2  3  4  5  6  7")

        let fixed = rows.filter { $0.role == "code" }
        XCTAssertEqual(fixed.count, 4)
        XCTAssertEqual(Set(fixed.map(\.lineLimit)), [1], "a wrapped row would lose its columns")
        XCTAssertEqual(Set(fixed.map(\.size)).count, 1, "one size, or the rows would not line up")
        XCTAssertEqual(fixed.first?.size, 12, "short lines keep the normal code size")

        XCTAssertEqual(rows.first { $0.text == "Plain note" }?.role, "body")
        XCTAssertEqual(rows.first { $0.text == "Indented but trimmed" }?.role, "code", "without trim=false the spaces go")
    }

    func testWideFixedWidthLinesShrinkToFitButStayReadable() {
        XCTAssertEqual(XbarPlugin.monospacedSize(columns: 20, nested: false), 12)
        let table = XbarPlugin.monospacedSize(columns: 48, nested: false)
        XCTAssertLessThan(table, 12)
        XCTAssertLessThanOrEqual(0.602 * 48 * table, 310)
        // `cal 2026`: three months side by side, 64 columns, still fits,
        // in a submenu's narrower card too.
        for nested in [false, true] {
            let year = XbarPlugin.monospacedSize(columns: 64, nested: nested)
            XCTAssertLessThanOrEqual(0.602 * 64 * year, nested ? 290 : 310)
            XCTAssertGreaterThanOrEqual(year, 7)
        }
        XCTAssertEqual(XbarPlugin.monospacedSize(columns: 400, nested: true), 7, "never below 7 pt")
    }

    func testLeadingSpacesAreCountedAfterTheSubmenuPrefix() {
        XCTAssertEqual(XbarPlugin.parseLine("   x | trim=false").leadingSpaces, 3)
        XCTAssertEqual(XbarPlugin.parseLine("--  x | trim=false").leadingSpaces, 2)
        XCTAssertEqual(XbarPlugin.parseLine("x").leadingSpaces, 0)
    }

    func testRenderTakesTheReadingFromTheFirstTitle() {
        let rendered = XbarPlugin.render(XbarPlugin.parse("""
        \u{1B}[31m:sunny: 21°\u{1B}[0m | sfimage=sun.max color=#ff3b30
        Feels 19°
        ---
        Forecast | href=https://example.com
        --Tomorrow 18°
        ---
        Reload | refresh=true
        Open shell | bash=/bin/zsh terminal=true
        """), context: .init(selfCommand: "./w.sh"))
        XCTAssertEqual(rendered.statusLabel, "☀️ 21°")
        XCTAssertEqual(rendered.statusIcon, "sun.max")
        XCTAssertEqual(rendered.statusTint, "danger")
        let children = rendered.tree.children ?? []
        XCTAssertEqual(children.map(\.type), ["hstack", "text", "divider", "button", "card", "divider", "button", "hstack"])
        XCTAssertEqual(children[3].action?.url, "https://example.com")
        XCTAssertEqual(children[4].children?.first?.text, "Tomorrow 18°")
        XCTAssertEqual(children[7].children?.last?.text, "Opens Terminal — not supported")
    }

    func testEmptyOutputSaysSo() {
        let rendered = XbarPlugin.render(XbarPlugin.parse(""), context: .init(selfCommand: "./w.sh"))
        XCTAssertNil(rendered.statusLabel)
        XCTAssertEqual(rendered.tree.children?.first?.type, "empty")
    }

    func testDepthJumpsAndOrphansAreNormalized() {
        let tree = XbarPlugin.buildTree(XbarPlugin.parse("t\n---\n----orphan\nA\n------deep\n---\n--after separator").items)
        XCTAssertEqual(tree.count, 4, "\(tree)")
        XCTAssertEqual(tree[0].line.text, "orphan")
        XCTAssertEqual(tree[1].children.first?.line.text, "deep", "two levels down becomes one")
        XCTAssertTrue(tree[2].line.isSeparator)
        XCTAssertEqual(tree[3].line.text, "after separator", "a separator adopts nothing")
    }

    func testDeepNestingIsCapped() {
        let lines = (0..<10).map { String(repeating: "--", count: $0) + "L\($0)" }.joined(separator: "\n")
        var node = XbarPlugin.buildTree(XbarPlugin.parse("t\n---\n" + lines).items).first
        var depth = 0
        while let next = node?.children.first { node = next; depth += 1 }
        XCTAssertEqual(depth, XbarPlugin.maxDepth)
    }

    func testColours() {
        XCTAssertEqual(XbarPlugin.tint(for: "red", dark: false), "danger")
        XCTAssertEqual(XbarPlugin.tint(for: "#0f0", dark: false), "good")
        XCTAssertEqual(XbarPlugin.tint(for: "#ffcc00", dark: false), "warning")
        XCTAssertEqual(XbarPlugin.tint(for: "#007aff", dark: false), "accent")
        XCTAssertEqual(XbarPlugin.tint(for: "red,green", dark: true), "good", "SwiftBar light,dark pair")
        XCTAssertNil(XbarPlugin.tint(for: "white", dark: false))
        XCTAssertNil(XbarPlugin.tint(for: "#zzz", dark: false))
    }

    func testEmojize() {
        XCTAssertEqual(XbarPlugin.cleanText(XbarPlugin.parseLine(":fire: 3 :nope: a:b")), "🔥 3 :nope: a:b")
        XCTAssertEqual(XbarPlugin.cleanText(XbarPlugin.parseLine(":fire: | emojize=false")), ":fire:")
    }

    // MARK: File name, metadata, environment

    func testIntervalFromTheFileName() {
        XCTAssertEqual(XbarPlugin.refreshInterval(fileName: "battery.5m.sh"), 300)
        XCTAssertEqual(XbarPlugin.refreshInterval(fileName: "a.10s.py"), 10)
        XCTAssertEqual(XbarPlugin.refreshInterval(fileName: "a.500ms.sh"), 0.5)
        XCTAssertEqual(XbarPlugin.refreshInterval(fileName: "a.2h.rb"), 7200)
        XCTAssertEqual(XbarPlugin.refreshInterval(fileName: "a.1d.sh"), 86400)
        XCTAssertEqual(XbarPlugin.refreshInterval(fileName: "a.sh"), 60, "no interval: every minute, as in xbar")
        XCTAssertEqual(XbarPlugin.refreshInterval(fileName: "my.plugin.sh"), 60, "a dotted name is not an interval")
        XCTAssertNil(XbarPlugin.refreshInterval(fileName: "a.0s.sh"))
        XCTAssertNil(XbarPlugin.refreshInterval(fileName: "a.999d.sh"))
        XCTAssertNil(XbarPlugin.refreshInterval(fileName: "a.-5m.sh"), "negative is refused, not defaulted")
        XCTAssertEqual(XbarPlugin.refreshInterval(fileName: "a.+5m.sh"), 300)
        XCTAssertEqual(XbarPlugin.baseName(fileName: "battery.5m.sh"), "battery")
        XCTAssertEqual(XbarPlugin.baseName(fileName: "battery.sh"), "battery")
        XCTAssertEqual(XbarPlugin.baseName(fileName: "my.weather.sh"), "my.weather")
        XCTAssertEqual(XbarPlugin.baseName(fileName: "my.weather.10m.sh"), "my.weather")
    }

    func testMetadata() {
        let meta = XbarPlugin.metadata(script: """
        #!/bin/bash
        # <xbar.title>Battery Level</xbar.title>
        # <xbar.version>v1.2</xbar.version>
        # <bitbar.desc>Old style</bitbar.desc>
        # <swiftbar.type>streamable</swiftbar.type>
        """)
        XCTAssertEqual(meta["title"], "Battery Level")
        XCTAssertEqual(meta["version"], "v1.2")
        XCTAssertEqual(meta["desc"], "Old style")
        XCTAssertEqual(meta["swiftbar.type"], "streamable")
    }

    func testEnvironment() {
        XCTAssertEqual(XbarPlugin.environment(darkMode: true), ["BARSHELF": "1", "XBARDarkMode": "true", "OS_APPEARANCE": "Dark"])
        XCTAssertEqual(XbarPlugin.environment(darkMode: false)["OS_APPEARANCE"], "Light")
        XCTAssertNil(XbarPlugin.environment(darkMode: false)["SWIFTBAR"])
    }

    // MARK: Install scaffold

    private func writePlugin(_ name: String, _ text: String, executable: Bool = true) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    func testScaffoldBuildsAValidWidget() throws {
        let plugin = try writePlugin("Battery Level.5m.sh", """
        #!/bin/bash
        # <xbar.title>Battery</xbar.title>
        # <xbar.version>v1.2</xbar.version>
        echo "🔋 80%"
        echo "---"
        echo "Again | bash='$0' param1=refresh"
        echo "Sleep | bash=/usr/bin/pmset param1=sleepnow"
        """, executable: false)
        let staging = tempDir.appendingPathComponent("staging", isDirectory: true)
        let scaffold = try XbarPluginInstall.scaffold(pluginFile: plugin, into: staging)
        XCTAssertEqual(scaffold.directory.lastPathComponent, "xbar.battery-level")
        XCTAssertEqual(scaffold.undeclaredCommands, ["/usr/bin/pmset"])
        let copy = scaffold.directory.appendingPathComponent("Battery Level.5m.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: copy.path), "a shebang file gets its executable bit")

        let data = try Data(contentsOf: scaffold.directory.appendingPathComponent("widget.json"))
        let manifest = try Manifest.decode(from: data)
        XCTAssertEqual(manifest.id, "xbar.battery-level")
        XCTAssertEqual(manifest.name, "Battery")
        XCTAssertEqual(manifest.source?.output, "xbar")
        XCTAssertEqual(manifest.source?.command, ["./Battery Level.5m.sh"])
        XCTAssertEqual(manifest.refresh?.interval, 300)
        XCTAssertEqual(manifest.permissions?.exec?.map(\.command), ["./Battery Level.5m.sh"])
        XCTAssertNil(manifest.permissions?.exec?.first?.allowedArgs, "the plugin may call itself with any arguments")
        XCTAssertEqual(manifest.minHostVersion, "0.7.35")

        let discovery = try WidgetDiscovery.discover(under: staging, subdirectory: nil)
        XCTAssertEqual(discovery.candidates.map(\.manifest.id), ["xbar.battery-level"])
        XCTAssertEqual(discovery.candidates.first?.displayVersion, "1.2.0")
    }

    func testScaffoldRefusals() throws {
        let staging = tempDir.appendingPathComponent("staging", isDirectory: true)
        let streaming = try writePlugin("s.sh", "#!/bin/sh\n# <swiftbar.type>streamable</swiftbar.type>\n")
        XCTAssertThrowsError(try XbarPluginInstall.scaffold(pluginFile: streaming, into: staging)) {
            XCTAssertEqual($0 as? XbarPluginInstall.InstallError, .streamable("s.sh"))
        }
        let zero = try writePlugin("z.0m.sh", "#!/bin/sh\n")
        XCTAssertThrowsError(try XbarPluginInstall.scaffold(pluginFile: zero, into: staging))
        let binary = try writePlugin("b.sh", "")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)
        XCTAssertThrowsError(try XbarPluginInstall.scaffold(pluginFile: binary, into: staging))
    }

    func testWhichLocalFilesArePlugins() throws {
        let executable = try writePlugin("a.sh", "echo hi")
        let shebang = try writePlugin("b.py", "#!/usr/bin/env python3\n", executable: false)
        let plain = try writePlugin("notes.txt", "hello", executable: false)
        let archive = try writePlugin("w.zip", "#!", executable: true)
        XCTAssertNotNil(XbarPluginInstall.localPluginFile(for: executable.path))
        XCTAssertNotNil(XbarPluginInstall.localPluginFile(for: "file://" + shebang.path))
        XCTAssertNil(XbarPluginInstall.localPluginFile(for: plain.path))
        XCTAssertNil(XbarPluginInstall.localPluginFile(for: archive.path))
        XCTAssertNil(XbarPluginInstall.localPluginFile(for: tempDir.path), "a directory is a widget folder, not a plugin")
        XCTAssertNil(XbarPluginInstall.localPluginFile(for: "https://example.com/a.sh"))
    }

    func testSlug() {
        XCTAssertEqual(XbarPluginInstall.slug("Battery Level!"), "battery-level")
        XCTAssertEqual(XbarPluginInstall.slug("日本"), "plugin")
        XCTAssertEqual(XbarPluginInstall.slug("--a__b--"), "a-b")
    }

    func testDottedNamesDoNotCollide() throws {
        let staging = tempDir.appendingPathComponent("staging", isDirectory: true)
        let weather = try XbarPluginInstall.scaffold(pluginFile: try writePlugin("my.weather.sh", "#!/bin/sh\n"), into: staging)
        let clock = try XbarPluginInstall.scaffold(pluginFile: try writePlugin("my.clock.sh", "#!/bin/sh\n"), into: staging)
        XCTAssertEqual(weather.directory.lastPathComponent, "xbar.my-weather")
        XCTAssertEqual(clock.directory.lastPathComponent, "xbar.my-clock")
        let widgets = tempDir.appendingPathComponent("widgets", isDirectory: true)
        let discovery = try WidgetDiscovery.discover(under: staging, subdirectory: nil)
        for candidate in discovery.candidates {
            _ = try HeadlessInstaller.install(InstallCandidate(candidate), into: widgets, hostVersion: nil)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: widgets.path)), ["xbar.my-weather", "xbar.my-clock"])
    }

    func testSessionFromAPluginFile() throws {
        let plugin = try writePlugin("cpu.10s.sh", "#!/bin/sh\necho 'CPU | bash=/usr/bin/top'\n")
        let session = try HeadlessInstaller.fetchSession(pluginFile: plugin)
        defer { session.cleanup() }
        XCTAssertEqual(session.candidates.map(\.manifest.id), ["xbar.cpu"])
        XCTAssertEqual(session.blockedPluginCommands, ["/usr/bin/top"])
    }
}
