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
                    id: "b",
                    type: "button",
                    title: "Copy",
                    icon: "doc.on.doc",
                    action: NodeAction(type: "copyText", value: "hi", toast: "Copied")
                ),
                UINode(id: "lst", type: "list", items: [
                    UINode(id: "i0", type: "text", text: "row 0"),
                ]),
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
    }

    func testActionDecoding() throws {
        let json = """
        { "type": "button", "title": "Open", "action": { "type": "openURL", "url": "https://example.com" } }
        """.data(using: .utf8)!
        let node = try JSONDecoder().decode(UINode.self, from: json)
        XCTAssertEqual(node.action?.type, "openURL")
        XCTAssertEqual(node.action?.url, "https://example.com")
    }
}
