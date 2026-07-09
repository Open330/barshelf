import XCTest
@testable import MenubucketCore

final class AasUsageAdapterTests: XCTestCase {
    private let fixture = """
    {
      "accounts": [
        {
          "provider": "anthropic",
          "name": "work",
          "email": "work@example.com",
          "active": true,
          "plan": "max",
          "planLabel": "Max 20x",
          "headline": "5h: 12% left",
          "error": null,
          "meters": [
            { "label": "5h window", "usedPct": 88, "resetMs": 1752003600000 },
            { "label": "Weekly", "usedPct": 45, "resetMs": 1752300000000 }
          ]
        },
        {
          "provider": "anthropic",
          "name": "personal",
          "active": false,
          "plan": "pro",
          "meters": [
            { "label": "5h window", "usedPct": 95 }
          ]
        },
        {
          "provider": "openai",
          "name": "team",
          "active": true,
          "error": "token expired",
          "meters": []
        }
      ]
    }
    """.data(using: .utf8)!

    func testAdaptProducesExpectedStructure() throws {
        let tree = AasUsageAdapter.adapt(fixture)

        XCTAssertEqual(tree.type, "vstack")
        let children = try XCTUnwrap(tree.children)

        // Header: "aas" title + worst-remaining summary.
        let header = try XCTUnwrap(children.first)
        XCTAssertEqual(header.type, "hstack")
        XCTAssertEqual(header.children?.first?.text, "aas")
        let summary = try XCTUnwrap(header.children?.last)
        XCTAssertEqual(summary.text, "5% left")
        XCTAssertEqual(summary.foreground, "danger")

        // One section per provider, order preserved.
        let sections = children.filter { $0.type == "section" }
        XCTAssertEqual(sections.map { $0.title }, ["Claude", "OpenAI"])

        // Footer refresh button.
        let footer = try XCTUnwrap(children.last)
        XCTAssertEqual(footer.type, "button")
        XCTAssertEqual(footer.action?.type, "refresh")
    }

    func testMeterSeverityTints() throws {
        let tree = AasUsageAdapter.adapt(fixture)
        let anthropic = try XCTUnwrap(tree.children?.first { $0.type == "section" && $0.title == "Claude" })
        let progressNodes = flatten(anthropic).filter { $0.type == "progress" }
        XCTAssertEqual(progressNodes.count, 3)

        // usedPct 88 → remaining 12 → warning; 45 → 55 → good; 95 → 5 → danger.
        XCTAssertEqual(progressNodes[0].tint, "warning")
        XCTAssertEqual(progressNodes[0].value ?? 0, 0.88, accuracy: 0.0001)
        XCTAssertEqual(progressNodes[1].tint, "good")
        XCTAssertEqual(progressNodes[2].tint, "danger")
    }

    func testAccountRowsAndErrors() throws {
        let tree = AasUsageAdapter.adapt(fixture)
        let all = flatten(tree)

        // Accounts render as dedicated cards.
        let cards = all.filter { $0.type == "card" }
        XCTAssertEqual(cards.count, 3)
        XCTAssertTrue(cards.contains { $0.tone == "warning" })
        XCTAssertTrue(cards.contains { $0.tone == "danger" })

        // Provider glyphs are mapped from provider identity.
        let providerIcons = all.filter { $0.id?.hasSuffix("-provider-icon") == true }
        XCTAssertEqual(providerIcons.map { $0.source?.name }, [
            "sparkles", "sparkles", "circle.hexagongrid.fill",
        ])

        // Plan badge uses planLabel when present and normalizes max labels.
        let badges = all.filter { $0.type == "badge" }
        XCTAssertTrue(badges.contains { $0.text == "MAX · 20x" })
        XCTAssertTrue(badges.contains { $0.text == "PRO" })
        XCTAssertTrue(badges.contains { $0.text == "ACTIVE" })

        // Account error rendered as a danger banner.
        let errorNode = try XCTUnwrap(all.first { $0.text == "token expired" })
        XCTAssertEqual(errorNode.type, "banner")
        XCTAssertEqual(errorNode.tone, "danger")

        // resetMs is surfaced as a visible ETA/reset caption.
        XCTAssertTrue(all.contains { node in
            node.id?.hasSuffix("-caption") == true
                && (node.text?.contains("reset") ?? false)
        })
    }

    func testRepeatedNodesHaveStableUniqueIDs() {
        let tree = AasUsageAdapter.adapt(fixture)
        let ids = flatten(tree).compactMap { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate node ids break SwiftUI identity")

        // Determinism: same input → same ids.
        let secondIDs = flatten(AasUsageAdapter.adapt(fixture)).compactMap { $0.id }
        XCTAssertEqual(ids, secondIDs)
    }

    func testGarbageInputYieldsDangerBanner() {
        let tree = AasUsageAdapter.adapt(Data("not json".utf8))
        XCTAssertEqual(tree.type, "banner")
        XCTAssertEqual(tree.tone, "danger")
    }

    func testEmptyAccountsYieldsEmptyState() throws {
        let tree = AasUsageAdapter.adapt(Data(#"{"accounts": []}"#.utf8))
        let empty = try XCTUnwrap(flatten(tree).first { $0.type == "empty" })
        XCTAssertEqual(empty.title, "No accounts")
    }

    // MARK: - Helpers

    private func flatten(_ node: UINode) -> [UINode] {
        var result = [node]
        for child in (node.children ?? []) + (node.items ?? []) {
            result.append(contentsOf: flatten(child))
        }
        return result
    }
}
