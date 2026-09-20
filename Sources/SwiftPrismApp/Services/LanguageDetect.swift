import Foundation

enum LanguageDetect {
    struct Result: Equatable {
        var languageId: String
        var evidence: String
        var sourceFileCount: Int
    }

    enum DetectError: LocalizedError {
        case none(URL)

        var errorDescription: String? {
            switch self {
            case .none(let root):
                return "Không nhận diện được ngôn ngữ trong “\(root.lastPathComponent)”. Cần Swift / Marlin / Kotlin / JS·TS / Rust / Go (file nguồn hoặc manifest)."
            }
        }
    }

    /// Detect primary language for a project folder. Throws if none match.
    static func detect(projectRoot: URL) throws -> Result {
        let fm = FileManager.default
        let skip = Set([
            ".build", "DerivedData", "Pods", "node_modules", ".git", "Carthage",
            "dist", "target", ".next", ".turbo", "__pycache__", ".venv", "vendor",
        ])

        var counts: [String: Int] = [
            "swift": 0, "marlin": 0, "kotlin": 0, "js": 0, "rust": 0, "go": 0,
        ]
        var markers: [String: [String]] = [:]

        func addMarker(_ lang: String, _ note: String) {
            markers[lang, default: []].append(note)
        }

        // Manifest / project markers (strong signal)
        let markerFiles: [(String, String)] = [
            ("Package.swift", "swift"),
            ("go.mod", "go"),
            ("Cargo.toml", "rust"),
            ("build.gradle.kts", "kotlin"),
            ("build.gradle", "kotlin"),
            ("Application.marlin", "marlin"),
            ("package.json", "js"),
            ("tsconfig.json", "js"),
        ]
        for (name, lang) in markerFiles {
            let url = projectRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                counts[lang, default: 0] += 50
                addMarker(lang, name)
            }
        }
        // Xcode project
        if let items = try? fm.contentsOfDirectory(atPath: projectRoot.path) {
            if items.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                counts["swift", default: 0] += 40
                addMarker("swift", "*.xcodeproj/xcworkspace")
            }
        }

        let extToLang: [String: String] = [
            "swift": "swift",
            "marlin": "marlin",
            "kt": "kotlin", "kts": "kotlin",
            "js": "js", "jsx": "js", "ts": "js", "tsx": "js", "mjs": "js", "cjs": "js",
            "rs": "rust",
            "go": "go",
        ]

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
            guard let lang = extToLang[ext] else { continue }
            counts[lang, default: 0] += 1
        }

        let ranked = counts.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value > 0 else {
            throw DetectError.none(projectRoot)
        }

        let evidenceParts = markers[best.key] ?? []
        let fileCount = max(0, best.value - (evidenceParts.isEmpty ? 0 : 0))
        // Subtract marker bonuses for display count roughly
        let sourceOnly = counts[best.key, default: 0]
        let evidence: String
        if !evidenceParts.isEmpty {
            evidence = evidenceParts.joined(separator: ", ") + " · ~\(sourceOnly) scored files"
        } else {
            evidence = "~\(sourceOnly) source files"
        }

        return Result(languageId: best.key, evidence: evidence, sourceFileCount: sourceOnly)
    }
}
