import Foundation
import simd

/// Company roots often contain unrelated subprojects (mpm, libraries, projects, …).
/// Layout each as a spatial "island" so the graph isn't one tangled cloud.
enum IslandLayout {
    struct Result {
        var positions: [String: SIMD3<Float>]
        /// nodeId → island key (top-level folder or `external` / `root`)
        var islandOf: [String: String]
        var islandCenters: [(name: String, center: SIMD3<Float>, nodeCount: Int)]
    }

    private static let skipTopLevel: Set<String> = [
        ".git", ".build", "build", "build-embedded-xtensa", "DerivedData",
        "node_modules", ".agents", ".claude", ".codex", ".grok", ".vscode",
        ".swiftpm", "Pods", "Carthage", "dist", "target", "vendor",
        "__pycache__", ".next", "xcuserdata",
    ]

    /// Top-level folder under `projectRoot`, e.g. `mpm`, `libraries`, `projects`.
    static func islandKey(filePath: String, projectRoot: String) -> String {
        let path = (filePath as NSString).standardizingPath
        let root = (projectRoot as NSString).standardizingPath
        var rel = path
        if path.hasPrefix(root) {
            rel = String(path.dropFirst(root.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        }
        guard !rel.isEmpty else { return "root" }
        let parts = rel.split(separator: "/").map(String.init)
        guard let first = parts.first, !first.isEmpty else { return "root" }
        if skipTopLevel.contains(first) { return "_noise" }
        // Nested app projects: projects/desk-garden → island "projects/desk-garden"
        if first == "projects", parts.count >= 2 {
            return "projects/\(parts[1])"
        }
        return first
    }

    static func layout(
        nodes: [GraphNode],
        links: [GraphLink],
        projectRoot: String,
        warmSteps: Int,
        settleSteps: Int
    ) -> Result {
        var islandOf: [String: String] = [:]
        var buckets: [String: [String]] = [:]

        for n in nodes {
            let key: String
            if n.filePath.isEmpty {
                key = "external"
            } else {
                key = islandKey(filePath: n.filePath, projectRoot: projectRoot)
            }
            islandOf[n.id] = key
            buckets[key, default: []].append(n.id)
        }

        // Drop empty noise island from layout ring (nodes still get a far park if any).
        let ordered = buckets.keys.sorted { a, b in
            if a == "external" { return false }
            if b == "external" { return true }
            if a == "_noise" { return false }
            if b == "_noise" { return true }
            return (buckets[a]?.count ?? 0) > (buckets[b]?.count ?? 0)
        }

        let maxIsland = ordered.map { buckets[$0]?.count ?? 0 }.max() ?? 1
        let ringR = 28 + Float(maxIsland) * 0.4 + Float(ordered.count) * 5

        var positions: [String: SIMD3<Float>] = [:]
        var centers: [(name: String, center: SIMD3<Float>, nodeCount: Int)] = []
        let idSet = Set(nodes.map(\.id))

        for (i, name) in ordered.enumerated() {
            let ids = buckets[name] ?? []
            guard !ids.isEmpty else { continue }
            let angle = Float(i) / Float(max(ordered.count, 1)) * (.pi * 2)
            let y: Float = name == "external" || name == "_noise" ? -8 : 0
            let center = SIMD3(cos(angle) * ringR, y, sin(angle) * ringR)

            let localLinks: [(String, String)] = links.compactMap { link in
                guard idSet.contains(link.source), idSet.contains(link.target) else { return nil }
                // Springs only inside the island — islands stay unrelated.
                guard islandOf[link.source] == name, islandOf[link.target] == name else { return nil }
                return (link.source, link.target)
            }

            let force = ForceLayout3D(nodeIds: ids, links: localLinks)
            let n = ids.count
            force.linkDistance = n > 80 ? 4.2 : 5.2
            force.charge = n > 120 ? -12 : -36
            force.centerStrength = 0.04
            for _ in 0..<warmSteps {
                _ = force.tick(1)
            }
            for _ in 0..<settleSteps {
                _ = force.tick(n > 100 ? 1 : 2)
            }
            for id in ids {
                positions[id] = (force.positions[id] ?? .zero) + center
            }
            if name != "_noise" {
                centers.append((name: name, center: center, nodeCount: ids.count))
            }
        }

        return Result(positions: positions, islandOf: islandOf, islandCenters: centers)
    }
}
