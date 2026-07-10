import XCTest
@testable import MenubucketCore

/// Test double for the host context: canned stdout (or error) per command.
private struct MockAdapterContext: AdapterContext {
    var outputs: [String: Data] = [:]
    var errors: [String: AdapterError] = [:]
    var settings: [String: JSONValue] = [:]

    func runAllowed(command: [String]) async throws -> Data {
        let key = command.joined(separator: " ")
        if let error = errors[key] { throw error }
        guard let data = outputs[key] else {
            throw AdapterError.execNotAllowed(key)
        }
        return data
    }
}

final class OtpeekAdapterTests: XCTestCase {
    // Fixtures mirror the otpeek CLI: `list --json` is a camelCase array of
    // accounts (extra fields like `secret` present), `code <id> --json` is a
    // single OtpCode object.
    private let listFixture = Data("""
    [
      {
        "id": "acc-github", "type": "totp", "secret": "JBSWY3DPEHPK3PXP",
        "issuer": "GitHub", "accountName": "jiun@example.com",
        "algorithm": "SHA1", "digits": 6, "period": 30,
        "counter": 0, "isFavorite": true, "sortOrder": 0,
        "createdAt": 1700000000000, "updatedAt": 1700000000000, "deletedAt": null
      },
      {
        "id": "acc-bank", "type": "hotp", "secret": "AAAA",
        "issuer": "Bank", "accountName": "hotp-should-be-filtered",
        "algorithm": "SHA1", "digits": 6, "counter": 7,
        "isFavorite": false, "sortOrder": 1,
        "createdAt": 1700000000000, "updatedAt": 1700000000000
      },
      {
        "id": "acc-aws", "type": "totp", "secret": "BBBB",
        "issuer": "AWS", "accountName": "ops@example.com",
        "algorithm": "SHA256", "digits": 8, "period": 30,
        "isFavorite": false, "sortOrder": 2,
        "createdAt": 1700000000000, "updatedAt": 1700000000000
      }
    ]
    """.utf8)

    private let githubCode = Data(
        #"{"code":"728419","validFrom":1783442400000,"validUntil":1783442430000}"#.utf8
    )
    private let awsCode = Data(
        #"{"code":"12345678","validFrom":1783442400000,"validUntil":1783442410000}"#.utf8
    )

    private func makeContext(settings: [String: JSONValue] = [:]) -> MockAdapterContext {
        MockAdapterContext(outputs: [
            "otpeek code acc-github --json": githubCode,
            "otpeek code acc-aws --json": awsCode,
        ], settings: settings)
    }

    // MARK: - Happy path

    func testBuildsRowPerTotpAccountAndFiltersHotp() async throws {
        let result = try await OtpeekAdapter.adapt(listFixture, context: makeContext())
        let rows = result.viewTree.items ?? []
        XCTAssertEqual(result.viewTree.type, "list")
        XCTAssertEqual(result.viewTree.searchPlaceholder, "Search accounts…")
        XCTAssertEqual(rows.count, 2, "hotp account must be filtered out")
        XCTAssertEqual(rows[0].id, "otp-acc-github-row")
        XCTAssertEqual(rows[1].id, "otp-acc-aws-row")
    }

    func testRowCarriesCountdownRingAndCopyAction() async throws {
        let result = try await OtpeekAdapter.adapt(listFixture, context: makeContext())
        let row = try XCTUnwrap(result.viewTree.items?.first)
        let children = row.children ?? []

        let ring = try XCTUnwrap(children.first { $0.type == "progress" })
        XCTAssertEqual(ring.style, "ring")
        XCTAssertEqual(ring.countdown?.from, 1_783_442_400_000)
        XCTAssertEqual(ring.countdown?.until, 1_783_442_430_000)
        XCTAssertEqual(ring.labelFrom, "remainingSeconds")
        XCTAssertEqual(ring.tintRules?.first?.whenRemainingLtSeconds, 10)
        XCTAssertEqual(ring.tintRules?.first?.tint, "danger")

        let codeButton = try XCTUnwrap(children.first { $0.type == "button" })
        XCTAssertEqual(codeButton.title, "728 419", "6-digit code grouped in threes")
        XCTAssertEqual(codeButton.action?.type, "copyText")
        XCTAssertEqual(codeButton.action?.value, "728419", "copy the raw, ungrouped code")
        XCTAssertEqual(codeButton.action?.clearAfterSec, 30)

        let identity = try XCTUnwrap(children.first { $0.type == "vstack" })
        let texts = (identity.children ?? []).compactMap(\.text)
        XCTAssertEqual(texts, ["GitHub", "jiun@example.com"])

        let favorite = try XCTUnwrap(children.first { $0.id == "otp-acc-github-favorite" })
        XCTAssertEqual(favorite.type, "image")
        XCTAssertEqual(favorite.source, ImageSource(kind: "sfSymbol", name: "star.fill"))
        XCTAssertEqual(favorite.tint, "warning")
        XCTAssertEqual(favorite.accessibilityLabel, "Favorite")

        let regularRow = try XCTUnwrap(result.viewTree.items?.dropFirst().first)
        XCTAssertFalse(
            (regularRow.children ?? []).contains { $0.id == "otp-acc-aws-favorite" },
            "non-favorites should not reserve space for an empty star"
        )
    }

    // MARK: - Service icons (favicons)

    func testRowLeadsWithFaviconIconForKnownIssuer() async throws {
        let result = try await OtpeekAdapter.adapt(listFixture, context: makeContext())
        let rows = result.viewTree.items ?? []

        let githubIcon = try XCTUnwrap(rows[0].children?.first)
        XCTAssertEqual(githubIcon.id, "otp-acc-github-icon")
        XCTAssertEqual(githubIcon.type, "image")
        XCTAssertEqual(githubIcon.source?.kind, "url")
        XCTAssertEqual(
            githubIcon.source?.url,
            "https://www.google.com/s2/favicons?domain=github.com&sz=64"
        )
        XCTAssertEqual(githubIcon.source?.monogram, "G", "letter fallback while the favicon loads")
        XCTAssertEqual(githubIcon.accessibilityLabel, "GitHub")

        let awsIcon = try XCTUnwrap(rows[1].children?.first)
        XCTAssertEqual(
            awsIcon.source?.url,
            "https://www.google.com/s2/favicons?domain=aws.amazon.com&sz=64",
            "specific known mapping (aws) must win over the generic amazon one"
        )
    }

    func testUnresolvedIssuerFallsBackToMonogramIcon() async throws {
        let fixture = Data("""
        [{"id":"acc-x","type":"totp","issuer":"Internal Admin Tool","accountName":"me@gmail.com","isFavorite":false}]
        """.utf8)
        var context = makeContext()
        context.outputs["otpeek code acc-x --json"] = githubCode

        let result = try await OtpeekAdapter.adapt(fixture, context: context)
        let icon = try XCTUnwrap(result.viewTree.items?.first?.children?.first)
        XCTAssertEqual(icon.source?.kind, "monogram", "no confident domain → no network lookup")
        XCTAssertEqual(icon.source?.monogram, "I")
    }

    func testShowIconsOffOmitsIconNodes() async throws {
        let context = makeContext(settings: ["showIcons": .bool(false)])
        let result = try await OtpeekAdapter.adapt(listFixture, context: context)

        for row in result.viewTree.items ?? [] {
            XCTAssertFalse(
                (row.children ?? []).contains { ($0.id ?? "").hasSuffix("-icon") },
                "showIcons=false must drop the leading icon column"
            )
        }
    }

    func testErrorRowKeepsIconColumnForAlignment() async throws {
        var context = makeContext()
        context.outputs.removeValue(forKey: "otpeek code acc-aws --json")
        context.errors["otpeek code acc-aws --json"] = .message("boom")

        let result = try await OtpeekAdapter.adapt(listFixture, context: context)
        let errorRow = try XCTUnwrap(result.viewTree.items?.last)
        XCTAssertEqual(errorRow.children?.first?.id, "otp-acc-aws-icon")
    }

    func testFaviconDomainResolution() {
        func account(issuer: String? = nil, name: String? = nil) -> OtpeekAdapter.Account {
            .init(id: "x", issuer: issuer, accountName: name)
        }
        // Known mapping, case-insensitive substring.
        XCTAssertEqual(OtpeekAdapter.faviconDomain(for: account(issuer: "GitHub")), "github.com")
        XCTAssertEqual(
            OtpeekAdapter.faviconDomain(for: account(issuer: "Amazon Web Services")),
            "aws.amazon.com"
        )
        // Issuer that already looks like a domain.
        XCTAssertEqual(OtpeekAdapter.faviconDomain(for: account(issuer: "pixiv.net")), "pixiv.net")
        // Email account name → its host, unless it's a generic mail host.
        XCTAssertEqual(
            OtpeekAdapter.faviconDomain(for: account(issuer: "VPN", name: "me@callabo.ai")),
            "callabo.ai"
        )
        XCTAssertNil(OtpeekAdapter.faviconDomain(for: account(issuer: "VPN", name: "me@gmail.com")))
        // Unknown single-word issuer: guessing "{issuer}.com" would fetch a
        // misleading globe icon, so it resolves to nothing (monogram).
        XCTAssertNil(OtpeekAdapter.faviconDomain(for: account(issuer: "Zorbcorp")))
        XCTAssertNil(OtpeekAdapter.faviconDomain(for: account()))
    }

    func testNextRefreshAtIsEarliestValidUntilPlusSlack() async throws {
        let result = try await OtpeekAdapter.adapt(listFixture, context: makeContext())
        // AWS expires first (…410000) → min(validUntil) + 250.
        XCTAssertEqual(result.nextRefreshAtMs, 1_783_442_410_000 + 250)
        XCTAssertNil(result.statusText, "codes are sensitive — no status text")
    }

    func testFavoritesOnlyFiltersBeforeFetchingCodes() async throws {
        let context = makeContext(settings: ["favoritesOnly": .bool(true)])
        let result = try await OtpeekAdapter.adapt(listFixture, context: context)

        XCTAssertEqual(result.viewTree.items?.map(\.id), ["otp-acc-github-row"])
    }

    func testFavoritesFirstKeepsStableOrderWithinGroups() async throws {
        let fixture = Data("""
        [
          {"id":"acc-github","type":"totp","issuer":"GitHub","accountName":"me","isFavorite":false},
          {"id":"acc-aws","type":"totp","issuer":"AWS","accountName":"ops","isFavorite":true}
        ]
        """.utf8)
        let context = makeContext(settings: ["favoritesFirst": .bool(true)])
        let result = try await OtpeekAdapter.adapt(fixture, context: context)

        XCTAssertEqual(
            result.viewTree.items?.map(\.id),
            ["otp-acc-aws-row", "otp-acc-github-row"]
        )
    }

    func testFolderSettingLoadsOnlyThatFolder() async throws {
        let folderFixture = Data("""
        [{"id":"acc-aws","type":"totp","issuer":"AWS","accountName":"ops","isFavorite":false}]
        """.utf8)
        var context = makeContext(settings: ["folder": .string("Work")])
        context.outputs["otpeek list --folder Work --json"] = folderFixture

        let result = try await OtpeekAdapter.adapt(listFixture, context: context)

        XCTAssertEqual(result.viewTree.items?.map(\.id), ["otp-acc-aws-row"])
    }

    // MARK: - Failure modes

    func testPerAccountFailureRendersErrorRowAndKeepsOthers() async throws {
        var context = makeContext()
        context.outputs.removeValue(forKey: "otpeek code acc-aws --json")
        context.errors["otpeek code acc-aws --json"] = .message("exited with code 1: boom")

        let result = try await OtpeekAdapter.adapt(listFixture, context: context)
        let rows = result.viewTree.items ?? []
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(rows[0].children?.first { $0.type == "button" }, "good row keeps its code")

        let errorText = rows[1].children?.first { $0.foreground == "danger" }
        XCTAssertEqual(errorText?.text?.contains("boom"), true)
        XCTAssertEqual(
            result.nextRefreshAtMs, 1_783_442_430_000 + 250,
            "deadline computed from the surviving code"
        )
    }

    func testAllPasswordFailuresThrowWithKeychainGuidance() async {
        var context = MockAdapterContext()
        context.errors["otpeek code acc-github --json"] = .message("could not decrypt vault: wrong password")
        context.errors["otpeek code acc-aws --json"] = .message("could not decrypt vault: wrong password")

        do {
            _ = try await OtpeekAdapter.adapt(listFixture, context: context)
            XCTFail("expected AdapterError")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("security add-generic-password -s dev.barshelf -a otpeek-vault-password -w"))
        }
    }

    func testGarbageListOutputThrowsInvalidPayload() async {
        do {
            _ = try await OtpeekAdapter.adapt(Data("not json".utf8), context: makeContext())
            XCTFail("expected AdapterError.invalidPayload")
        } catch let error as AdapterError {
            guard case .invalidPayload = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testEmptyOrNonTotpVaultRendersEmptyState() async throws {
        let result = try await OtpeekAdapter.adapt(Data("[]".utf8), context: makeContext())
        XCTAssertEqual(result.viewTree.type, "empty")
        XCTAssertNil(result.nextRefreshAtMs)
    }

    // MARK: - Grouping

    func testCodeGrouping() {
        XCTAssertEqual(OtpeekAdapter.groupedCode("728419"), "728 419")
        XCTAssertEqual(OtpeekAdapter.groupedCode("12345678"), "1234 5678")
        XCTAssertEqual(OtpeekAdapter.groupedCode("123456789"), "123 456 789")
        XCTAssertEqual(OtpeekAdapter.groupedCode("1234"), "1234")
    }
}
