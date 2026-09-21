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
    /// Wide range so dense graphs (e.g. marlin-language) can inspect a single node.
    private let zoomMin: CGFloat = 0.08
    private let zoomMax: CGFloat = 80.0
    /// Bumps to drop stale background load results after rapid Open / Skip.
    private var loadGeneration: UInt64 = 0
    private let loadQueue = DispatchQueue(label: "app.codeprism.sot-load", qos: .userInitiated)

    func zoomIn() { setGraphZoom(graphZoom * 1.2) }
    func zoomOut() { setGraphZoom(graphZoom / 1.2) }
    func resetZoom() { setGraphZoom(1) }
    func setGraphZoom(_ value: CGFloat) {
        graphZoom = min(max(value, zoomMin), zoomMax)
    }
    func nudgeGraphZoom(deltaY: CGFloat) {
        setGraphZoom(graphZoom * (deltaY > 0 ? 1.12 : 0.89))
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
                || $0.filePath.lowercased().contains(q)
        }
    }

    /// Sidebar groups — company subprojects as islands (mpm, libraries, …).
    var nodesByIsland: [(island: String, nodes: [GraphNode])] {
        let root = document.projectRoot
        var buckets: [String: [GraphNode]] = [:]
        for n in filteredNodes {
            let key =
                n.filePath.isEmpty
                ? "external"
                : IslandLayout.islandKey(filePath: n.filePath, projectRoot: root)
            buckets[key, default: []].append(n)
        }
        return buckets.keys.sorted { a, b in
            if a == "external" { return false }
            if b == "external" { return true }
            return (buckets[a]?.count ?? 0) > (buckets[b]?.count ?? 0)
        }.map { ($0, buckets[$0] ?? []) }
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
            guard let self else { return }
            // Never stack incremental builds on top of an in-flight Build / Open storm.
            guard !self.isBusy, self.screen == .graph else { return }
            self.analyze(fullBuild: false, reason: "file change")
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
        loadGeneration &+= 1
        let gen = loadGeneration
        projectRoot = url
        document = .empty
        selectedId = nil
        lastFingerprint = nil
        detectedLanguages = []
        graphZoom = 1
        screen = .build
        isBusy = true
        buildProgressLabel = "Detecting languages…"
        status = "Opening \(url.lastPathComponent)…"
        bookmarks?.remember(url: url, languages: [])

        loadQueue.async { [weak self] in
            do {
                // Detect only on Open — full SoT decode happens later on Skip/Build (background).
                let detected = try LanguageDetect.detectAll(projectRoot: url)
                let langs = detected.map(\.languageId)
                let hasCache = langs.contains { SoTCache.resolveJSON(projectRoot: url, preferred: $0) != nil }
                DispatchQueue.main.async {
                    guard let self, gen == self.loadGeneration else { return }
                    self.detectedLanguages = detected
                    let detail = detected.map { "\($0.languageId)(\($0.evidence))" }.joined(separator: "; ")
                    self.status =
                        "\(url.lastPathComponent) → \(self.languagesLabel) · \(detail)"
                        + (hasCache ? " · cache ready" : " · no cache yet")
                    self.isBusy = false
                    self.bookmarks?.remember(url: url, languages: langs)
                    self.watcher.start(projectRoot: url)
                    self.watcher.isEnabled = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, gen == self.loadGeneration else { return }
                    self.detectedLanguages = []
                    self.document = .empty
                    self.status = error.localizedDescription
                    self.isBusy = false
                    self.bookmarks?.remember(url: url, languages: [])
                }
            }
        }
    }

    func showGraph() {
        screen = .graph
        watcher.isEnabled = false
        loadSoTInBackground(reason: "open graph")
    }

    func backToBuild() {
        watcher.isEnabled = false
        screen = .build
    }

    func cancelBuild() {
        BackendRunner.cancelActiveAnalyze()
        buildProgressLabel = "Cancelling…"
        status = "Cancelling build…"
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
        watcher.isEnabled = false
        BackendRunner.resetCancelFlag()
        buildProgressLabel = fullBuild ? "Building all languages…" : "Checking graph updates…"
        status = "\(buildProgressLabel) (\(reason))"

        let langs = plugins.map(\.id)
        let previous = lastFingerprint

        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            var cancelled = false
            for (i, plugin) in plugins.enumerated() {
                DispatchQueue.main.async {
                    self.buildProgressLabel = "[\(i + 1)/\(plugins.count)] \(plugin.name)…"
                }
                do {
                    _ = try BackendRunner.analyze(projectRoot: root, plugin: plugin)
                } catch BackendError.cancelled {
                    cancelled = true
                    errors.append("\(plugin.name): cancelled")
                    break
                } catch {
                    errors.append("\(plugin.name): \(error.localizedDescription)")
                }
            }

            if cancelled {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.buildProgressLabel = "Cancelled"
                    self.status = "Build cancelled. Partial: " + (errors.isEmpty ? "none" : errors.joined(separator: "; "))
                    if self.screen == .graph { self.watcher.isEnabled = true }
                }
                return
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
                        if self.screen == .graph { self.watcher.isEnabled = true }
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
                    // Re-enable watcher only after graph is up — avoid analyze→write→re-analyze loops.
                    self.watcher.isEnabled = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = errors.isEmpty ? error.localizedDescription : errors.joined(separator: "; ")
                    if self.screen == .graph { self.watcher.isEnabled = true }
                }
            }
        }
    }

    func tryLoadSoT() {
        loadSoTInBackground(reason: "reload")
    }

    /// Decode SoT JSON off the main thread; publish `document` only when done.
    private func loadSoTInBackground(reason: String) {
        guard let root = projectRoot else { return }
        let langs = detectedLanguageIds
        guard !langs.isEmpty else {
            document = .empty
            status = "Chưa nhận diện được ngôn ngữ."
            return
        }

        loadGeneration &+= 1
        let gen = loadGeneration
        isBusy = true
        buildProgressLabel = "Loading SoT…"
        status = "Loading SoT (\(langs.joined(separator: "+"))) in background…"

        loadQueue.async { [weak self] in
            do {
                let doc = try GraphLoader.loadMerged(projectRoot: root, languages: langs)
                let fp = GraphFingerprint.from(doc)
                DispatchQueue.main.async {
                    guard let self, gen == self.loadGeneration else { return }
                    self.document = doc
                    self.lastFingerprint = fp
                    if self.selectedId == nil || self.document.nodes.contains(where: { $0.id == self.selectedId }) == false {
                        self.selectedId = doc.nodes.first?.id
                    }
                    self.isBusy = false
                    self.status =
                        "Loaded SoT (\(langs.joined(separator: "+"))): \(doc.nodes.count) nodes, \(doc.links.count) links · \(reason)"
                    if self.screen == .graph {
                        self.watcher.isEnabled = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, gen == self.loadGeneration else { return }
                    self.document = .empty
                    self.isBusy = false
                    self.status =
                        "\(root.lastPathComponent) → \(self.languagesLabel). Chưa có cache — bấm Build into cache."
                    if self.screen == .graph {
                        self.watcher.isEnabled = true
                    }
                }
            }
        }
    }
}
