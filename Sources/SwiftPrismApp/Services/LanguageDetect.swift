import Foundation

enum LanguageDetect {
    struct Result: Equatable {
        var languageId: String
        var evidence: String
        var sourceFileCount: Int
        var score: Int
    }

    enum DetectError: LocalizedError {
        case none(URL)

        var errorDescription: String? {
            switch self {
            case .none(let root):
                return "Không nhận diện được ngôn ngữ trong “\(root.lastPathComponent)”. Cần Swift / Marlin / Kotlin / JS·TS / Rust / Go / C++ / Objective-C."
            }
        }
    }

    /// All languages present in the project (score > 0), strongest first.
    static func detectAll(projectRoot: URL) throws -> [Result] {
        let fm = FileManager.default
        let skip = Set([
            ".build", "DerivedData", "Pods", "node_modules", ".git", "Carthage",
            "dist", "target", ".next", ".turbo", "__pycache__", ".venv", "vendor",
        ])

        var counts: [String: Int] = [
            "swift": 0, "marlin": 0, "kotlin": 0, "js": 0, "rust": 0, "go": 0,
            "cpp": 0, "objc": 0,
        ]
        var markers: [String: [String]] = [:]
        var fileCounts: [String: Int] = [:]

        func addMarker(_ lang: String, _ note: String) {
            markers[lang, default: []].append(note)
        }

        let markerFiles: [(String, String, Int)] = [
            ("Package.swift", "swift", 50),
            ("go.mod", "go", 50),
            ("Cargo.toml", "rust", 50),
            ("build.gradle.kts", "kotlin", 50),
            ("build.gradle", "kotlin", 40),
            ("Application.marlin", "marlin", 50),
            ("package.json", "js", 40),
            ("tsconfig.json", "js", 45),
            ("CMakeLists.txt", "cpp", 50),
            ("compile_commands.json", "cpp", 45),
        ]
        for (name, lang, bonus) in markerFiles {
            let url = projectRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                counts[lang, default: 0] += bonus
                addMarker(lang, name)
            }
        }
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
            "c": "cpp", "cc": "cpp", "cpp": "cpp", "cxx": "cpp",
            "hh": "cpp", "hpp": "cpp", "hxx": "cpp",
            "m": "objc", "mm": "objc",
            "h": "cpp",
        ]

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

        // A language “exists” if it has source files OR a strong marker (≥ 40).
        var results: [Result] = []
        for (lang, score) in counts where score > 0 {
            let files = fileCounts[lang, default: 0]
            let hasMarker = !(markers[lang] ?? []).isEmpty
            // Skip marker-only noise with zero sources except strong project roots
            if files == 0, !hasMarker { continue }
            if files == 0, score < 40 { continue }

            let evidenceParts = markers[lang] ?? []
            let evidence: String
            if !evidenceParts.isEmpty {
                evidence = evidenceParts.joined(separator: ", ") + (files > 0 ? " · \(files) files" : "")
            } else {
                evidence = "\(files) source files"
            }
            results.append(
                Result(
                    languageId: lang,
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

    /// Primary language only (strongest score).
    static func detect(projectRoot: URL) throws -> Result {
        try detectAll(projectRoot: projectRoot)[0]
    }
}
