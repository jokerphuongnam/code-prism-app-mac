import Foundation

/// Structural fingerprint of a graph: symbols + call/depends edges.
/// Body-only edits inside a function that do **not** add/remove calls
/// leave this fingerprint unchanged → skip cache update.
struct GraphFingerprint: Equatable, Codable {
    var symbolKeys: Set<String>
    var edgeKeys: Set<String>

    static func from(_ doc: GraphDocument) -> GraphFingerprint {
        var symbols = Set<String>()
        var edges = Set<String>()
        for n in doc.nodes {
            // id + flavor + signature shape (not body)
            symbols.insert("\(n.id)|\(n.flavor)|\(n.signature)")
            for d in n.dependencies {
                edges.insert("\(n.id)->\(d)")
            }
        }
        for l in doc.links {
            edges.insert("\(l.source)->\(l.target)|\(l.kind)")
        }
        return GraphFingerprint(symbolKeys: symbols, edgeKeys: edges)
    }

    var summary: String {
        "\(symbolKeys.count) symbols, \(edgeKeys.count) edges"
    }

    func diffDescription(against old: GraphFingerprint) -> String {
        let addedSym = symbolKeys.subtracting(old.symbolKeys).count
        let removedSym = old.symbolKeys.subtracting(symbolKeys).count
        let addedEdge = edgeKeys.subtracting(old.edgeKeys).count
        let removedEdge = old.edgeKeys.subtracting(edgeKeys).count
        return "symbols +\(addedSym)/-\(removedSym), edges +\(addedEdge)/-\(removedEdge)"
    }
}
