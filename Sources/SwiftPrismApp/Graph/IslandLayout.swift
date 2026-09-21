import Foundation
import simd

/// Company roots often contain unrelated subprojects (mpm, libraries, projects, …),
/// and each project may itself mix languages (marlin + swift + …).
/// Layout each project×language pair as a spatial "island".
enum IslandLayout {
    struct Result {
        var positions: [String: SIMD3<Float>]
        /// nodeId → island key
        var islandOf: [String: String]
        var islandCenters: [(name: String, center: SIMD3<Float>, nodeCount: Int)]
    }

    private static let skipTopLevel: Set<String> = [
        ".git", ".build", "build", "build-embedded-xtensa", "DerivedData",
        "node_modules", ".agents", ".claude", ".codex", ".grok", ".vscode",
        ".swiftpm", "Pods", "Carthage", "dist", "target", "vendor",
        "__pycache__", ".next", "xcuserdata",
    ]

    private static let extToLang: [String: String] = [
        "swift": "swift", "m": "objc", "mm": "objc",
        "h": "cpp", "hpp": "cpp", "c": "cpp", "cc": "cpp", "cpp": "cpp", "cxx": "cpp",
        "kt": "kotlin", "kts": "kotlin", "java": "kotlin",
        "rs": "rust", "go": "go",
        "js": "js", "jsx": "js", "ts": "js", "tsx": "js",
        "marlin": "marlin", "marlinheader": "marlin",
    ]

    /// Project slice only, e.g. `mpm`, `libraries`, `projects/desk-garden`.
    static func projectKey(filePath: String, projectRoot: String) -> String {
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
        if first == "projects", parts.count >= 2 {
            return "projects/\(parts[1])"
        }
        return first
    }

    static func languageKey(for node: GraphNode) -> String {
        if !node.language.isEmpty { return node.language }
        // Merged multi-lang ids: `swift::Foo.bar`
        if let range = node.id.range(of: "::") {
            let prefix = String(node.id[..<range.lowerBound])
            if !prefix.isEmpty, !prefix.contains("/") { return prefix }
        }
        // Name tagged `[swift] Foo`
        if node.name.hasPrefix("["), let end = node.name.firstIndex(of: "]") {
            let tag = String(node.name[node.name.index(after: node.name.startIndex)..<end])
            if !tag.isEmpty { return tag }
        }
        let ext = (node.filePath as NSString).pathExtension.lowercased()
        if let lang = extToLang[ext] { return lang }
        return ""
    }

    /// Back-compat helper used by sidebar before language-aware keys.
    static func islandKey(filePath: String, projectRoot: String) -> String {
        projectKey(filePath: filePath, projectRoot: projectRoot)
    }

    /// Full island id: project, or `project · lang` when the graph has multiple languages.
    static func islandKey(for node: GraphNode, projectRoot: String, multiLang: Bool) -> String {
        if node.filePath.isEmpty && node.language.isEmpty {
            return "external"
        }
        let project: String
        if node.filePath.isEmpty {
            project = "external"
        } else {
            project = projectKey(filePath: node.filePath, projectRoot: projectRoot)
        }
        guard multiLang else { return project }
        let lang = languageKey(for: node)
        if lang.isEmpty { return project }
        if project == "external" { return "external · \(lang)" }
        return "\(project) · \(lang)"
    }

    static func layout(
        nodes: [GraphNode],
        links: [GraphLink],
        projectRoot: String,
        warmSteps: Int,
        settleSteps: Int
    ) -> Result {
        let langs = Set(nodes.map { languageKey(for: $0) }.filter { !$0.isEmpty })
        let multiLang = langs.count > 1

        var islandOf: [String: String] = [:]
        var buckets: [String: [String]] = [:]

        for n in nodes {
            let key = islandKey(for: n, projectRoot: projectRoot, multiLang: multiLang)
            islandOf[n.id] = key
            buckets[key, default: []].append(n.id)
        }

        let ordered = buckets.keys.sorted { a, b in
            if a.hasPrefix("external") { return false }
            if b.hasPrefix("external") { return true }
            if a == "_noise" || a.hasPrefix("_noise") { return false }
            if b == "_noise" || b.hasPrefix("_noise") { return true }
            return (buckets[a]?.count ?? 0) > (buckets[b]?.count ?? 0)
        }

        let maxIsland = ordered.map { buckets[$0]?.count ?? 0 }.max() ?? 1
        // More islands (project × lang) → larger ring so they stay readable.
        let ringR = 30 + Float(maxIsland) * 0.45 + Float(ordered.count) * 6

        var positions: [String: SIMD3<Float>] = [:]
        var centers: [(name: String, center: SIMD3<Float>, nodeCount: Int)] = []
        let idSet = Set(nodes.map(\.id))

        // Group islands that share a project so sibling languages sit as a small cluster.
        let projectGroups: [String: [String]] = {
            var g: [String: [String]] = [:]
            for name in ordered {
                let project = name.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
                g[project, default: []].append(name)
            }
            return g
        }()
        let projectOrder = ordered.map {
            $0.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? $0
        }
        var uniqueProjects: [String] = []
        for p in projectOrder where !uniqueProjects.contains(p) {
            uniqueProjects.append(p)
        }

        var islandIndex = 0
        for (pi, project) in uniqueProjects.enumerated() {
            let siblings = projectGroups[project] ?? [project]
            let projectAngle = Float(pi) / Float(max(uniqueProjects.count, 1)) * (.pi * 2)
            let projectCenter = SIMD3(cos(projectAngle) * ringR, 0, sin(projectAngle) * ringR)

            for (si, name) in siblings.enumerated() {
                let ids = buckets[name] ?? []
                guard !ids.isEmpty else { continue }
                // Sibling languages offset around the project center.
                let localR: Float = siblings.count > 1 ? 10 + Float(ids.count) * 0.08 : 0
                let localAngle = Float(si) / Float(max(siblings.count, 1)) * (.pi * 2)
                let y: Float = name.contains("external") || name.contains("_noise") ? -8 : Float(si) * 0.4
                let center = projectCenter + SIMD3(cos(localAngle) * localR, y, sin(localAngle) * localR)

                let localLinks: [(String, String)] = links.compactMap { link in
                    guard idSet.contains(link.source), idSet.contains(link.target) else { return nil }
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
                if !name.contains("_noise") {
                    centers.append((name: name, center: center, nodeCount: ids.count))
                }
                islandIndex += 1
            }
        }

        return Result(positions: positions, islandOf: islandOf, islandCenters: centers)
    }
}
