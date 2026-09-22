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
    }

    /// Where a source file sits: large island, archipelago, and file island.
    static func scope(filePath: String, projectRoot: String) -> Scope {
        let nodes = nodes(projectRoot: projectRoot)
        let path = (filePath as NSString).standardizingPath
        let leaf = nodes
            .filter { !$0.path.isEmpty && (path == $0.path || path.hasPrefix($0.path + "/")) }
            .max { a, b in
                if a.path.count != b.path.count { return a.path.count < b.path.count }
                return a.flavor != "xcode" && b.flavor == "xcode"
            }
        let file = (path as NSString).lastPathComponent
        guard let leaf else {
            return Scope(region: IslandLayout.projectKey(filePath: filePath, projectRoot: projectRoot), archipelago: "root", file: file)
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
        return Scope(region: region, archipelago: arch, file: file.isEmpty ? leaf.name : file)
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
