import AppKit
import SceneKit
import SwiftUI
import simd

struct GraphSceneView: NSViewRepresentable {
    var document: GraphDocument
    var selectedId: String?
    var onSelect: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        context.coordinator.view = view

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        view.addGestureRecognizer(click)

        context.coordinator.rebuild(document: document, selectedId: selectedId)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        if context.coordinator.documentSignature != documentSignature(document) {
            context.coordinator.rebuild(document: document, selectedId: selectedId)
        } else {
            context.coordinator.updateSelection(selectedId)
        }
    }

    private func documentSignature(_ doc: GraphDocument) -> String {
        "\(doc.nodes.count)|\(doc.links.count)|\(doc.generatedAt)|\(doc.projectRoot)"
    }

    final class Coordinator: NSObject {
        var onSelect: (String?) -> Void
        weak var view: SCNView?
        var documentSignature: String = ""
        private var nodeMap: [String: SCNNode] = [:]
        private var layout: ForceLayout3D?
        private var tickTimer: Timer?
        private var graph: GraphDocument = .empty

        init(onSelect: @escaping (String?) -> Void) {
            self.onSelect = onSelect
        }

        func rebuild(document: GraphDocument, selectedId: String?) {
            tickTimer?.invalidate()
            graph = document
            documentSignature = "\(document.nodes.count)|\(document.links.count)|\(document.generatedAt)|\(document.projectRoot)"

            let scene = SCNScene()
            scene.background.contents = NSColor(calibratedWhite: 0.07, alpha: 1)

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.zFar = 200
            camera.position = SCNVector3(0, 4, 14)
            camera.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(camera)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 400
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 800
            key.eulerAngles = SCNVector3(-0.6, 0.4, 0)
            scene.rootNode.addChildNode(key)

            nodeMap.removeAll()
            let ids = document.nodes.map(\.id)
            let linkPairs = document.links.map { ($0.source, $0.target) }
            let force = ForceLayout3D(nodeIds: ids, links: linkPairs)
            // Warm layout
            for _ in 0..<90 {
                _ = force.tick(1)
            }
            layout = force

            let root = SCNNode()
            root.name = "graphRoot"
            for n in document.nodes {
                let geo = NodeGeometry.makeGeometry(flavor: n.flavor)
                let node = SCNNode(geometry: geo)
                node.name = n.id
                if let p = force.positions[n.id] {
                    node.simdPosition = p
                }
                // Billboard label
                let text = SCNText(string: n.name, extrusionDepth: 0.01)
                text.font = NSFont.systemFont(ofSize: 0.35, weight: .medium)
                text.flatness = 0.2
                let textNode = SCNNode(geometry: text)
                textNode.scale = SCNVector3(0.015, 0.015, 0.015)
                textNode.position = SCNVector3(0.2, 0.35, 0)
                let tm = SCNMaterial()
                tm.diffuse.contents = NSColor.white
                text.materials = [tm]
                node.addChildNode(textNode)
                root.addChildNode(node)
                nodeMap[n.id] = node
            }

            for link in document.links {
                guard let a = force.positions[link.source], let b = force.positions[link.target] else { continue }
                let line = NodeGeometry.makeLinkNode(from: a, to: b, kind: link.kind)
                line.name = "link:\(link.id)"
                root.addChildNode(line)
            }

            scene.rootNode.addChildNode(root)
            view?.scene = scene
            view?.pointOfView = camera
            updateSelection(selectedId)

            // Settle a bit more live
            var ticks = 0
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
                guard let self, let layout = self.layout else { t.invalidate(); return }
                let e = layout.tick(2)
                for (id, node) in self.nodeMap {
                    if let p = layout.positions[id] {
                        node.simdPosition = p
                    }
                }
                // Rebuild links cheaply every few frames
                ticks += 1
                if ticks % 3 == 0 {
                    self.refreshLinks(in: root, layout: layout)
                }
                if e < 0.002 || ticks > 120 {
                    t.invalidate()
                    self.refreshLinks(in: root, layout: layout)
                }
            }
        }

        private func refreshLinks(in root: SCNNode, layout: ForceLayout3D) {
            root.childNodes.filter { $0.name?.hasPrefix("link:") == true }.forEach { $0.removeFromParentNode() }
            for link in graph.links {
                guard let a = layout.positions[link.source], let b = layout.positions[link.target] else { continue }
                let line = NodeGeometry.makeLinkNode(from: a, to: b, kind: link.kind)
                line.name = "link:\(link.id)"
                root.addChildNode(line)
            }
        }

        func updateSelection(_ selectedId: String?) {
            for (id, node) in nodeMap {
                let selected = id == selectedId
                node.geometry?.firstMaterial?.emission.contents = selected
                    ? NSColor.systemYellow
                    : NSColor.black
                node.scale = selected ? SCNVector3(1.35, 1.35, 1.35) : SCNVector3(1, 1, 1)
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view else { return }
            let p = gesture.location(in: view)
            let hits = view.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            if let name = hits.first?.node.name, nodeMap[name] != nil {
                onSelect(name)
            } else if let parentName = hits.first?.node.parent?.name, nodeMap[parentName] != nil {
                onSelect(parentName)
            } else {
                onSelect(nil)
            }
        }
    }
}
