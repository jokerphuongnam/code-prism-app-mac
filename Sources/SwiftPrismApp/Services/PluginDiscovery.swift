import Foundation

/// Discovered language backend plugin (from disk, not hardcoded).
struct DiscoveredPlugin: Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var bin: String
    var extensions: [String]
    var markers: [String]
    var cacheFolder: String
    var version: String
    /// Directory that contains the binary / manifest.
    var rootURL: URL
    var binaryURL: URL

    var isExecutable: Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }

    /// Can participate in detect/build — must declare extensions and/or markers in the plugin manifest.
    /// A random `*-prism` folder with an empty heuristic stub does not claim languages.
    var canDetectLanguage: Bool {
        !extensions.isEmpty || !markers.isEmpty
    }
}

enum PluginDiscovery {
    private struct Manifest: Decodable {
        var id: String
        var name: String
        var bin: String
        var extensions: [String]
        var markers: [String]?
        var cacheFolder: String?
        var version: String?
    }

    /// Scan Application Support + monorepo `code-prism/backends/<id>/` (+ legacy `*-prism`).
    static func discover() -> [DiscoveredPlugin] {
        var byId: [String: DiscoveredPlugin] = [:]
        let fm = FileManager.default

        // 1) Installed plugins
        let installedRoot = DemoPaths.backendsRoot
        if let ids = try? fm.contentsOfDirectory(atPath: installedRoot.path) {
            for id in ids {
                let dir = installedRoot.appendingPathComponent(id, isDirectory: true)
                if let plugin = loadPlugin(from: dir, preferBinName: nil) {
                    byId[plugin.id] = plugin
                }
            }
        }

        // 2) Monorepo backends (`backends/js`, `backends/marlin`, …) + legacy `*-prism`
        let backendsRoot = DemoPaths.backendsCheckoutRoot
        if let repos = try? fm.contentsOfDirectory(atPath: backendsRoot.path) {
            for repo in repos {
                if repo.hasPrefix(".") { continue }
                let dir = backendsRoot.appendingPathComponent(repo, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                if let plugin = loadPlugin(from: dir, preferBinName: nil) {
                    if plugin.isExecutable || byId[plugin.id] == nil {
                        byId[plugin.id] = plugin
                    }
                }
            }
        }

        // Env overrides: CODE_PRISM_BACKEND_<ID>=/path/to/bin
        for (key, value) in ProcessInfo.processInfo.environment {
            guard key.hasPrefix("CODE_PRISM_BACKEND_"), !value.isEmpty else { continue }
            let id = String(key.dropFirst("CODE_PRISM_BACKEND_".count)).lowercased()
            let binURL = URL(fileURLWithPath: value)
            guard fm.isExecutableFile(atPath: binURL.path) else { continue }
            if var existing = byId[id] {
                existing.binaryURL = binURL
                byId[id] = existing
            } else {
                byId[id] = DiscoveredPlugin(
                    id: id,
                    name: id,
                    bin: binURL.lastPathComponent,
                    extensions: [],
                    markers: [],
                    cacheFolder: id == "objc" ? "objective-c-prism" : "\(id)-prism",
                    version: "env",
                    rootURL: binURL.deletingLastPathComponent(),
                    binaryURL: binURL
                )
            }
        }

        return byId.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func loadPlugin(from dir: URL, preferBinName: String?) -> DiscoveredPlugin? {
        let fm = FileManager.default
        let manifestURL = dir.appendingPathComponent("code-prism-plugin.json")
        guard fm.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            // Heuristic: folder named foo-prism with bin/foo-prism
            let repo = dir.lastPathComponent
            guard repo.hasSuffix("-prism") else { return nil }
            let id: String = {
                if repo == "objective-c-prism" { return "objc" }
                return String(repo.dropLast("-prism".count))
            }()
            let binName = preferBinName ?? (repo == "objective-c-prism" ? "objective-c-prism" : (id == "swift" ? "swift-prism-analyzer" : "\(id)-prism"))
            let candidates = [
                dir.appendingPathComponent("bin/\(binName)"),
                dir.appendingPathComponent("core/.build/release/\(binName)"),
            ]
            guard let bin = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
                return nil
            }
            return DiscoveredPlugin(
                id: id,
                name: id,
                bin: binName,
                extensions: [],
                markers: [],
                cacheFolder: repo,
                version: "0",
                rootURL: dir,
                binaryURL: bin
            )
        }

        let cacheFolder = manifest.cacheFolder
            ?? (manifest.id == "objc" ? "objective-c-prism" : "\(manifest.id)-prism")
        let binName = preferBinName ?? manifest.bin
        let candidates = [
            dir.appendingPathComponent("bin/\(binName)"),
            dir.appendingPathComponent(binName),
            dir.appendingPathComponent("core/.build/release/\(binName)"),
            DemoPaths.backendsRoot.appendingPathComponent("\(manifest.id)/\(binName)"),
        ]
        let bin = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) })
            ?? dir.appendingPathComponent("bin/\(binName)")

        return DiscoveredPlugin(
            id: manifest.id,
            name: manifest.name,
            bin: binName,
            extensions: manifest.extensions.map { $0.lowercased() },
            markers: manifest.markers ?? [],
            cacheFolder: cacheFolder,
            version: manifest.version ?? "0",
            rootURL: dir,
            binaryURL: bin
        )
    }
}
