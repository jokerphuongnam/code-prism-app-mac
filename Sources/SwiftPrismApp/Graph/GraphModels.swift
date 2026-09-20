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
    var flavor: String
    var location: FlatLocation?
    var parents: [String]?
    var calls: [String]?
    var node_context: String?
}

struct FlatLocation: Decodable {
    var absPath: String?
    var line: Int?
    var col: Int?
}
