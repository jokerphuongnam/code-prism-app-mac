import AppKit
import SceneKit
import SwiftUI
import simd

struct GraphSceneView: NSViewRepresentable {
    var document: GraphDocument
    var selectedId: String?
    var zoom: CGFloat
    var onSelect: (String?) -> Void
    var onZoomChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onZoomChange: onZoomChange)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = HoverSCNView()
        view.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        context.coordinator.view = view
        view.onHoverChange = { context.coordinator.isHovered = $0 }
        view.onCommandScroll = { delta in
            context.coordinator.nudgeZoomFromScroll(delta)
        }

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        view.addGestureRecognizer(click)

        context.coordinator.rebuild(document: document, selectedId: selectedId, zoom: zoom)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.externalZoom = zoom
        if let hover = nsView as? HoverSCNView {
            hover.onCommandScroll = { delta in
                context.coordinator.nudgeZoomFromScroll(delta)
            }
        }
        if context.coordinator.documentSignature != documentSignature(document) {
            context.coordinator.rebuild(document: document, selectedId: selectedId, zoom: zoom)
        } else {
            context.coordinator.updateSelection(selectedId)
            context.coordinator.applyCameraZoom(zoom)
        }
    }

    private func documentSignature(_ doc: GraphDocument) -> String {
        "\(doc.nodes.count)|\(doc.links.count)|\(doc.generatedAt)|\(doc.projectRoot)"
    }

    final class Coordinator: NSObject {
        var onSelect: (String?) -> Void
        var onZoomChange: (CGFloat) -> Void
        weak var view: SCNView?
        var documentSignature: String = ""
        var isHovered = false
        var externalZoom: CGFloat = 1

        private var nodeMap: [String: SCNNode] = [:]
        private var layout: ForceLayout3D?
        private var tickTimer: Timer?
        private var graph: GraphDocument = .empty
        private weak var cameraNode: SCNNode?
        private var baseCameraDistance: Float = 16

        init(onSelect: @escaping (String?) -> Void, onZoomChange: @escaping (CGFloat) -> Void) {
            self.onSelect = onSelect
            self.onZoomChange = onZoomChange
        }

        func nudgeZoomFromScroll(_ deltaY: CGFloat) {
            let factor: CGFloat = deltaY > 0 ? 1.08 : 0.92
            let next = min(max(externalZoom * factor, 0.35), 4.0)
            onZoomChange(next)
        }

        func rebuild(document: GraphDocument, selectedId: String?, zoom: CGFloat) {
            tickTimer?.invalidate()
            graph = document
            documentSignature =
                "\(document.nodes.count)|\(document.links.count)|\(document.generatedAt)|\(document.projectRoot)"
            externalZoom = zoom

            let scene = SCNScene()
            scene.background.contents = NSColor(calibratedWhite: 0.07, alpha: 1)

            let camera = SCNNode()
            camera.name = "camera"
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.1
            camera.camera?.zFar = 500
            camera.camera?.fieldOfView = 55
            baseCameraDistance = max(12, Float(document.nodes.count) * 0.35 + 10)
            camera.position = SCNVector3(0, baseCameraDistance * 0.25, baseCameraDistance)
            camera.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(camera)
            cameraNode = camera

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 500
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 900
            key.eulerAngles = SCNVector3(-0.6, 0.4, 0)
            scene.rootNode.addChildNode(key)

            nodeMap.removeAll()
            let ids = document.nodes.map(\.id)
            let linkPairs = document.links.map { ($0.source, $0.target) }
            let force = ForceLayout3D(nodeIds: ids, links: linkPairs)
            // Wider layout so labels don't pile up
            force.linkDistance = 4.2
            force.charge = -42
            for _ in 0..<110 {
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

                // Sprite label (SCNText is unreliable / often invisible at bad scales)
                let label = makeBillboardLabel(shortName(n.name))
                label.position = SCNVector3(0, 0.55, 0)
                node.addChildNode(label)

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
            applyCameraZoom(zoom)
            updateSelection(selectedId)

            var ticks = 0
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
                guard let self, let layout = self.layout else {
                    t.invalidate()
                    return
                }
                let e = layout.tick(2)
                for (id, node) in self.nodeMap {
                    if let p = layout.positions[id] {
                        node.simdPosition = p
                    }
                }
                ticks += 1
                if ticks % 3 == 0 {
                    self.refreshLinks(in: root, layout: layout)
                }
                if e < 0.002 || ticks > 100 {
                    t.invalidate()
                    self.refreshLinks(in: root, layout: layout)
                }
            }
        }

        func applyCameraZoom(_ zoom: CGFloat) {
            guard let camera = cameraNode else { return }
            let z = CGFloat(baseCameraDistance) / max(zoom, 0.2)
            let y = z * 0.25
            // Keep looking at origin; preserve X from camera control if any
            let x = camera.position.x
            camera.position = SCNVector3(x, y, z)
            camera.look(at: SCNVector3(0, 0, 0))
        }

        private func shortName(_ name: String) -> String {
            // Drop [lang] prefix noise for display; hard wrap length
            var s = name
            if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
                s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
            if s.count > 22 {
                return String(s.prefix(20)) + "…"
            }
            return s
        }

        private func makeBillboardLabel(_ text: String) -> SCNNode {
            let image = Self.renderLabelImage(text)
            let aspect = image.size.width / max(image.size.height, 1)
            let height: CGFloat = 0.42
            let width = height * aspect
            let plane = SCNPlane(width: width, height: height)
            let mat = SCNMaterial()
            mat.diffuse.contents = image
            mat.isDoubleSided = true
            mat.lightingModel = .constant
            mat.writesToDepthBuffer = false
            plane.materials = [mat]
            let node = SCNNode(geometry: plane)
            node.constraints = [SCNBillboardConstraint()]
            node.name = "label"
            return node
        }

        private static func renderLabelImage(_ text: String) -> NSImage {
            let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            let padding: CGFloat = 10
            let imgSize = NSSize(width: ceil(size.width + padding * 2), height: ceil(size.height + padding * 1.2))
            let image = NSImage(size: imgSize)
            image.lockFocus()
            let bg = NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: imgSize),
                xRadius: 6,
                yRadius: 6
            )
            NSColor.black.withAlphaComponent(0.72).setFill()
            bg.fill()
            (text as NSString).draw(
                at: NSPoint(x: padding, y: padding * 0.45),
                withAttributes: attrs
            )
            image.unlockFocus()
            return image
        }

        private func refreshLinks(in root: SCNNode, layout: ForceLayout3D) {
            root.childNodes.filter { $0.name?.hasPrefix("link:") == true }.forEach {
                $0.removeFromParentNode()
            }
            for link in graph.links {
                guard let a = layout.positions[link.source], let b = layout.positions[link.target]
                else { continue }
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
                let s: CGFloat = selected ? 1.35 : 1.0
                node.scale = SCNVector3(s, s, s)
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view else { return }
            let p = gesture.location(in: view)
            let hits = view.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            for hit in hits {
                var n: SCNNode? = hit.node
                while let cur = n {
                    if let name = cur.name, nodeMap[name] != nil {
                        onSelect(name)
                        return
                    }
                    n = cur.parent
                }
            }
            onSelect(nil)
        }
    }
}

/// SCNView that reports hover + ⌘+scroll for zoom (like agents-holding).
final class HoverSCNView: SCNView {
    var onHoverChange: ((Bool) -> Void)?
    var onCommandScroll: ((CGFloat) -> Void)?
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    private func installMonitor() {
        removeMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window != nil else { return event }
            // Only when pointer is over this view
            let loc = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(loc) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), !flags.contains(.control) else { return event }
            let dy = event.scrollingDeltaY
            if abs(dy) > 0.1 {
                self.onCommandScroll?(dy)
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    deinit { removeMonitor() }
}
