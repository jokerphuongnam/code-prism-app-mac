import Foundation
import simd

/// Display node for the 3D graph (normalized from analyzer SoT).
struct GraphNode: Identifiable, Hashable {
    var id: String
    var name: String
    var flavor: String
    var filePath: String
    var line: Int
    var signature: String
    var dependencies: [String]
    /// Prism language id when known (`swift`, `marlin`, …). Empty if unspecified.
    var language: String = ""
    /// Parent archipelagos, outer to inner. The view draws only leaves inside this area.
    var group: String = ""
}

struct GraphLink: Identifiable, Hashable {
    var id: String { "\(source)->\(target):\(kind)" }
    var source: String
    var target: String
    var kind: String // "depends" | "call"
}

struct GraphDocument: Equatable {
    var projectRoot: String
    var generatedAt: String
    var nodes: [GraphNode]
    var links: [GraphLink]

    static let empty = GraphDocument(projectRoot: "", generatedAt: "", nodes: [], links: [])
}

/// Analyzer `--context` v2 JSON (LiteTrace sample).
struct ContextV2File: Decodable {
    var path: String
    var target: String?
    var signatures: [ContextV2Signature]
}

struct ContextV2Signature: Decodable {
    var id: String
    var line: Int?
    var signature: String?
    var dependencies: [String]?
    var resources: [String]?
}

struct ContextV2Document: Decodable {
    var version: String?
    var generatedAt: String?
    var projectType: String?
    var files: [ContextV2File]?
    var dependencyIndex: [String: [String]]?
}

/// Flat MCP / schema 4 nodes array (optional path).
struct FlatGraphDocument: Decodable {
    var nodes: [FlatGraphNode]?
    var schemaVersion: String?
    var generatedAt: String?
    var projectRoot: String?
}

struct FlatGraphNode: Decodable {
    var id: String
    var name: String
    var kind: String?
    var flavor: String?
    var location: FlatLocation?
    var parents: [String]?
    var calls: [FlatCall]?
    var nodes: [FlatGraphNode]?
    var node_context: String?
}

enum FlatCall: Decodable {
    case id(String)
    case link(target: String, kind: String)

    var target: String {
        switch self {
        case .id(let value): return value
        case .link(let target, _): return target
        }
    }

    var kind: String {
        switch self {
        case .id: return "call"
        case .link(_, let kind): return kind
        }
    }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = .id(text)
            return
        }
        let box = try decoder.container(keyedBy: CodingKeys.self)
        self = .link(
            target: try box.decode(String.self, forKey: .target),
            kind: try box.decodeIfPresent(String.self, forKey: .kind) ?? "call"
        )
    }

    private enum CodingKeys: String, CodingKey { case target, kind }
}

struct FlatLocation: Decodable {
    var absPath: String?
    var line: Int?
    var col: Int?
}
