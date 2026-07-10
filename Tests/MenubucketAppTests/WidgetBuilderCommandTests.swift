import XCTest
@testable import MenubucketApp

/// The Create-tab "command" source and its gallery templates: a bare command is
/// exec'd directly, but a shell pipeline/expression must run under `/bin/sh -c`.
/// Tokenizing a pipeline and exec'ing argv[0] used to pass `|`, `jq`, … as
/// literal arguments, so every piped template failed on "test run".
@MainActor
final class WidgetBuilderCommandTests: XCTestCase {
    func testNeedsShellDetectsUnquotedOperators() {
        XCTAssertTrue(WidgetBuilderModel.needsShell("df -h / | tail -1"))
        XCTAssertTrue(WidgetBuilderModel.needsShell("a && b"))
        XCTAssertTrue(WidgetBuilderModel.needsShell("cat x > y"))
        XCTAssertTrue(WidgetBuilderModel.needsShell("ls *.txt"))
        XCTAssertTrue(WidgetBuilderModel.needsShell("echo $HOME"))
        XCTAssertTrue(WidgetBuilderModel.needsShell("echo $(date)"))
    }

    func testNeedsShellIgnoresQuotedMetacharacters() {
        // A bare command whose only metacharacters are inside quotes (an awk/jq
        // program, a literal argument) does not need a shell.
        XCTAssertFalse(WidgetBuilderModel.needsShell("echo 'a | b ; c'"))
        XCTAssertFalse(WidgetBuilderModel.needsShell("gh run list --limit 5 --json name,status"))
        XCTAssertFalse(WidgetBuilderModel.needsShell("aas usage --json"))
    }

    func testCommandArgvWrapsPipelinesInShell() {
        let piped = WidgetBuilderModel.commandArgv("df -h / | tail -1")
        XCTAssertEqual(Array(piped.prefix(2)), ["/bin/sh", "-c"])
        XCTAssertEqual(piped.count, 3)
        XCTAssertEqual(piped.last, "df -h / | tail -1")

        let bare = WidgetBuilderModel.commandArgv("gh run list --limit 5")
        XCTAssertEqual(bare.first, "gh")
        XCTAssertFalse(bare.contains("/bin/sh"))
    }

    /// Guards the regression: every gallery template yields a runnable argv, and
    /// any template that uses shell syntax routes through `/bin/sh -c` rather
    /// than handing operators to the first binary.
    func testGalleryTemplatesProduceRunnableArgv() {
        for template in WidgetBuilderModel.commandTemplates {
            let argv = WidgetBuilderModel.commandArgv(template.command)
            XCTAssertFalse(argv.isEmpty, "\(template.id): empty argv")
            XCTAssertFalse(
                ["|", "&", ";", ">", "<"].contains(argv[0]),
                "\(template.id): argv[0] is a stray shell operator (\(argv[0]))"
            )
            if WidgetBuilderModel.needsShell(template.command) {
                XCTAssertEqual(
                    Array(argv.prefix(2)), ["/bin/sh", "-c"],
                    "\(template.id): shell-syntax template must run under /bin/sh -c"
                )
            }
        }
    }
}
