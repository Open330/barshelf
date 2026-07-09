import Foundation

/// Authoring graph for the Builder canvas. The runtime still consumes
/// `WorkflowDefinition`; this graph is a higher-level editing model that
/// compiles down to the existing workflow contract.
public struct WorkflowGraph: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var nodes: [Node]
    public var edges: [Edge]
    public var view: JSONValue
    public var empty: JSONValue?
    public var status: WorkflowDefinition.StatusDef?

    public init(
        schemaVersion: Int = 1,
        nodes: [Node],
        edges: [Edge] = [],
        view: JSONValue,
        empty: JSONValue? = nil,
        status: WorkflowDefinition.StatusDef? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
        self.edges = edges
        self.view = view
        self.empty = empty
        self.status = status
    }

    public struct Node: Codable, Equatable, Sendable {
        public var id: String
        public var title: String?
        public var position: Position?
        public var operation: Operation

        public init(
            id: String,
            title: String? = nil,
            position: Position? = nil,
            operation: Operation
        ) {
            self.id = id
            self.title = title
            self.position = position
            self.operation = operation
        }
    }

    public struct Position: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Edge: Codable, Equatable, Sendable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public enum Operation: Equatable, Sendable {
        case source(use: String, with: JSONValue? = nil)
        case transform(use: String, from: String? = nil, with: JSONValue? = nil)
        case display
    }
}

extension WorkflowGraph.Operation: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case use
        case from
        case with
    }

    private enum OperationType: String, Codable {
        case source
        case transform
        case display
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(OperationType.self, forKey: .type)
        switch type {
        case .source:
            let use = try container.decode(String.self, forKey: .use)
            let params = try container.decodeIfPresent(JSONValue.self, forKey: .with)
            self = .source(use: use, with: params)
        case .transform:
            let use = try container.decode(String.self, forKey: .use)
            let from = try container.decodeIfPresent(String.self, forKey: .from)
            let params = try container.decodeIfPresent(JSONValue.self, forKey: .with)
            self = .transform(use: use, from: from, with: params)
        case .display:
            self = .display
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .source(use, params):
            try container.encode(OperationType.source, forKey: .type)
            try container.encode(use, forKey: .use)
            try container.encodeIfPresent(params, forKey: .with)
        case let .transform(use, from, params):
            try container.encode(OperationType.transform, forKey: .type)
            try container.encode(use, forKey: .use)
            try container.encodeIfPresent(from, forKey: .from)
            try container.encodeIfPresent(params, forKey: .with)
        case .display:
            try container.encode(OperationType.display, forKey: .type)
        }
    }
}

public enum WorkflowGraphError: Error, LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case duplicateNodeID(String)
    case missingEdgeEndpoint(String)
    case missingTransformInput(String)
    case displayNodeUsedAsInput(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "unsupported workflow graph schemaVersion: \(version)"
        case let .duplicateNodeID(id):
            return "duplicate workflow graph node id: \(id)"
        case let .missingEdgeEndpoint(id):
            return "workflow graph edge references a missing node: \(id)"
        case let .missingTransformInput(id):
            return "workflow graph transform needs one input edge or an explicit from path: \(id)"
        case let .displayNodeUsedAsInput(id):
            return "workflow graph display node cannot be used as data input: \(id)"
        }
    }
}

public enum WorkflowGraphCompiler {
    public static func compile(_ graph: WorkflowGraph) throws -> WorkflowDefinition {
        guard graph.schemaVersion == 1 else {
            throw WorkflowGraphError.unsupportedSchemaVersion(graph.schemaVersion)
        }

        let nodesByID = try indexNodes(graph.nodes)
        try validateEdges(graph.edges, nodesByID: nodesByID)

        var sources: [String: WorkflowDefinition.SourceDef] = [:]
        var transforms: [String: WorkflowDefinition.TransformDef] = [:]

        for node in graph.nodes {
            switch node.operation {
            case let .source(use, params):
                sources[node.id] = .init(use: use, with: params)
            case let .transform(use, explicitFrom, params):
                let from = try explicitFrom ?? inferredInputPath(
                    for: node.id,
                    edges: graph.edges,
                    nodesByID: nodesByID
                )
                transforms[node.id] = .init(use: use, from: from, with: params)
            case .display:
                break
            }
        }

        return WorkflowDefinition(
            schemaVersion: 1,
            kind: "workflow",
            sources: sources,
            transforms: transforms.isEmpty ? nil : transforms,
            view: graph.view,
            empty: graph.empty,
            status: graph.status
        )
    }

    private static func indexNodes(_ nodes: [WorkflowGraph.Node]) throws -> [String: WorkflowGraph.Node] {
        var nodesByID: [String: WorkflowGraph.Node] = [:]
        for node in nodes {
            if nodesByID[node.id] != nil {
                throw WorkflowGraphError.duplicateNodeID(node.id)
            }
            nodesByID[node.id] = node
        }
        return nodesByID
    }

    private static func validateEdges(
        _ edges: [WorkflowGraph.Edge],
        nodesByID: [String: WorkflowGraph.Node]
    ) throws {
        for edge in edges {
            guard nodesByID[edge.from] != nil else {
                throw WorkflowGraphError.missingEdgeEndpoint(edge.from)
            }
            guard nodesByID[edge.to] != nil else {
                throw WorkflowGraphError.missingEdgeEndpoint(edge.to)
            }
        }
    }

    private static func inferredInputPath(
        for transformID: String,
        edges: [WorkflowGraph.Edge],
        nodesByID: [String: WorkflowGraph.Node]
    ) throws -> String {
        let incoming = edges.filter { $0.to == transformID }
        guard incoming.count == 1 else {
            throw WorkflowGraphError.missingTransformInput(transformID)
        }
        return try outputPath(for: incoming[0].from, nodesByID: nodesByID)
    }

    private static func outputPath(
        for nodeID: String,
        nodesByID: [String: WorkflowGraph.Node]
    ) throws -> String {
        guard let node = nodesByID[nodeID] else {
            throw WorkflowGraphError.missingEdgeEndpoint(nodeID)
        }
        switch node.operation {
        case .source:
            return "$.sources.\(nodeID)"
        case .transform:
            return "$.transforms.\(nodeID)"
        case .display:
            throw WorkflowGraphError.displayNodeUsedAsInput(nodeID)
        }
    }
}
