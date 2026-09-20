import CryptoKit
import Foundation

/// SPM-like SoT cache — never inside the user project.
enum SoTCache {
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("code-prism", isDirectory: true)
    }

    static func projectKey(for projectRoot: URL) -> String {
        let real = projectRoot.standardizedFileURL.path
        let data = Data(real.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() // 16 hex chars
    }

    static func directory(language: String, projectRoot: URL) -> URL {
        root
            .appendingPathComponent(language, isDirectory: true)
            .appendingPathComponent(projectKey(for: projectRoot), isDirectory: true)
    }

    static func jsonURL(language: String, projectRoot: URL) -> URL {
        directory(language: language, projectRoot: projectRoot)
            .appendingPathComponent("prism-context.json")
    }

    static func metaURL(language: String, projectRoot: URL) -> URL {
        directory(language: language, projectRoot: projectRoot)
            .appendingPathComponent("meta.json")
    }

    /// Find any language cache for this project (prefer `preferred`).
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
        // Legacy in-project paths (read-only migration)
        for name in [".codeprism", ".swiftprism"] {
            let legacy = projectRoot.appendingPathComponent("\(name)/prism-context.json")
            if fm.fileExists(atPath: legacy.path) { return legacy }
        }
        return nil
    }
}
