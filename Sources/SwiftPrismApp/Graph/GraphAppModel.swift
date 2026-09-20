import Foundation
import SwiftUI

@MainActor
final class GraphAppModel: ObservableObject {
    @Published var projectRoot: URL?
    @Published var document: GraphDocument = .empty
    @Published var selectedId: String?
    @Published var status: String = "Open a project (or LiteTrace demo)."
    @Published var isBusy = false
    @Published var selectedBackendId: String = "swift"
    @Published var searchQuery: String = ""

    var selectedBackend: BackendPlugin {
        BackendCatalog.plugin(id: selectedBackendId) ?? BackendCatalog.all[0]
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

    func openProject() {
        if let url = BackendRunner.pickProjectFolder(start: DemoPaths.liteTrace) {
            projectRoot = url
            status = "Opened \(url.lastPathComponent). Install/run a backend to refresh SoT, or Reload if SoT exists."
            tryLoadSoT()
        }
    }

    func openLiteTraceDemo() {
        let url = DemoPaths.liteTrace
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = "LiteTrace not found at \(url.path)"
            return
        }
        projectRoot = url
        selectedBackendId = "swift"
        status = "Demo: LiteTrace (Swift backend)"
        tryLoadSoT()
    }

    func installSelectedBackend() {
        let plugin = selectedBackend
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
        let plugin = selectedBackend
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
        do {
            let doc = try GraphLoader.load(projectRoot: root, language: selectedBackendId)
            document = doc
            if selectedId == nil { selectedId = doc.nodes.first?.id }
            status = "Loaded SoT from cache: \(doc.nodes.count) nodes, \(doc.links.count) links"
        } catch {
            document = .empty
            status = error.localizedDescription
        }
    }
}
