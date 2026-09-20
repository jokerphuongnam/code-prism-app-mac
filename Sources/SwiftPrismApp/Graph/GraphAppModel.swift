import Foundation
import SwiftUI

@MainActor
final class GraphAppModel: ObservableObject {
    @Published var projectRoot: URL?
    @Published var document: GraphDocument = .empty
    @Published var selectedId: String?
    @Published var status: String = "Open a project (or LiteTrace demo)."
    @Published var isBusy = false
    /// All detected languages (may be multiple).
    @Published var detectedLanguages: [LanguageDetect.Result] = []
    @Published var searchQuery: String = ""

    var detectedLanguageIds: [String] { detectedLanguages.map(\.languageId) }

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
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) || $0.signature.lowercased().contains(q)
        }
    }

    var canAnalyze: Bool {
        projectRoot != nil && !selectedBackends.isEmpty && !isBusy
    }

    func openProject() {
        if let url = BackendRunner.pickProjectFolder(start: DemoPaths.liteTrace) {
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

    private func adoptProject(_ url: URL) {
        projectRoot = url
        document = .empty
        selectedId = nil
        do {
            let detected = try LanguageDetect.detectAll(projectRoot: url)
            detectedLanguages = detected
            let detail = detected.map { "\($0.languageId)(\($0.evidence))" }.joined(separator: "; ")
            status = "\(url.lastPathComponent) → \(languagesLabel) · \(detail)"
            tryLoadSoT()
        } catch {
            detectedLanguages = []
            document = .empty
            status = error.localizedDescription
        }
    }

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
                self.objectWillChange.send()
            }
        }
    }

    func analyze() {
        guard let root = projectRoot else {
            status = BackendError.noProject.localizedDescription
            return
        }
        let plugins = selectedBackends
        guard !plugins.isEmpty else {
            status = "Không nhận diện được ngôn ngữ cho project này — Analyze bị hủy."
            return
        }
        isBusy = true
        status = "Running \(plugins.map(\.name).joined(separator: "+")) → ~/Library/Caches/code-prism/…"
        let langs = plugins.map(\.id)
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            for plugin in plugins {
                do {
                    _ = try BackendRunner.analyze(projectRoot: root, plugin: plugin)
                } catch {
                    errors.append("\(plugin.name): \(error.localizedDescription)")
                }
            }
            do {
                let doc = try GraphLoader.loadMerged(projectRoot: root, languages: langs)
                DispatchQueue.main.async {
                    self.document = doc
                    self.selectedId = doc.nodes.first?.id
                    self.isBusy = false
                    var msg = "SoT multi-lang: \(doc.nodes.count) nodes, \(doc.links.count) links (\(langs.joined(separator: "+")))"
                    if !errors.isEmpty {
                        msg += " · partial errors: " + errors.joined(separator: "; ")
                    }
                    self.status = msg
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
            if selectedId == nil { selectedId = doc.nodes.first?.id }
            status = "Loaded SoT (\(langs.joined(separator: "+"))): \(doc.nodes.count) nodes, \(doc.links.count) links"
        } catch {
            document = .empty
            status = "\(root.lastPathComponent) → \(languagesLabel). Chưa có cache — bấm Analyze."
        }
    }
}
