import Foundation

enum GraphLoader {
    /// Load SoT from system cache for this project (never requires in-tree .codeprism).
    static func load(projectRoot: URL, language: String? = nil) throws -> GraphDocument {
        guard let sot = SoTCache.resolveJSON(projectRoot: projectRoot, preferred: language) else {
            throw LoadError.missingSoT(
                SoTCache.directory(language: language ?? "swift", projectRoot: projectRoot)
            )
        }
        let data = try Data(contentsOf: sot)
        return try decode(data: data, projectRoot: projectRoot.path)
    }

    /// Merge SoT for multiple languages of the same project (prefix node ids with `lang:` to avoid clashes).
    static func loadMerged(projectRoot: URL, languages: [String]) throws -> GraphDocument {
        var merged = GraphDocument(
            projectRoot: projectRoot.path,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            nodes: [],
            links: []
        )
        var loadedAny = false
        var lastError: Error?
        for lang in languages {
            do {
                let doc = try load(projectRoot: projectRoot, language: lang)
                loadedAny = true
                let prefix = languages.count > 1 ? "\(lang)::" : ""
                for n in doc.nodes {
                    var nn = n
                    nn.id = prefix + n.id
                    nn.dependencies = n.dependencies.map { prefix + $0 }
                    nn.language = lang
                    if languages.count > 1 {
                        nn.name = "[\(lang)] \(n.name)"
                    }
                    merged.nodes.append(nn)
                }
                for l in doc.links {
                    merged.links.append(
                        GraphLink(
                            source: prefix + l.source,
                            target: prefix + l.target,
                            kind: l.kind
                        )
                    )
                }
            } catch {
                lastError = error
            }
        }
        if !loadedAny {
            throw lastError ?? LoadError.missingSoT(
                SoTCache.directory(language: languages.first ?? "swift", projectRoot: projectRoot)
            )
        }
        return merged
    }

    static func decode(data: Data, projectRoot: String) throws -> GraphDocument {
        // Try flat nodes schema first (MCP / schema 4).
        if let flat = try? JSONDecoder().decode(FlatGraphDocument.self, from: data),
           let nodes = flat.nodes, !nodes.isEmpty {
            return fromFlat(nodes, projectRoot: flat.projectRoot ?? projectRoot, generatedAt: flat.generatedAt ?? "")
        }

        // Context v2 (LiteTrace / --context output).
        if let v2 = try? JSONDecoder().decode(ContextV2Document.self, from: data),
           let files = v2.files {
            return fromContextV2(v2, files: files, projectRoot: projectRoot)
        }

        throw LoadError.unsupportedSchema
    }

    private static func fromFlat(_ nodes: [FlatGraphNode], projectRoot: String, generatedAt: String) -> GraphDocument {
        var outNodes: [GraphNode] = []
        var links: [GraphLink] = []
        for n in nodes {
            outNodes.append(
                GraphNode(
                    id: n.id,
                    name: n.name,
                    flavor: n.flavor,
                    filePath: n.location?.absPath ?? "",
                    line: n.location?.line ?? 0,
                    signature: n.node_context ?? n.name,
                    dependencies: n.calls ?? []
                )
            )
            for c in n.calls ?? [] {
                links.append(GraphLink(source: n.id, target: c, kind: "call"))
            }
        }
        return GraphDocument(projectRoot: projectRoot, generatedAt: generatedAt, nodes: outNodes, links: links)
    }

    private static func fromContextV2(
        _ doc: ContextV2Document,
        files: [ContextV2File],
        projectRoot: String
    ) -> GraphDocument {
        var nodes: [GraphNode] = []
        var seen = Set<String>()

        for file in files {
            for sig in file.signatures {
                if seen.contains(sig.id) { continue }
                seen.insert(sig.id)
                let flavor = inferFlavor(signature: sig.signature ?? "", id: sig.id)
                nodes.append(
                    GraphNode(
                        id: sig.id,
                        name: sig.id.split(separator: ".").last.map(String.init) ?? sig.id,
                        flavor: flavor,
                        filePath: file.path,
                        line: sig.line ?? 0,
                        signature: sig.signature ?? sig.id,
                        dependencies: sig.dependencies ?? []
                    )
                )
            }
        }

        // dependencyIndex: key is dependency, values are users → edge user → dependency
        var links: [GraphLink] = []
        var linkSeen = Set<String>()
        if let index = doc.dependencyIndex {
            for (dep, users) in index {
                for user in users {
                    let key = "\(user)->\(dep)"
                    if linkSeen.contains(key) { continue }
                    linkSeen.insert(key)
                    // Ensure endpoints exist as nodes (external / unresolved names)
                    if !seen.contains(dep) {
                        seen.insert(dep)
                        nodes.append(
                            GraphNode(
                                id: dep,
                                name: dep,
                                flavor: "external",
                                filePath: "",
                                line: 0,
                                signature: dep,
                                dependencies: []
                            )
                        )
                    }
                    if !seen.contains(user) {
                        seen.insert(user)
                        nodes.append(
                            GraphNode(
                                id: user,
                                name: user,
                                flavor: "external",
                                filePath: "",
                                line: 0,
                                signature: user,
                                dependencies: []
                            )
                        )
                    }
                    links.append(GraphLink(source: user, target: dep, kind: "depends"))
                }
            }
        }

        // Also add signature.dependencies edges
        for n in nodes {
            for d in n.dependencies {
                let key = "\(n.id)->\(d)"
                if linkSeen.contains(key) { continue }
                linkSeen.insert(key)
                links.append(GraphLink(source: n.id, target: d, kind: "depends"))
            }
        }

        return GraphDocument(
            projectRoot: projectRoot,
            generatedAt: doc.generatedAt ?? "",
            nodes: nodes,
            links: links
        )
    }

    private static func inferFlavor(signature: String, id: String) -> String {
        let s = signature
        if s.contains("struct ") { return "struct" }
        if s.contains("class ") { return "class" }
        if s.contains("enum ") { return "enum" }
        if s.contains("protocol ") { return "protocol" }
        if s.contains("actor ") { return "actor" }
        if s.contains("func ") || s.contains("init(") { return "function" }
        if s.contains("var ") || s.contains("let ") { return "variable" }
        if id.contains(".") { return "member" }
        return "type"
    }

    enum LoadError: LocalizedError {
        case missingSoT(URL)
        case unsupportedSchema

        var errorDescription: String? {
            switch self {
            case .missingSoT(let url):
                return "No SoT in cache (\(url.path)). Install/run a backend (Analyze) first — data goes to ~/Library/Caches/code-prism/, not into your project."
            case .unsupportedSchema:
                return "Unrecognized prism-context.json schema."
            }
        }
    }
}
