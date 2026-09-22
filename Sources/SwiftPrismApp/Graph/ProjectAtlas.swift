import Foundation

/// Project tree from `prism projects` (Cargo, Xcode, SPM, npm, …).
enum ProjectAtlas {
    struct Node {
        var id: String
        var name: String
        var flavor: String
        var path: String
        var parents: [String]
        var targets: [String]
    }

    private static var cacheRoot = ""
    private static var cache: [Node] = []

    static func nodes(projectRoot: String) -> [Node] {
        if cacheRoot == projectRoot { return cache }
        cacheRoot = projectRoot
        cache = load(projectRoot)
        return cache
    }

    private static func load(_ root: String) -> [Node] {
        let home = NSHomeDirectory() + "/bin/prism"
        let prism = FileManager.default.isExecutableFile(atPath: home) ? home : "prism"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [prism, "projects", "--root", root]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            return raw.nodes.map {
                Node(
                    id: $0.id,
                    name: $0.name,
                    flavor: $0.flavor,
                    path: $0.location?.absPath ?? "",
                    parents: $0.parents ?? [],
                    targets: $0.targets ?? []
                )
            }
        } catch {
            return []
        }
    }

    struct Scope {
        var region: String
        var archipelago: String
        var file: String
        /// Loose / integration / unscoped sources — kept, piled by language, not wired into projects.
        var isLoose: Bool
    }

    private static let loosePathSegments: Set<String> = [
        "integration", "integrations", "examples", "example", "samples", "sample",
        "fixtures", "testdata", "playgrounds", "playground", "snippets",
    ]

    /// Where a source file sits: large island, archipelago, and file island.
    static func scope(filePath: String, projectRoot: String, language: String = "") -> Scope {
        let nodes = nodes(projectRoot: projectRoot)
        let path = (filePath as NSString).standardizingPath
        let file = (path as NSString).lastPathComponent
        let lang = language.isEmpty ? languageFromPath(path) : language

        if isLoosePath(path) {
            return looseScope(file: file, language: lang)
        }

        let leaf = nodes
            .filter { !$0.path.isEmpty && (path == $0.path || path.hasPrefix($0.path + "/")) }
            .max { a, b in
                if a.path.count != b.path.count { return a.path.count < b.path.count }
                return a.flavor != "xcode" && b.flavor == "xcode"
            }
        guard let leaf else {
            // No Cargo/Xcode/SPM/… owner → language pile, not a fake "root" island.
            return looseScope(file: file, language: lang)
        }

        // Matched only a broad folder group (not a real package/app) → also loose.
        if leaf.flavor == "group" {
            let tighter = nodes.contains {
                $0.flavor != "group"
                    && !$0.path.isEmpty
                    && (path == $0.path || path.hasPrefix($0.path + "/"))
            }
            if !tighter {
                return looseScope(file: file, language: lang)
            }
        }

        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var regionNode = leaf
        var guardrail = 0
        while guardrail < 12, let parent = regionNode.parents.first, let next = byId[parent] {
            if next.flavor == "group" { regionNode = next; break }
            if next.flavor == "xcode" { regionNode = next; break }
            regionNode = next
            guardrail += 1
        }
        let xcodeName: (String) -> String = { $0.replacingOccurrences(of: ".xcodeproj", with: "").replacingOccurrences(of: ".xcworkspace", with: "") }
        let hostApp = nodes.first { $0.flavor == "xcode" && (leaf.path == $0.path || leaf.path.hasPrefix($0.path + "/")) }
        let region: String
        if let hostApp {
            region = xcodeName(hostApp.name)
        } else if regionNode.flavor == "group" {
            region = regionNode.name
        } else {
            region = leaf.name
        }
        var arch = leaf.name
        if leaf.flavor == "xcode" || hostApp?.id == leaf.id {
            let parts = Set(path.split(separator: "/").map(String.init))
            let owner = leaf.flavor == "xcode" ? leaf : hostApp
            if let target = owner?.targets.first(where: { parts.contains($0) }) {
                arch = "\(owner?.name ?? leaf.name)/\(target)"
            }
        }
        return Scope(
            region: region,
            archipelago: arch,
            file: file.isEmpty ? leaf.name : file,
            isLoose: false
        )
    }

    private static func looseScope(file: String, language: String) -> Scope {
        let lang = language.isEmpty ? "unknown" : language
        return Scope(
            region: "ungrouped",
            archipelago: lang,
            file: file.isEmpty ? lang : file,
            isLoose: true
        )
    }

    private static func isLoosePath(_ path: String) -> Bool {
        let parts = Set(path.split(separator: "/").map { $0.lowercased() })
        return !parts.isDisjoint(with: loosePathSegments)
    }

    /// Only extensions claimed by an installed plugin.
    static func languageFromPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return "" }
        for plugin in PluginDiscovery.discover() where plugin.canDetectLanguage {
            if plugin.extensions.contains(ext) { return plugin.id }
        }
        return ""
    }
}

private struct Raw: Decodable {
    var nodes: [RawNode]
}

private struct RawNode: Decodable {
    var id: String
    var name: String
    var flavor: String
    var location: RawLoc?
    var parents: [String]?
    var targets: [String]?
}

private struct RawLoc: Decodable {
    var absPath: String?
}
