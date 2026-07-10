import XCTest
@testable import MenubucketCore

final class UINodeTests: XCTestCase {
    func testRoundTrip() throws {
        let tree = UINode(
            id: "root",
            type: "vstack",
            children: [
                UINode(id: "t1", type: "text", text: "Hello", role: "title", lineLimit: 1),
                UINode(
                    id: "row",
                    type: "hstack",
                    children: [
                        UINode(
                            id: "icon",
                            type: "image",
                            source: ImageSource(kind: "sfSymbol", name: "gauge"),
                            size: 12,
                            tint: "accent"
                        ),
                        UINode(id: "sp", type: "spacer"),
                        UINode(id: "badge", type: "badge", text: "Pro", tint: "good"),
                    ],
                    spacing: 4
                ),
                UINode(id: "p", type: "progress", tint: "warning", value: 0.42, label: "Quota"),
                UINode(
                    id: "card",
                    type: "card",
                    children: [UINode(id: "card-text", type: "text", text: "Grouped")],
                    spacing: 4,
                    tone: "accent"
                ),
                UINode(
                    id: "b",
                    type: "button",
                    title: "Copy",
                    icon: "doc.on.doc",
                    action: NodeAction(type: "copyText", value: "hi", toast: "Copied")
                ),
                UINode(
                    id: "lst",
                    type: "list",
                    items: [UINode(id: "i0", type: "text", text: "row 0")],
                    searchPlaceholder: "Search rows"
                ),
            ],
            spacing: 8,
            padding: 4,
            widthFill: true
        )

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(UINode.self, from: data)
        XCTAssertEqual(decoded, tree)
    }

    func testUnknownTypeDecodesSuccessfully() throws {
        // Forward compatibility: unknown node types (and unknown fields) must decode.
        let json = """
        {
          "type": "vstack",
          "children": [
            { "id": "known", "type": "text", "text": "hi" },
            { "id": "future", "type": "sparkline", "points": [1, 2, 3], "style": "area" },
            { "id": "grid", "type": "grid", "columns": 2 }
          ]
        }
        """.data(using: .utf8)!

        let node = try JSONDecoder().decode(UINode.self, from: json)
        XCTAssertEqual(node.type, "vstack")
        XCTAssertEqual(node.children?.count, 3)
        XCTAssertEqual(node.children?[1].type, "sparkline")
        XCTAssertFalse(node.children?[1].isKnownType ?? true)
        XCTAssertTrue(node.children?[0].isKnownType ?? false)
        XCTAssertTrue(UINode(type: "card").isKnownType)
    }

    func testAccessibilityLabelDecoding() throws {
        let json = """
        {
          "type": "image",
          "source": { "kind": "sfSymbol", "name": "wifi.slash" },
          "accessibilityLabel": "Offline"
        }
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(UINode.self, from: json)
        XCTAssertEqual(node.accessibilityLabel, "Offline")
    }

    func testAccessibilityLabelDefaultsToNil() throws {
        let json = """
        { "type": "text", "text": "hi" }
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(UINode.self, from: json)
        XCTAssertNil(node.accessibilityLabel)
    }

    func testAccessibilityLabelRoundTrip() throws {
        let node = UINode(
            type: "button",
            title: "Copy",
            icon: "doc.on.doc",
            action: NodeAction(type: "copyText", value: "hi"),
            accessibilityLabel: "Copy to clipboard"
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(UINode.self, from: data)
        XCTAssertEqual(decoded, node)
        XCTAssertEqual(decoded.accessibilityLabel, "Copy to clipboard")
    }

    func testAccessibilityLabelCoexistsWithUnknownFields() throws {
        // The label must decode even alongside forward-compat unknown fields.
        let json = """
        {
          "type": "sparkline",
          "points": [1, 2, 3],
          "accessibilityLabel": "Weekly usage trend",
          "futureField": { "nested": true }
        }
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(UINode.self, from: json)
        XCTAssertEqual(node.accessibilityLabel, "Weekly usage trend")
        XCTAssertFalse(node.isKnownType)
    }

    func testActionDecoding() throws {
        let json = """
        { "type": "button", "title": "Open", "action": { "type": "openURL", "url": "https://example.com" } }
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(UINode.self, from: json)
        XCTAssertEqual(node.action?.type, "openURL")
        XCTAssertEqual(node.action?.url, "https://example.com")
    }

    func testVisibleTextSearchMatchesNestedRowsAndExcludesActionPayloads() {
        let row = UINode(
            id: "account-row",
            type: "hstack",
            children: [
                UINode(type: "vstack", children: [
                    UINode(type: "text", text: "GitHub"),
                    UINode(type: "text", text: "jiun@example.com"),
                ]),
                UINode(
                    type: "button",
                    title: "728 419",
                    action: NodeAction(type: "copyText", value: "hidden-secret")
                ),
            ]
        )

        XCTAssertTrue(row.matchesSearch("github"))
        XCTAssertTrue(row.matchesSearch("GITHUB example"))
        XCTAssertTrue(row.matchesSearch("728"))
        XCTAssertFalse(row.matchesSearch("hidden-secret"))
        XCTAssertFalse(row.matchesSearch("aws"))
        XCTAssertTrue(row.matchesSearch("   "))
    }
}
