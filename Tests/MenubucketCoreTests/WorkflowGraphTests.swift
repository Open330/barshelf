import XCTest
@testable import MenubucketCore

final class WorkflowGraphTests: XCTestCase {
    func testCompilesSourceTransformGraphToWorkflow() throws {
        let rows: JSONValue = .array([
            .object(["name": .string("Build"), "state": .string("ok")]),
            .object(["name": .string("Deploy"), "state": .string("waiting")]),
        ])
        let graph = WorkflowGraph(
            nodes: [
                .init(
                    id: "data",
                    title: "Paste JSON",
                    position: .init(x: 40, y: 80),
                    operation: .source(use: "value", with: rows)
                ),
                .init(
                    id: "top",
                    title: "Limit",
                    position: .init(x: 260, y: 80),
                    operation: .transform(use: "limit", with: .object(["count": .number(1)]))
                ),
                .init(
                    id: "display",
                    title: "List",
                    position: .init(x: 480, y: 80),
                    operation: .display
                ),
            ],
            edges: [
                .init(from: "data", to: "top"),
                .init(from: "top", to: "display"),
            ],
            view: .object([
                "type": .string("list"),
                "items": .object([
                    "forEach": .string("$.transforms.top"),
                    "as": .string("row"),
                    "template": .object([
                        "type": .string("text"),
                        "text": .string("${row.name}: ${row.state}"),
                    ]),
                ]),
            ]),
            status: .init(tooltip: "${count(transforms.top)} rows")
        )

        let workflow = try WorkflowGraphCompiler.compile(graph)
        XCTAssertEqual(workflow.sources["data"], .init(use: "value", with: rows))
        XCTAssertEqual(
            workflow.transforms?["top"],
            .init(use: "limit", from: "$.sources.data", with: .object(["count": .number(1)]))
        )

        let sourceParams = try WorkflowEngine.resolvedSourceParams(workflow, settings: .object([:]))
        let output = try WorkflowEngine.evaluate(
            workflow,
            sources: sourceParams,
            settings: .object([:])
        )
        XCTAssertEqual(output.expandedItemCount, 1)
        XCTAssertEqual(output.statusTooltip, "1 rows")
        XCTAssertEqual(output.viewTree.items?.first?.text, "Build: ok")
    }

    func testExplicitTransformFromOverridesIncomingEdgeInference() throws {
        let graph = WorkflowGraph(
            nodes: [
                .init(id: "data", operation: .source(use: "value", with: .object([
                    "items": .array([.object(["name": .string("A")])]),
                ]))),
                .init(id: "visible", operation: .transform(
                    use: "assign",
                    from: "$.sources.data.items"
                )),
            ],
            edges: [.init(from: "data", to: "visible")],
            view: .object(["type": .string("divider")])
        )

        let workflow = try WorkflowGraphCompiler.compile(graph)
        XCTAssertEqual(workflow.transforms?["visible"]?.from, "$.sources.data.items")
    }

    func testGraphRoundTripsWithStableOperationShape() throws {
        let graph = WorkflowGraph(
            nodes: [
                .init(
                    id: "api",
                    operation: .source(
                        use: "http",
                        with: .object(["url": .string("https://api.example.com/status")])
                    )
                ),
                .init(id: "value", operation: .display),
            ],
            view: .object(["type": .string("text"), "text": .string("${sources.api.status}")])
        )

        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(WorkflowGraph.self, from: data)
        XCTAssertEqual(decoded, graph)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        let operation = try XCTUnwrap(nodes.first?["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "source")
        XCTAssertEqual(operation["use"] as? String, "http")
    }

    func testRejectsDuplicateNodeIDs() {
        let graph = WorkflowGraph(
            nodes: [
                .init(id: "data", operation: .source(use: "value")),
                .init(id: "data", operation: .display),
            ],
            view: .object(["type": .string("divider")])
        )

        XCTAssertThrowsError(try WorkflowGraphCompiler.compile(graph)) { error in
            XCTAssertEqual(error as? WorkflowGraphError, .duplicateNodeID("data"))
        }
    }

    func testRejectsMissingEdgeEndpoint() {
        let graph = WorkflowGraph(
            nodes: [.init(id: "top", operation: .transform(use: "limit"))],
            edges: [.init(from: "missing", to: "top")],
            view: .object(["type": .string("divider")])
        )

        XCTAssertThrowsError(try WorkflowGraphCompiler.compile(graph)) { error in
            XCTAssertEqual(error as? WorkflowGraphError, .missingEdgeEndpoint("missing"))
        }
    }

    func testRejectsTransformWithoutSingleInput() {
        let graph = WorkflowGraph(
            nodes: [.init(id: "top", operation: .transform(use: "limit"))],
            view: .object(["type": .string("divider")])
        )

        XCTAssertThrowsError(try WorkflowGraphCompiler.compile(graph)) { error in
            XCTAssertEqual(error as? WorkflowGraphError, .missingTransformInput("top"))
        }
    }

    func testRejectsDisplayNodeAsTransformInput() {
        let graph = WorkflowGraph(
            nodes: [
                .init(id: "display", operation: .display),
                .init(id: "top", operation: .transform(use: "limit")),
            ],
            edges: [.init(from: "display", to: "top")],
            view: .object(["type": .string("divider")])
        )

        XCTAssertThrowsError(try WorkflowGraphCompiler.compile(graph)) { error in
            XCTAssertEqual(error as? WorkflowGraphError, .displayNodeUsedAsInput("display"))
        }
    }
}
