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
                let plugins = PluginDiscovery.discover()
                let langs = plugins.map(\.name).joined(separator: " / ")
                return "Không nhận diện được ngôn ngữ trong “\(root.lastPathComponent)”. Plugin hiện có: \(langs.isEmpty ? "(không có)" : langs)."
            }
        }
    }

    /// Detect languages using **discovered plugins** only (extensions + markers from manifests).
    static func detectAll(projectRoot: URL, plugins: [DiscoveredPlugin]? = nil) throws -> [Result] {
        let plugins = plugins ?? PluginDiscovery.discover()
        guard !plugins.isEmpty else { throw DetectError.noPlugins }

        let fm = FileManager.default
        let skip = BackendRunner.skipDirectoryNames

        var counts: [String: Int] = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, 0) })
        var fileCounts: [String: Int] = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, 0) })
        var markersHit: [String: [String]] = [:]

        // Markers
        for plugin in plugins {
            for marker in plugin.markers {
                let url = projectRoot.appendingPathComponent(marker)
                if fm.fileExists(atPath: url.path) {
                    counts[plugin.id, default: 0] += 50
                    markersHit[plugin.id, default: []].append(marker)
                }
            }
            // Extra: xcodeproj for plugins that include "swift"
            if plugin.extensions.contains("swift"),
               let items = try? fm.contentsOfDirectory(atPath: projectRoot.path),
               items.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                counts[plugin.id, default: 0] += 40
                markersHit[plugin.id, default: []].append("*.xcodeproj")
            }
        }

        let extToLang: [String: String] = {
            var map: [String: String] = [:]
            for plugin in plugins {
                for ext in plugin.extensions {
                    // First plugin wins for shared exts like .h — prefer more specific later by score
                    if map[ext] == nil { map[ext] = plugin.id }
                }
            }
            // Prefer objc for .h when objc plugin exists and we'll boost via .m/.mm
            if plugins.contains(where: { $0.id == "objc" }) {
                // keep .h as cpp if both claim it; objc boost handles .m/.mm projects
            }
            return map
        }()

        // If both cpp and objc claim "h", map h → cpp by default; objc gets boost from m/mm
        var headerCount = 0
        guard let enumerator = fm.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DetectError.none(projectRoot)
        }

        for case let url as URL in enumerator {
            if skip.contains(where: { url.pathComponents.contains($0) }) {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ext == "h" { headerCount += 1 }
            guard let lang = extToLang[ext] else { continue }
            counts[lang, default: 0] += 1
            fileCounts[lang, default: 0] += 1
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
        guard !results.isEmpty else { throw DetectError.none(projectRoot) }
        return results
    }
}
