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
        var scopeOf: [String: ProjectAtlas.Scope] = [:]
        var islandCenters: [(name: String, center: SIMD3<Float>, nodeCount: Int)]
    }

    private static let skipTopLevel: Set<String> = [
        ".git", ".build", "build", "build-embedded-xtensa", "DerivedData",
        "node_modules", ".agents", ".claude", ".codex", ".grok", ".vscode",
        ".swiftpm", "Pods", "Carthage", "dist", "target", "vendor",
        "__pycache__", ".next", "xcuserdata",
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

    /// Language only from SoT / merge prefix — never invent langs from file extensions
    /// (extensions without a plugin must not become islands or nodes).
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
        var scopeOf: [String: ProjectAtlas.Scope] = [:]
        var buckets: [String: [String]] = [:]

        let useAtlas = !ProjectAtlas.nodes(projectRoot: projectRoot).isEmpty
        for n in nodes {
            if !n.group.isEmpty {
                islandOf[n.id] = n.group
                buckets[n.group, default: []].append(n.id)
            } else if useAtlas, !n.filePath.isEmpty {
                let scope = ProjectAtlas.scope(
                    filePath: n.filePath,
                    projectRoot: projectRoot,
                    language: languageKey(for: n)
                )
                scopeOf[n.id] = scope
                // Loose / integration files: one pile per language (not per-file islands).
                let key: String
                if scope.isLoose {
                    key = "ungrouped · \(scope.archipelago)"
                } else {
                    key = "\(scope.region) / \(scope.archipelago) / \(scope.file)"
                }
                islandOf[n.id] = key
                buckets[key, default: []].append(n.id)
            } else {
                let key = islandKey(for: n, projectRoot: projectRoot, multiLang: multiLang)
                islandOf[n.id] = key
                buckets[key, default: []].append(n.id)
            }
        }

        let ordered = buckets.keys.sorted { a, b in
            // Park ungrouped language piles after real projects.
            let aLoose = a.hasPrefix("ungrouped")
            let bLoose = b.hasPrefix("ungrouped")
            if aLoose != bLoose { return !aLoose && bLoose }
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

        func splitKey(_ key: String) -> (region: String, arch: String) {
            let bits = key.components(separatedBy: " / ")
            if bits.count >= 2 { return (bits[0], bits[1]) }
            let project = key.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? key
            return (project, key)
        }
        // Large island → archipelago → file island.
        var regionOrder: [String] = []
        var archByRegion: [String: [String]] = [:]
        var filesByArch: [String: [String]] = [:]
        for name in ordered {
            let parts = splitKey(name)
            if !regionOrder.contains(parts.region) { regionOrder.append(parts.region) }
            let archKey = parts.region + "\u{1f}" + parts.arch
            if archByRegion[parts.region]?.contains(archKey) != true {
                archByRegion[parts.region, default: []].append(archKey)
            }
            filesByArch[archKey, default: []].append(name)
        }

        var islandIndex = 0
        for (pi, region) in regionOrder.enumerated() {
            let archKeys = archByRegion[region] ?? []
            let projectAngle = Float(pi) / Float(max(regionOrder.count, 1)) * (.pi * 2)
            let projectCenter = SIMD3(cos(projectAngle) * ringR, 0, sin(projectAngle) * ringR)
            let archR: Float = archKeys.count > 1 ? 16 + Float(archKeys.count) * 3 : 0

            for (ai, archKey) in archKeys.enumerated() {
                let fileKeys = filesByArch[archKey] ?? []
                let archAngle = Float(ai) / Float(max(archKeys.count, 1)) * (.pi * 2)
                let archCenter = projectCenter + SIMD3(cos(archAngle) * archR, Float(ai) * 0.15, sin(archAngle) * archR)
                let fileR: Float = fileKeys.count > 1 ? 6 + Float(fileKeys.count) * 0.35 : 0

            for (si, name) in fileKeys.enumerated() {
                let ids = buckets[name] ?? []
                guard !ids.isEmpty else { continue }
                let isLoosePile = name.hasPrefix("ungrouped")
                let localAngle = Float(si) / Float(max(fileKeys.count, 1)) * (.pi * 2)
                let y: Float =
                    isLoosePile ? -14
                    : (name.contains("external") || name.contains("_noise") ? -8 : 0)
                // Park loose language piles on a wider ring so they don't tangle projects.
                let looseBoost: Float = isLoosePile ? ringR * 0.35 : 0
                let center =
                    archCenter
                    + SIMD3(cos(localAngle) * (fileR + looseBoost), y, sin(localAngle) * (fileR + looseBoost))

                // Loose piles: keep nodes, but do not wire springs (no edges "đi đâu").
                let localLinks: [(String, String)] = isLoosePile
                    ? []
                    : links.compactMap { link in
                        guard idSet.contains(link.source), idSet.contains(link.target) else { return nil }
                        guard islandOf[link.source] == name, islandOf[link.target] == name else {
                            return nil
                        }
                        return (link.source, link.target)
                    }

                let force = ForceLayout3D(nodeIds: ids, links: localLinks)
                let n = ids.count
                force.linkDistance = n > 80 ? 4.2 : 5.2
                force.charge = isLoosePile ? (n > 80 ? -6 : -18) : (n > 120 ? -12 : -36)
                force.centerStrength = isLoosePile ? 0.08 : 0.04
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
        }

        return Result(positions: positions, islandOf: islandOf, scopeOf: scopeOf, islandCenters: centers)
    }
}
