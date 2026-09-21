import Foundation

enum LanguageDetect {
    struct Result: Equatable {
        var languageId: String
        var evidence: String
        var sourceFileCount: Int
        var score: Int
    }

    enum DetectError: LocalizedError {
        case noPlugins
        case none(URL)

        var errorDescription: String? {
            switch self {
            case .noPlugins:
                return "Không tìm thấy backend plugin nào trên máy. Clone vào ~/Documents/Code/code-prism/backends/*-prism hoặc Install backend."
            case .none(let root):
                let plugins = PluginDiscovery.discover().filter(\.canDetectLanguage)
                let langs = plugins.map(\.name).joined(separator: " / ")
                return "Không nhận diện được ngôn ngữ trong “\(root.lastPathComponent)”. Plugin hiện có: \(langs.isEmpty ? "(không có)" : langs)."
            }
        }
    }

    /// Extra junk dirs beyond BackendRunner.skip — keep detect fast on monorepos.
    private static let extraSkip: Set<String> = [
        ".cache", "CMakeFiles", "cmake-build-debug", "cmake-build-release",
        "out", "output", "xcuserdata", "Pods", "Carthage",
    ]

    /// Detect languages using **discovered plugins only**.
    /// Unknown extensions (no plugin) are ignored. Large monorepos use a shallow
    /// pass first so roots like marlin-language light up without walking all of build/.
    static func detectAll(projectRoot: URL, plugins: [DiscoveredPlugin]? = nil) throws -> [Result] {
        let plugins = (plugins ?? PluginDiscovery.discover()).filter(\.canDetectLanguage)
        guard !plugins.isEmpty else { throw DetectError.noPlugins }

        // 1) Fast shallow pass (company roots: mpm/, libraries/, projects/, …)
        let shallow = scan(
            projectRoot: projectRoot,
            plugins: plugins,
            maxDepth: 6,
            fileCap: 40_000
        )
        if !shallow.isEmpty { return shallow }

        // 2) Deeper fallback for unusual layouts
        let deep = scan(
            projectRoot: projectRoot,
            plugins: plugins,
            maxDepth: 16,
            fileCap: 120_000
        )
        guard !deep.isEmpty else { throw DetectError.none(projectRoot) }
        return deep
    }

    private static func scan(
        projectRoot: URL,
        plugins: [DiscoveredPlugin],
        maxDepth: Int,
        fileCap: Int
    ) -> [Result] {
        let fm = FileManager.default
        let skip = BackendRunner.skipDirectoryNames.union(extraSkip)

        var counts: [String: Int] = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, 0) })
        var fileCounts: [String: Int] = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, 0) })
        var markersHit: [String: [String]] = [:]

        // Markers: root file, then shallow search (Application.marlin often under projects/)
        for plugin in plugins {
            for marker in plugin.markers {
                let rootHit = projectRoot.appendingPathComponent(marker)
                if fm.fileExists(atPath: rootHit.path) {
                    counts[plugin.id, default: 0] += 50
                    markersHit[plugin.id, default: []].append(marker)
                } else if let rel = findNamed(
                    marker,
                    under: projectRoot,
                    maxDepth: min(4, maxDepth),
                    skip: skip
                ) {
                    counts[plugin.id, default: 0] += 50
                    markersHit[plugin.id, default: []].append("\(rel)")
                }
            }
            if plugin.extensions.contains("swift"),
               let items = try? fm.contentsOfDirectory(atPath: projectRoot.path),
               items.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                counts[plugin.id, default: 0] += 40
                markersHit[plugin.id, default: []].append("*.xcodeproj")
            }
        }

        var extToLang: [String: String] = [:]
        for plugin in plugins {
            for ext in plugin.extensions where extToLang[ext] == nil {
                extToLang[ext] = plugin.id
            }
        }

        var headerCount = 0
        var seenFiles = 0
        walkFiles(projectRoot: projectRoot, maxDepth: maxDepth, skip: skip) { url in
            if seenFiles >= fileCap { return false }
            seenFiles += 1
            let ext = url.pathExtension.lowercased()
            if ext == "h" { headerCount += 1 }
            guard let lang = extToLang[ext] else { return true }
            counts[lang, default: 0] += 1
            fileCounts[lang, default: 0] += 1
            return true
        }
        if counts["objc", default: 0] > 0, headerCount > 0 {
            counts["objc", default: 0] += min(headerCount, counts["objc", default: 0])
        }

        var results: [Result] = []
        for plugin in plugins {
            let score = counts[plugin.id, default: 0]
            if score <= 0 { continue }
            let files = fileCounts[plugin.id, default: 0]
            let notes = markersHit[plugin.id] ?? []
            if files == 0, notes.isEmpty { continue }
            if files == 0, score < 40 { continue }
            let evidence: String
            if !notes.isEmpty {
                evidence = notes.joined(separator: ", ") + (files > 0 ? " · \(files) files" : "")
            } else {
                evidence = "\(files) source files"
            }
            results.append(
                Result(
                    languageId: plugin.id,
                    evidence: evidence,
                    sourceFileCount: files,
                    score: score
                )
            )
        }
        results.sort { $0.score > $1.score }
        return results
    }

    /// Recursive file walk with depth limit; `body` return false to abort.
    private static func walkFiles(
        projectRoot: URL,
        maxDepth: Int,
        skip: Set<String>,
        body: (URL) -> Bool
    ) {
        let fm = FileManager.default
        var stop = false
        func go(_ dir: URL, depth: Int) {
            guard !stop, depth <= maxDepth else { return }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for url in entries {
                if stop { return }
                let name = url.lastPathComponent
                if skip.contains(name) { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    go(url, depth: depth + 1)
                } else if !body(url) {
                    stop = true
                    return
                }
            }
        }
        go(projectRoot, depth: 0)
    }

    private static func findNamed(
        _ fileName: String,
        under root: URL,
        maxDepth: Int,
        skip: Set<String>
    ) -> String? {
        var found: String?
        let rootPath = root.path
        walkFiles(projectRoot: root, maxDepth: maxDepth, skip: skip) { url in
            if url.lastPathComponent == fileName {
                let path = url.path
                if path.hasPrefix(rootPath) {
                    var rel = String(path.dropFirst(rootPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    found = rel
                } else {
                    found = fileName
                }
                return false
            }
            return true
        }
        return found
    }
}
