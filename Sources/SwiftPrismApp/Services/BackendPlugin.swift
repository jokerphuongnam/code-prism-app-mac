import AppKit
import Foundation

/// Language backend plugin = CLI whose `main` writes SoT into the system cache.
struct BackendPlugin: Identifiable, Equatable {
    var id: String
    var name: String
    var binaryName: String
    var buildArtifactRelative: String
    var envOverrideKey: String

    var installedURL: URL {
        DemoPaths.backendsRoot.appendingPathComponent("\(id)/\(binaryName)")
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installedURL.path)
            || ProcessInfo.processInfo.environment[envOverrideKey] != nil
    }

    var resolvedBinary: URL? {
        if let env = ProcessInfo.processInfo.environment[envOverrideKey], !env.isEmpty {
            let u = URL(fileURLWithPath: env)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        if FileManager.default.isExecutableFile(atPath: installedURL.path) {
            return installedURL
        }
        let repoName: String = {
            switch id {
            case "js": return "js-prism"
            case "objc": return "objective-c-prism"
            default: return "\(id)-prism"
            }
        }()
        let sibling = DemoPaths.siblingBackendRepo(repoName)
            .appendingPathComponent(buildArtifactRelative)
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        if id == "swift" {
            let alts = [
                DemoPaths.siblingBackendRepo("swift-prism")
                    .appendingPathComponent("core/.build/release/swift-prism-analyzer"),
                DemoPaths.siblingBackendRepo("swift-prism")
                    .appendingPathComponent("bin/swift-prism-analyzer"),
            ]
            return alts.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return nil
    }
}

enum BackendCatalog {
    static let all: [BackendPlugin] = [
        .init(id: "swift", name: "Swift", binaryName: "swift-prism-analyzer",
              buildArtifactRelative: "core/.build/release/swift-prism-analyzer",
              envOverrideKey: "CODE_PRISM_BACKEND_SWIFT"),
        .init(id: "marlin", name: "Marlin", binaryName: "marlin-prism",
              buildArtifactRelative: "bin/marlin-prism",
              envOverrideKey: "CODE_PRISM_BACKEND_MARLIN"),
        .init(id: "kotlin", name: "Kotlin", binaryName: "kotlin-prism",
              buildArtifactRelative: "bin/kotlin-prism",
              envOverrideKey: "CODE_PRISM_BACKEND_KOTLIN"),
        .init(id: "js", name: "JS/TS", binaryName: "js-prism",
              buildArtifactRelative: "bin/js-prism",
              envOverrideKey: "CODE_PRISM_BACKEND_JS"),
        .init(id: "rust", name: "Rust", binaryName: "rust-prism",
              buildArtifactRelative: "bin/rust-prism",
              envOverrideKey: "CODE_PRISM_BACKEND_RUST"),
        .init(id: "go", name: "Go", binaryName: "go-prism",
              buildArtifactRelative: "bin/go-prism",
              envOverrideKey: "CODE_PRISM_BACKEND_GO"),
        .init(id: "cpp", name: "C/C++", binaryName: "cpp-prism",
              buildArtifactRelative: "bin/cpp-prism",
              envOverrideKey: "CODE_PRISM_BACKEND_CPP"),
        .init(id: "objc", name: "Objective-C", binaryName: "objective-c-prism",
              buildArtifactRelative: "bin/objective-c-prism",
              envOverrideKey: "CODE_PRISM_BACKEND_OBJC"),
    ]

    static func plugin(id: String) -> BackendPlugin? { all.first { $0.id == id } }
}

enum BackendError: LocalizedError {
    case analyzerNotFound(String)
    case analyzeFailed(String)
    case noSourceFiles
    case noProject

    var errorDescription: String? {
        switch self {
        case .analyzerNotFound(let id):
            return "Backend '\(id)' not found. Build that *-prism repo under code-prism/backends/."
        case .analyzeFailed(let msg):
            return "Backend failed: \(msg)"
        case .noSourceFiles:
            return "No source files matched this backend."
        case .noProject:
            return "Open a project first."
        }
    }
}

enum BackendRunner {
    static func pickProjectFolder(start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project to open (SoT goes to system cache, not into this folder)"
        panel.prompt = "Open"
        if let start { panel.directoryURL = start }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @discardableResult
    static func install(_ plugin: BackendPlugin) throws -> URL {
        guard let src = plugin.resolvedBinary else {
            throw BackendError.analyzerNotFound(plugin.id)
        }
        let fm = FileManager.default
        let dest = plugin.installedURL
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }

    /// Run backend → write SoT under ~/Library/Caches/code-prism/<lang>/<key>/.
    static func analyze(projectRoot: URL, plugin: BackendPlugin) throws -> URL {
        var bin = plugin.resolvedBinary
        if bin == nil { bin = try install(plugin) }
        guard let bin, FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw BackendError.analyzerNotFound(plugin.id)
        }

        let cacheDir = SoTCache.directory(language: plugin.id, projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let jsonOut = cacheDir.appendingPathComponent("prism-context.json")

        switch plugin.id {
        case "swift":
            try runSwiftAnalyzer(bin: bin, projectRoot: projectRoot, jsonOut: jsonOut)
        default:
            try runGenericBackend(bin: bin, projectRoot: projectRoot, jsonOut: jsonOut, lang: plugin.id)
        }

        // meta.json for MCP resolution
        let meta: [String: Any] = [
            "projectRoot": projectRoot.standardizedFileURL.path,
            "language": plugin.id,
            "projectKey": SoTCache.projectKey(for: projectRoot),
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
