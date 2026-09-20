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
    static func langPrismFolder(_ languageId: String, cacheFolder: String? = nil) -> String {
        if let cacheFolder, !cacheFolder.isEmpty { return cacheFolder }
        if let plugin = BackendCatalog.plugin(id: languageId) {
            return plugin.cacheFolder
        }
        if languageId == "objc" { return "objective-c-prism" }
        if languageId.hasSuffix("-prism") { return languageId }
        return "\(languageId)-prism"
    }

    static func projectCacheDir(for projectRoot: URL) -> URL {
        root.appendingPathComponent(projectSlug(for: projectRoot), isDirectory: true)
    }

    static func directory(language: String, projectRoot: URL, cacheFolder: String? = nil) -> URL {
        projectCacheDir(for: projectRoot)
            .appendingPathComponent(langPrismFolder(language, cacheFolder: cacheFolder), isDirectory: true)
    }

    static func jsonURL(language: String, projectRoot: URL, cacheFolder: String? = nil) -> URL {
        directory(language: language, projectRoot: projectRoot, cacheFolder: cacheFolder)
            .appendingPathComponent("prism-context.json")
    }

    static func metaURL(language: String, projectRoot: URL, cacheFolder: String? = nil) -> URL {
        directory(language: language, projectRoot: projectRoot, cacheFolder: cacheFolder)
            .appendingPathComponent("meta.json")
    }

    static func resolveJSON(projectRoot: URL, preferred: String?) -> URL? {
        let plugins = PluginDiscovery.discover()
        let order: [DiscoveredPlugin]
        if let preferred, let pref = plugins.first(where: { $0.id == preferred }) {
            order = [pref] + plugins.filter { $0.id != preferred }
        } else {
            order = plugins
        }
        let fm = FileManager.default
        for plugin in order {
            let url = jsonURL(language: plugin.id, projectRoot: projectRoot, cacheFolder: plugin.cacheFolder)
            if fm.fileExists(atPath: url.path) { return url }
        }
        // Legacy: code-prism/<lang>/<hash>/
        let hash = projectHash(for: projectRoot)
        for plugin in order {
            let legacy = root
                .appendingPathComponent(plugin.id, isDirectory: true)
                .appendingPathComponent(hash, isDirectory: true)
                .appendingPathComponent("prism-context.json")
            if fm.fileExists(atPath: legacy.path) { return legacy }
        }
        return nil
    }
}
