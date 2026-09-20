import CryptoKit
import Foundation

/// SPM-like SoT cache:
/// `~/Library/Caches/code-prism/<projectName>-<hash>/{lang}-prism/`
enum SoTCache {
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("code-prism", isDirectory: true)
    }

    static func sanitizeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]+",
            with: "-",
            options: .regularExpression
        )
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "project" : trimmed
    }

    static func projectHash(for projectRoot: URL) -> String {
        let real = projectRoot.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(real.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func projectSlug(for projectRoot: URL) -> String {
        let name = sanitizeName(projectRoot.standardizedFileURL.lastPathComponent)
        return "\(name)-\(projectHash(for: projectRoot))"
    }

    /// Folder name under project cache: `swift-prism`, `objective-c-prism`, …
    static func langPrismFolder(_ languageId: String) -> String {
        if languageId == "objc" { return "objective-c-prism" }
        if languageId.hasSuffix("-prism") { return languageId }
        return "\(languageId)-prism"
    }

    static func projectCacheDir(for projectRoot: URL) -> URL {
        root.appendingPathComponent(projectSlug(for: projectRoot), isDirectory: true)
    }

    static func directory(language: String, projectRoot: URL) -> URL {
        projectCacheDir(for: projectRoot)
            .appendingPathComponent(langPrismFolder(language), isDirectory: true)
    }

    static func jsonURL(language: String, projectRoot: URL) -> URL {
        directory(language: language, projectRoot: projectRoot)
            .appendingPathComponent("prism-context.json")
    }

    static func metaURL(language: String, projectRoot: URL) -> URL {
        directory(language: language, projectRoot: projectRoot)
            .appendingPathComponent("meta.json")
    }

    static func resolveJSON(projectRoot: URL, preferred: String?) -> URL? {
        let order: [String]
        if let preferred {
            order = [preferred] + BackendCatalog.all.map(\.id).filter { $0 != preferred }
        } else {
            order = BackendCatalog.all.map(\.id)
        }
        let fm = FileManager.default
        for lang in order {
            let url = jsonURL(language: lang, projectRoot: projectRoot)
            if fm.fileExists(atPath: url.path) { return url }
        }
        // Legacy: code-prism/<lang>/<hash>/
        let hash = projectHash(for: projectRoot)
        for lang in order {
            let legacy = root
                .appendingPathComponent(lang, isDirectory: true)
                .appendingPathComponent(hash, isDirectory: true)
                .appendingPathComponent("prism-context.json")
            if fm.fileExists(atPath: legacy.path) { return legacy }
        }
        return nil
    }
}
