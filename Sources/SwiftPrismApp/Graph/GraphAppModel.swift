import Foundation
import SwiftUI

@MainActor
final class GraphAppModel: ObservableObject {
    @Published var projectRoot: URL?
    @Published var document: GraphDocument = .empty
    @Published var selectedId: String?
    @Published var status: String = "Open a project (or LiteTrace demo)."
    @Published var isBusy = false
    /// Auto-detected language id (`swift`, `js`, …). `nil` if unknown / error.
    @Published var detectedLanguageId: String?
    @Published var detectEvidence: String = ""
    @Published var searchQuery: String = ""

    var selectedBackend: BackendPlugin? {
        guard let detectedLanguageId else { return nil }
        return BackendCatalog.plugin(id: detectedLanguageId)
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
        projectRoot != nil && selectedBackend != nil && !isBusy
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

    /// Set project root, auto-detect language, load cache if any.
    private func adoptProject(_ url: URL) {
        projectRoot = url
        document = .empty
        selectedId = nil
        do {
            let detected = try LanguageDetect.detect(projectRoot: url)
            detectedLanguageId = detected.languageId
            detectEvidence = detected.evidence
            let langName = selectedBackend?.name ?? detected.languageId
            status = "\(url.lastPathComponent) → \(langName) (\(detected.evidence))"
            tryLoadSoT()
        } catch {
            detectedLanguageId = nil
            detectEvidence = ""
            document = .empty
            status = error.localizedDescription
        }
    }

    func installSelectedBackend() {
        guard let plugin = selectedBackend else {
            status = "Chưa nhận diện được ngôn ngữ — không cài được backend."
            return
        }
        isBusy = true
        status = "Installing \(plugin.name) backend…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dest = try BackendRunner.install(plugin)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = "Installed \(plugin.name) → \(dest.path)"
                    self.objectWillChange.send()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func analyze() {
        guard let root = projectRoot else {
            status = BackendError.noProject.localizedDescription
            return
        }
        guard let plugin = selectedBackend else {
            status = "Không nhận diện được ngôn ngữ cho project này — Analyze bị hủy."
            return
        }
        isBusy = true
        status = "Running \(plugin.name) backend → ~/Library/Caches/code-prism/…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let json = try BackendRunner.analyze(projectRoot: root, plugin: plugin)
                let doc = try GraphLoader.load(projectRoot: root, language: plugin.id)
                DispatchQueue.main.async {
                    self.document = doc
                    self.selectedId = doc.nodes.first?.id
                    self.isBusy = false
                    self.status = "SoT cached (\(plugin.name)): \(doc.nodes.count) nodes, \(doc.links.count) links · \(json.deletingLastPathComponent().path)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func tryLoadSoT() {
        guard let root = projectRoot else { return }
        guard let lang = detectedLanguageId else {
            document = .empty
            return
        }
        do {
            let doc = try GraphLoader.load(projectRoot: root, language: lang)
            document = doc
            if selectedId == nil { selectedId = doc.nodes.first?.id }
            status = "Loaded SoT (\(lang)): \(doc.nodes.count) nodes, \(doc.links.count) links"
        } catch {
            document = .empty
            // Keep detect status; append load hint
            if let backend = selectedBackend {
                status = "\(root.lastPathComponent) → \(backend.name) (\(detectEvidence)). Chưa có cache — bấm Analyze."
            } else {
                status = error.localizedDescription
            }
        }
    }
}
