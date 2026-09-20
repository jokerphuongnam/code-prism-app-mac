import Foundation
import SwiftUI

enum AppScreen: Equatable {
    case welcome
    case build
    case graph
}

@MainActor
final class GraphAppModel: ObservableObject {
    @Published var screen: AppScreen = .welcome
    @Published var projectRoot: URL?
    @Published var document: GraphDocument = .empty
    @Published var selectedId: String?
    @Published var status: String = "File → Open… or click Open Project to choose a folder."
    @Published var isBusy = false
    @Published var buildProgressLabel: String = "Building…"
    @Published var detectedLanguages: [LanguageDetect.Result] = []
    @Published var searchQuery: String = ""
    @Published var lastFingerprint: GraphFingerprint?
    /// Camera zoom for SceneKit graph (1 = default). ⌘+scroll / magnifier buttons.
    @Published var graphZoom: CGFloat = 1.0

    private let watcher = ProjectWatcher()
    private weak var bookmarks: BookmarkStore?
    private let zoomMin: CGFloat = 0.35
    private let zoomMax: CGFloat = 4.0

    func zoomIn() { setGraphZoom(graphZoom * 1.12) }
    func zoomOut() { setGraphZoom(graphZoom / 1.12) }
    func resetZoom() { setGraphZoom(1) }
    func setGraphZoom(_ value: CGFloat) {
        graphZoom = min(max(value, zoomMin), zoomMax)
    }
    func nudgeGraphZoom(deltaY: CGFloat) {
        setGraphZoom(graphZoom * (deltaY > 0 ? 1.08 : 0.92))
    }

    var detectedLanguageIds: [String] { detectedLanguages.map(\.languageId) }

    func attachBookmarks(_ store: BookmarkStore) {
        bookmarks = store
    }

    var selectedBackends: [BackendPlugin] {
        let plugins = PluginDiscovery.discover()
        return detectedLanguageIds.compactMap { id in plugins.first { $0.id == id } }
    }

    var languagesLabel: String {
        guard !detectedLanguages.isEmpty else { return "Unknown language" }
        let plugins = PluginDiscovery.discover()
        return detectedLanguages.map { det in
            plugins.first { $0.id == det.languageId }?.name ?? det.languageId
        }.joined(separator: " + ")
    }

    var selectedNode: GraphNode? {
        guard let selectedId else { return nil }
        return document.nodes.first { $0.id == selectedId }
    }

    var filteredNodes: [GraphNode] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return document.nodes }
        return document.nodes.filter {
            $0.id.lowercased().contains(q)
                || $0.name.lowercased().contains(q)
                || $0.signature.lowercased().contains(q)
        }
    }

    var canAnalyze: Bool {
        projectRoot != nil && !selectedBackends.isEmpty && !isBusy
    }

    var hasCachedGraph: Bool {
        guard let root = projectRoot, !detectedLanguageIds.isEmpty else { return false }
        return SoTCache.resolveJSON(projectRoot: root, preferred: detectedLanguageIds.first) != nil
    }

    init() {
        watcher.onChange = { [weak self] in
            self?.analyze(fullBuild: false, reason: "file change")
        }
    }

    // MARK: - Open (within this project window)

    func openProject() {
        if let url = BackendRunner.pickProjectFolder(start: projectRoot ?? DemoPaths.liteTrace) {
            adoptProject(url)
        }
    }

    func openLiteTraceDemo() {
        let url = DemoPaths.liteTrace
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = "LiteTrace not found at \(url.path)"
            return
        }
        adoptProject(url)
    }

    /// Load / switch this window to a project folder (also bookmarks it).
    func adoptProject(_ url: URL) {
        watcher.stop()
        projectRoot = url
        document = .empty
        selectedId = nil
        lastFingerprint = nil
        graphZoom = 1
        do {
            let detected = try LanguageDetect.detectAll(projectRoot: url)
            detectedLanguages = detected
            let detail = detected.map { "\($0.languageId)(\($0.evidence))" }.joined(separator: "; ")
            status = "\(url.lastPathComponent) → \(languagesLabel) · \(detail)"
            screen = .build
            bookmarks?.remember(url: url, languages: detectedLanguageIds)
            if let doc = try? GraphLoader.loadMerged(projectRoot: url, languages: detectedLanguageIds) {
                lastFingerprint = GraphFingerprint.from(doc)
            }
            watcher.start(projectRoot: url)
        } catch {
            detectedLanguages = []
            document = .empty
            status = error.localizedDescription
            screen = .build
            bookmarks?.remember(url: url, languages: [])
        }
    }

    func showGraph() {
        tryLoadSoT()
        screen = .graph
    }

    func backToBuild() {
        screen = .build
    }

    // MARK: - Backends / analyze

    func installSelectedBackend() {
        let plugins = selectedBackends
        guard !plugins.isEmpty else {
            status = "Chưa nhận diện được ngôn ngữ — không cài được backend."
            return
        }
        isBusy = true
        status = "Installing \(plugins.map(\.name).joined(separator: ", "))…"
        DispatchQueue.global(qos: .userInitiated).async {
            var messages: [String] = []
            for plugin in plugins {
                do {
                    let dest = try BackendRunner.install(plugin)
                    messages.append("\(plugin.name)→\(dest.lastPathComponent)")
                } catch {
                    messages.append("\(plugin.name): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.status = messages.joined(separator: " · ")
            }
        }
    }

    /// - fullBuild: user pressed Build (always show progress; still skip write if fingerprint unchanged)
    /// - reason: "file change" for watcher-driven incremental
    func analyze(fullBuild: Bool, reason: String = "manual") {
        guard let root = projectRoot else {
            status = BackendError.noProject.localizedDescription
            return
        }
        let plugins = selectedBackends
        guard !plugins.isEmpty else {
            status = "Không nhận diện được ngôn ngữ — Analyze bị hủy."
            return
        }
        if isBusy { return }

        isBusy = true
        buildProgressLabel = fullBuild ? "Building all languages…" : "Checking graph updates…"
        status = "\(buildProgressLabel) (\(reason))"

        let langs = plugins.map(\.id)
        let previous = lastFingerprint

        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            for (i, plugin) in plugins.enumerated() {
                DispatchQueue.main.async {
                    self.buildProgressLabel = "[\(i + 1)/\(plugins.count)] \(plugin.name)…"
                }
                do {
                    _ = try BackendRunner.analyze(projectRoot: root, plugin: plugin)
                } catch {
                    errors.append("\(plugin.name): \(error.localizedDescription)")
                }
            }

            do {
                let doc = try GraphLoader.loadMerged(projectRoot: root, languages: langs)
                let fingerprint = GraphFingerprint.from(doc)
                let changed = previous.map { $0 != fingerprint } ?? true

                DispatchQueue.main.async {
                    self.isBusy = false
                    if !changed {
                        self.status =
                            "No structural graph change (\(fingerprint.summary)) — body-only edits ignored."
                        // Keep showing graph if already there
                        if self.screen == .build, self.hasCachedGraph {
                            self.document = doc
                        }
                        return
                    }

                    self.lastFingerprint = fingerprint
                    self.document = doc
                    self.selectedId = doc.nodes.first?.id
                    let diff = previous.map { fingerprint.diffDescription(against: $0) } ?? "initial build"
                    var msg = "Cache updated (\(diff)) · \(doc.nodes.count) nodes, \(doc.links.count) links"
                    if !errors.isEmpty {
                        msg += " · partial: " + errors.joined(separator: "; ")
                    }
                    self.status = msg
                    self.screen = .graph
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = errors.isEmpty ? error.localizedDescription : errors.joined(separator: "; ")
                }
            }
        }
    }

    func tryLoadSoT() {
        guard let root = projectRoot else { return }
        let langs = detectedLanguageIds
        guard !langs.isEmpty else {
            document = .empty
            return
        }
        do {
            let doc = try GraphLoader.loadMerged(projectRoot: root, languages: langs)
            document = doc
            lastFingerprint = GraphFingerprint.from(doc)
            if selectedId == nil { selectedId = doc.nodes.first?.id }
            status = "Loaded SoT (\(langs.joined(separator: "+"))): \(doc.nodes.count) nodes, \(doc.links.count) links"
        } catch {
            document = .empty
            status = "\(root.lastPathComponent) → \(languagesLabel). Chưa có cache — bấm Build into cache."
        }
    }
}
