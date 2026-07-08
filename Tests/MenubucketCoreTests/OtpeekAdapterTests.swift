import XCTest
@testable import MenubucketCore

/// Test double for the host context: canned stdout (or error) per command.
private struct MockAdapterContext: AdapterContext {
    var outputs: [String: Data] = [:]
    var errors: [String: AdapterError] = [:]

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

    private func makeContext() -> MockAdapterContext {
        MockAdapterContext(outputs: [
            "otpeek code acc-github --json": githubCode,
            "otpeek code acc-aws --json": awsCode,
        ])
    }

    // MARK: - Happy path

    func testBuildsRowPerTotpAccountAndFiltersHotp() async throws {
        let result = try await OtpeekAdapter.adapt(listFixture, context: makeContext())
        let rows = result.viewTree.items ?? []
        XCTAssertEqual(result.viewTree.type, "list")
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
    }

    func testNextRefreshAtIsEarliestValidUntilPlusSlack() async throws {
        let result = try await OtpeekAdapter.adapt(listFixture, context: makeContext())
        // AWS expires first (…410000) → min(validUntil) + 250.
        XCTAssertEqual(result.nextRefreshAtMs, 1_783_442_410_000 + 250)
        XCTAssertNil(result.statusText, "codes are sensitive — no status text")
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
            XCTAssertTrue(message.contains("security add-generic-password -s dev.menubucket -a otpeek-vault-password -w"))
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
