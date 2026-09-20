import AppKit
import Foundation

/// Language backend plugin = CLI whose `main` writes SoT under `.codeprism/`.
struct BackendPlugin: Identifiable, Equatable {
    var id: String
    var name: String
    var binaryName: String
    /// Relative path inside a sibling `*-prism` repo after build.
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
        let sibling = DemoPaths.siblingBackendRepo(id == "swift" ? "swift-prism" : "\(id)-prism")
            .appendingPathComponent(buildArtifactRelative)
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        // swift special-case paths
        if id == "swift" {
            let alts = [
                DemoPaths.siblingBackendRepo("swift-prism").appendingPathComponent("extension/bin/swift-prism-analyzer"),
                DemoPaths.siblingBackendRepo("swift-prism").appendingPathComponent("core/.build/release/swift-prism-analyzer"),
            ]
            return alts.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return nil
    }
}

enum BackendCatalog {
    static let all: [BackendPlugin] = [
        BackendPlugin(
            id: "swift",
            name: "Swift",
            binaryName: "swift-prism-analyzer",
            buildArtifactRelative: "core/.build/release/swift-prism-analyzer",
            envOverrideKey: "CODE_PRISM_BACKEND_SWIFT"
        ),
        BackendPlugin(
            id: "marlin",
            name: "Marlin",
            binaryName: "marlin-prism",
            buildArtifactRelative: "bin/marlin-prism",
            envOverrideKey: "CODE_PRISM_BACKEND_MARLIN"
        ),
        BackendPlugin(
            id: "kotlin",
            name: "Kotlin",
            binaryName: "kotlin-prism",
            buildArtifactRelative: "bin/kotlin-prism",
            envOverrideKey: "CODE_PRISM_BACKEND_KOTLIN"
        ),
        BackendPlugin(
            id: "js",
            name: "JS/TS",
            binaryName: "js-prism",
            buildArtifactRelative: "bin/js-prism",
            envOverrideKey: "CODE_PRISM_BACKEND_JS"
        ),
    ]

    static func plugin(id: String) -> BackendPlugin? {
        all.first { $0.id == id }
    }
}

enum BackendError: LocalizedError {
    case analyzerNotFound(String)
    case analyzeFailed(String)
    case noSourceFiles
    case noProject

    var errorDescription: String? {
        switch self {
        case .analyzerNotFound(let id):
            return "Backend '\(id)' not found. Build/install that *-prism repo first."
        case .analyzeFailed(let msg):
            return "Backend failed: \(msg)"
        case .noSourceFiles:
            return "No source files matched this backend."
        case .noProject:
            return "Open a project first."
        }
    }
}

enum SoTPaths {
    static let dirNamePreferred = ".codeprism"
    static let dirNameLegacy = ".swiftprism"
    static let jsonName = "prism-context.json"
    static let sqliteName = "graph.sqlite"
    static let configName = "codeprism-config.json"

    static func sotDir(for project: URL) -> URL {
        let preferred = project.appendingPathComponent(dirNamePreferred, isDirectory: true)
        let legacy = project.appendingPathComponent(dirNameLegacy, isDirectory: true)
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        if FileManager.default.fileExists(atPath: legacy.appendingPathComponent(jsonName).path) {
            return legacy
        }
        return preferred
    }

    static func jsonURL(for project: URL) -> URL {
        sotDir(for: project).appendingPathComponent(jsonName)
    }
}

enum BackendRunner {
    static func pickProjectFolder(start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project to open"
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

    /// Run backend main → write SoT under `.codeprism/`.
    static func analyze(projectRoot: URL, plugin: BackendPlugin) throws -> URL {
        let bin = plugin.resolvedBinary ?? {
            try? install(plugin)
            return plugin.installedURL
        }()
        guard let bin, FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw BackendError.analyzerNotFound(plugin.id)
        }

        let sotDir = projectRoot.appendingPathComponent(SoTPaths.dirNamePreferred, isDirectory: true)
        try FileManager.default.createDirectory(at: sotDir, withIntermediateDirectories: true)
        let gitignore = sotDir.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: gitignore.path) {
            try "*\n".write(to: gitignore, atomically: true, encoding: .utf8)
        }
        let jsonOut = sotDir.appendingPathComponent(SoTPaths.jsonName)

        switch plugin.id {
        case "swift":
            try runSwiftAnalyzer(bin: bin, projectRoot: projectRoot, jsonOut: jsonOut)
        default:
            // Generic CLI: <bin> --root <project> --out <json>
            try runGenericBackend(bin: bin, projectRoot: projectRoot, jsonOut: jsonOut)
        }

        _ = try? importSQLite(from: jsonOut, sotDir: sotDir)

        let cfg: [String: String] = [
            "graphPath": jsonOut.path,
            "sqlitePath": sotDir.appendingPathComponent(SoTPaths.sqliteName).path,
            "projectRoot": projectRoot.path,
            "backend": plugin.id,
        ]
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: sotDir.appendingPathComponent(SoTPaths.configName), options: .atomic)
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

    private static func runGenericBackend(bin: URL, projectRoot: URL, jsonOut: URL) throws {
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["--root", projectRoot.path, "--out", jsonOut.path]
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
        let skip = [".build", "DerivedData", "Pods", "node_modules", ".git", ".codeprism", ".swiftprism", "Carthage", "dist"]
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
            if extSet.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func importSQLite(from json: URL, sotDir: URL) throws -> URL {
        let db = sotDir.appendingPathComponent(SoTPaths.sqliteName)
        let helpers = [
            DemoPaths.siblingBackendRepo("mcp-prism").appendingPathComponent("dist/graph-db.js"),
            DemoPaths.siblingBackendRepo("swift-prism").appendingPathComponent("mcp-server/dist/graph-db.js"),
        ]
        guard let helper = helpers.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return db
        }
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
