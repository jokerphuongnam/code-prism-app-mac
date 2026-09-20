import AppKit
import Foundation

/// Thin wrapper over a discovered plugin (catalog is never hardcoded).
typealias BackendPlugin = DiscoveredPlugin

enum BackendCatalog {
    /// Live discovery each call — install/checkouts can appear without restart.
    static var all: [BackendPlugin] { PluginDiscovery.discover() }

    static func plugin(id: String) -> BackendPlugin? {
        all.first { $0.id == id }
    }
}

enum BackendError: LocalizedError {
    case analyzerNotFound(String)
    case analyzeFailed(String)
    case noSourceFiles
    case noProject
    case noPlugins

    var errorDescription: String? {
        switch self {
        case .analyzerNotFound(let id):
            return "Backend '\(id)' binary not runnable. Build/install that plugin."
        case .analyzeFailed(let msg):
            return "Backend failed: \(msg)"
        case .noSourceFiles:
            return "No source files matched this backend."
        case .noProject:
            return "Open a project first."
        case .noPlugins:
            return "No Code Prism backends found on this machine."
        }
    }
}

enum BackendRunner {
    static func pickProjectFolder(start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project (SoT → system cache, not into this folder)"
        panel.prompt = "Open"
        if let start { panel.directoryURL = start }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @discardableResult
    static func install(_ plugin: BackendPlugin) throws -> URL {
        guard plugin.isExecutable else {
            throw BackendError.analyzerNotFound(plugin.id)
        }
        let fm = FileManager.default
        let dest = DemoPaths.backendsRoot
            .appendingPathComponent(plugin.id, isDirectory: true)
            .appendingPathComponent(plugin.bin)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copy manifest too
        let destDir = dest.deletingLastPathComponent()
        let manifestSrc = plugin.rootURL.appendingPathComponent("code-prism-plugin.json")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: plugin.binaryURL, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        if fm.fileExists(atPath: manifestSrc.path) {
            let manifestDest = destDir.appendingPathComponent("code-prism-plugin.json")
            if fm.fileExists(atPath: manifestDest.path) { try? fm.removeItem(at: manifestDest) }
            try? fm.copyItem(at: manifestSrc, to: manifestDest)
        }
        return dest
    }

    static func analyze(projectRoot: URL, plugin: BackendPlugin) throws -> URL {
        let bin = plugin.isExecutable ? plugin.binaryURL : {
            try? install(plugin)
            return DemoPaths.backendsRoot
                .appendingPathComponent(plugin.id, isDirectory: true)
                .appendingPathComponent(plugin.bin)
        }()
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw BackendError.analyzerNotFound(plugin.id)
        }

        let cacheDir = SoTCache.directory(language: plugin.id, projectRoot: projectRoot, cacheFolder: plugin.cacheFolder)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let jsonOut = cacheDir.appendingPathComponent("prism-context.json")

        if plugin.id == "swift" || plugin.extensions == ["swift"] {
            try runSwiftAnalyzer(bin: bin, projectRoot: projectRoot, jsonOut: jsonOut)
        } else {
            try runGenericBackend(bin: bin, projectRoot: projectRoot, jsonOut: jsonOut, lang: plugin.id)
        }

        let meta: [String: Any] = [
            "projectRoot": projectRoot.standardizedFileURL.path,
            "language": plugin.id,
            "cacheFolder": plugin.cacheFolder,
            "projectSlug": SoTCache.projectSlug(for: projectRoot),
            "projectKey": SoTCache.projectHash(for: projectRoot),
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "sot": [
                "json": jsonOut.path,
                "sqlite": cacheDir.appendingPathComponent("graph.sqlite").path,
            ],
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try metaData.write(to: cacheDir.appendingPathComponent("meta.json"), options: .atomic)
        _ = try? importSQLite(from: jsonOut, cacheDir: cacheDir)
        return jsonOut
    }

    private static func runSwiftAnalyzer(bin: URL, projectRoot: URL, jsonOut: URL) throws {
        let files = sourceFiles(in: projectRoot, extensions: ["swift"])
        guard !files.isEmpty else { throw BackendError.noSourceFiles }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = [
            "--workspace", projectRoot.path,
            "--scan-targets",
            "--public-only-external",
            "--context",
            "--output", jsonOut.path,
        ] + files.map(\.path)
        try run(proc)
    }

    private static func runGenericBackend(bin: URL, projectRoot: URL, jsonOut: URL, lang: String) throws {
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["--root", projectRoot.path, "--out", jsonOut.path, "--lang", lang]
        try run(proc)
    }

    private static func run(_ proc: Process) throws {
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw BackendError.analyzeFailed(err.isEmpty ? "exit \(proc.terminationStatus)" : err)
        }
    }

    private static func sourceFiles(in root: URL, extensions: [String]) -> [URL] {
        let skip = [".build", "DerivedData", "Pods", "node_modules", ".git", "Carthage", "dist", "target"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        let extSet = Set(extensions.map { $0.lowercased() })
        for case let url as URL in enumerator {
            if skip.contains(where: { url.pathComponents.contains($0) }) {
                enumerator.skipDescendants()
                continue
            }
            if extSet.contains(url.pathExtension.lowercased()) { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func importSQLite(from json: URL, cacheDir: URL) throws -> URL {
        let db = cacheDir.appendingPathComponent("graph.sqlite")
        let helper = URL(fileURLWithPath: ("~/Documents/Code/mcp-prism/dist/graph-db.js" as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: helper.path) else { return db }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["node", helper.path, "import", json.path, db.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        return db
    }
}
