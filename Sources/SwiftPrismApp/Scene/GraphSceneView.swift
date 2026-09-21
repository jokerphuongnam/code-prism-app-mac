import AppKit
import QuartzCore
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
        // Custom orbit — default SceneKit control feels sticky/jumpy with our zoom.
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        context.coordinator.view = view
        view.onHoverChange = { context.coordinator.isHovered = $0 }
        view.onCommandScroll = { delta in
            context.coordinator.nudgeZoomFromScroll(delta)
        }
        view.onOrbitDrag = { dx, dy, ended in
            context.coordinator.handleOrbitDrag(dx: dx, dy: dy, ended: ended)
        }

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        // Require click not to steal drags — use button mask / delay
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)

        context.coordinator.rebuild(document: document, selectedId: selectedId, zoom: zoom)
        context.coordinator.startDisplayLink()
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
            hover.onOrbitDrag = { dx, dy, ended in
                context.coordinator.handleOrbitDrag(dx: dx, dy: dy, ended: ended)
            }
        }
        if context.coordinator.documentSignature != documentSignature(document) {
            context.coordinator.rebuild(document: document, selectedId: selectedId, zoom: zoom)
        } else {
            context.coordinator.updateSelection(selectedId)
            context.coordinator.targetZoom = zoom
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
        var targetZoom: CGFloat = 1

        private var nodeMap: [String: SCNNode] = [:]
        private var layout: ForceLayout3D?
        private var layoutTimer: Timer?
        private var displayLink: CVDisplayLink?
        private var graph: GraphDocument = .empty
        private weak var cameraNode: SCNNode?
        private weak var pivotNode: SCNNode?
        private weak var graphRoot: SCNNode?
        private var baseCameraDistance: Float = 16
        private var selectedId: String?
        private var visibleIds: Set<String> = []
        private var nodeById: [String: GraphNode] = [:]
        private var cullFrameCounter = 0
        /// Max SceneKit node instances mounted for the current frustum.
        private let maxBufferedNodes = 320
        /// Labels only when the viewport is sparse enough (billboards are expensive).
        private let maxLabeledNodes = 56
        private let viewportMargin: CGFloat = 96

        // Orbit state (radians). Drag sticks to mouse; light inertia on release.
        private var yaw: Float = 0.55
        private var pitch: Float = 0.35
        private var yawVel: Float = 0
        private var pitchVel: Float = 0
        private var smoothRadius: Float = 16
        private var dragging = false
        private var lastTickTime: CFTimeInterval = 0
        private var lastDragSampleTime: CFTimeInterval = 0
        private var isTickScheduled = false
        private let tickLock = NSLock()

        /// Radians per pixel — tuned for trackpad + mouse.
        private let orbitSensitivity: Float = 0.0055
        /// Per-second exponential damping while coasting (~halves every ~80ms).
        private let inertiaDampingPerSecond: Float = 8.5
        private let radiusLerpPerSecond: Float = 12
        private let maxAngularSpeed: Float = 0.55
        private let velocityEMA: Float = 0.35

        init(onSelect: @escaping (String?) -> Void, onZoomChange: @escaping (CGFloat) -> Void) {
            self.onSelect = onSelect
            self.onZoomChange = onZoomChange
        }

        func nudgeZoomFromScroll(_ deltaY: CGFloat) {
            let factor: CGFloat = deltaY > 0 ? 1.08 : 0.92
            let next = min(max(externalZoom * factor, 0.35), 4.0)
            onZoomChange(next)
        }

        func handleOrbitDrag(dx: CGFloat, dy: CGFloat, ended: Bool) {
            let now = CACurrentMediaTime()
            if ended {
                dragging = false
                // Soft-cap leftover velocity so coast feels light, not a spin.
                yawVel = min(max(yawVel, -maxAngularSpeed * 0.45), maxAngularSpeed * 0.45)
                pitchVel = min(max(pitchVel, -maxAngularSpeed * 0.45), maxAngularSpeed * 0.45)
                lastDragSampleTime = 0
                return
            }
            dragging = true
            let dYaw = Float(dx) * orbitSensitivity
            let dPitch = Float(dy) * orbitSensitivity
            yaw += dYaw
            pitch = min(max(pitch + dPitch, -1.2), 1.35)

            // Time-based EMA velocity so inertia matches actual drag speed.
            let dt = lastDragSampleTime > 0 ? Float(now - lastDragSampleTime) : (1.0 / 60.0)
            lastDragSampleTime = now
            let safeDt = max(dt, 1.0 / 240.0)
            let instYaw = dYaw / safeDt
            let instPitch = dPitch / safeDt
            yawVel = yawVel * (1 - velocityEMA) + instYaw * velocityEMA
            pitchVel = pitchVel * (1 - velocityEMA) + instPitch * velocityEMA
            yawVel = min(max(yawVel, -maxAngularSpeed), maxAngularSpeed)
            pitchVel = min(max(pitchVel, -maxAngularSpeed), maxAngularSpeed)

            // Apply immediately while dragging — no rubber-band lag behind the cursor.
            applyCameraTransform(yaw: yaw, pitch: pitch, radius: smoothRadius)
            cullFrameCounter += 1
            if cullFrameCounter % 2 == 0 {
                syncVisibleBuffer(force: false)
            }
        }

        func startDisplayLink() {
            stopDisplayLink()
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else { return }
            displayLink = link
            lastTickTime = CACurrentMediaTime()
            let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
                guard let context else { return kCVReturnSuccess }
                let coord = Unmanaged<Coordinator>.fromOpaque(context).takeUnretainedValue()
                // Hop to main; coalesce so a busy main thread doesn't queue many frames.
                coord.scheduleCameraTick()
                return kCVReturnSuccess
            }
            CVDisplayLinkSetOutputCallback(
                link,
                callback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            CVDisplayLinkStart(link)
        }

        func stopDisplayLink() {
            if let displayLink {
                CVDisplayLinkStop(displayLink)
                self.displayLink = nil
            }
        }

        private func scheduleCameraTick() {
            tickLock.lock()
            let shouldEnqueue = !isTickScheduled
            if shouldEnqueue { isTickScheduled = true }
            tickLock.unlock()
            guard shouldEnqueue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tickCamera()
                self.tickLock.lock()
                self.isTickScheduled = false
                self.tickLock.unlock()
            }
        }

        private func tickCamera() {
            let now = CACurrentMediaTime()
            let dt = lastTickTime > 0 ? Float(now - lastTickTime) : (1.0 / 60.0)
            lastTickTime = now
            let safeDt = min(max(dt, 1.0 / 240.0), 1.0 / 20.0)

            if !dragging {
                if abs(yawVel) > 0.00002 || abs(pitchVel) > 0.00002 {
                    yaw += yawVel * safeDt
                    pitch = min(max(pitch + pitchVel * safeDt, -1.2), 1.35)
                    let damp = exp(-inertiaDampingPerSecond * safeDt)
                    yawVel *= damp
                    pitchVel *= damp
                    if abs(yawVel) < 0.00008 { yawVel = 0 }
                    if abs(pitchVel) < 0.00008 { pitchVel = 0 }
                }
            }

            let targetRadius = baseCameraDistance / Float(max(targetZoom, 0.2))
            let rAlpha = 1 - exp(-radiusLerpPerSecond * safeDt)
            smoothRadius += (targetRadius - smoothRadius) * rAlpha

            applyCameraTransform(yaw: yaw, pitch: pitch, radius: smoothRadius)
            // Orbit changes the frustum — refresh the visible node buffer.
            cullFrameCounter += 1
            if cullFrameCounter % 2 == 0 {
                syncVisibleBuffer(force: false)
            }
        }

        private func applyCameraTransform(yaw: Float, pitch: Float, radius: Float) {
            guard let pivot = pivotNode, let camera = cameraNode else { return }
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            pivot.eulerAngles = SCNVector3(pitch, yaw, 0)
            camera.position = SCNVector3(0, 0, radius)
            SCNTransaction.commit()
        }

        func rebuild(document: GraphDocument, selectedId: String?, zoom: CGFloat) {
            layoutTimer?.invalidate()
            graph = document
            self.selectedId = selectedId
            documentSignature =
                "\(document.nodes.count)|\(document.links.count)|\(document.generatedAt)|\(document.projectRoot)"
            externalZoom = zoom
            targetZoom = zoom
            visibleIds.removeAll(keepingCapacity: true)
            nodeMap.removeAll(keepingCapacity: true)
            nodeById = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })

            let scene = SCNScene()
            scene.background.contents = NSColor(calibratedWhite: 0.07, alpha: 1)

            // pivot → camera (smooth orbit)
            let pivot = SCNNode()
            pivot.name = "cameraPivot"
            let camera = SCNNode()
            camera.name = "camera"
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.05
            camera.camera?.zFar = 800
            camera.camera?.fieldOfView = 50
            let nCount = max(document.nodes.count, 1)
            baseCameraDistance = max(12, min(80, Float(nCount) * 0.22 + 10))
            smoothRadius = baseCameraDistance / Float(max(zoom, 0.2))
            camera.position = SCNVector3(0, 0, smoothRadius)
            pivot.addChildNode(camera)
            pivot.eulerAngles = SCNVector3(pitch, yaw, 0)
            scene.rootNode.addChildNode(pivot)
            pivotNode = pivot
            cameraNode = camera

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 520
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 950
            key.eulerAngles = SCNVector3(-0.55, 0.45, 0)
            scene.rootNode.addChildNode(key)

            let ids = document.nodes.map(\.id)
            let linkPairs = document.links.map { ($0.source, $0.target) }
            let force = ForceLayout3D(nodeIds: ids, links: linkPairs)
            force.linkDistance = nCount > 400 ? 3.4 : 4.2
            // O(n²) charge melts large graphs — disable above threshold.
            force.charge = nCount > 350 ? 0 : -42
            let warm = nCount > 500 ? 28 : (nCount > 200 ? 55 : 110)
            for _ in 0..<warm {
                _ = force.tick(1)
            }
            layout = force

            let root = SCNNode()
            root.name = "graphRoot"
            scene.rootNode.addChildNode(root)
            graphRoot = root

            view?.scene = scene
            view?.pointOfView = camera
            // Mount only what the camera can see (viewport buffer).
            syncVisibleBuffer(force: true)
            updateSelection(selectedId)

            var ticks = 0
            let maxTicks = nCount > 400 ? 40 : 100
            layoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
                guard let self, let layout = self.layout else {
                    t.invalidate()
                    return
                }
                let e = layout.tick(nCount > 400 ? 1 : 2)
                for (id, node) in self.nodeMap {
                    if let p = layout.positions[id] {
                        node.simdPosition = p
                    }
                }
                ticks += 1
                if ticks % 4 == 0 {
                    self.syncVisibleBuffer(force: false)
                }
                if e < 0.002 || ticks > maxTicks {
                    t.invalidate()
                    self.syncVisibleBuffer(force: true)
                }
            }

            if displayLink == nil {
                startDisplayLink()
            }
        }

        /// Keep only frustum-visible (and near) nodes mounted in SceneKit.
        private func syncVisibleBuffer(force: Bool) {
            guard let view, let layout, let root = graphRoot else { return }
            let bounds = view.bounds
            guard bounds.width > 1, bounds.height > 1 else { return }

            struct Cand {
                let id: String
                let screenDist2: CGFloat
                let camDist2: Float
                let pos: SIMD3<Float>
            }

            let cx = bounds.midX
            let cy = bounds.midY
            var candidates: [Cand] = []
            candidates.reserveCapacity(min(graph.nodes.count, maxBufferedNodes * 2))

            let camWorld = cameraNode?.worldPosition ?? SCNVector3(0, 0, smoothRadius)
            let camPos = SIMD3<Float>(Float(camWorld.x), Float(camWorld.y), Float(camWorld.z))

            for n in graph.nodes {
                guard let p = layout.positions[n.id] else { continue }
                let projected = view.projectPoint(SCNVector3(p.x, p.y, p.z))
                // SceneKit: z in (0, 1) ≈ in front of camera / in clip volume.
                let inDepth = projected.z > 0 && projected.z < 1
                let inXY =
                    projected.x >= -viewportMargin
                    && projected.x <= bounds.width + viewportMargin
                    && projected.y >= -viewportMargin
                    && projected.y <= bounds.height + viewportMargin
                if !(inDepth && inXY) { continue }
                let dx = projected.x - cx
                let dy = projected.y - cy
                let screenDist2 = dx * dx + dy * dy
                let delta = p - camPos
                let camDist2 = simd_length_squared(delta)
                candidates.append(Cand(id: n.id, screenDist2: screenDist2, camDist2: camDist2, pos: p))
            }

            // Prefer near-camera / center-of-screen when the frustum is dense.
            candidates.sort {
                if $0.camDist2 != $1.camDist2 { return $0.camDist2 < $1.camDist2 }
                return $0.screenDist2 < $1.screenDist2
            }
            if candidates.count > maxBufferedNodes {
                candidates = Array(candidates.prefix(maxBufferedNodes))
            }
            if let sel = selectedId, let p = layout.positions[sel], !candidates.contains(where: { $0.id == sel }) {
                candidates.insert(Cand(id: sel, screenDist2: 0, camDist2: 0, pos: p), at: 0)
                if candidates.count > maxBufferedNodes {
                    candidates = Array(candidates.prefix(maxBufferedNodes))
                }
            }

            let nextVisible = Set(candidates.map(\.id))
            if !force, nextVisible == visibleIds { return }

            let labeledBudget = Set(candidates.prefix(maxLabeledNodes).map(\.id)).union(
                selectedId.map { Set([$0]) } ?? []
            )

            // Remove nodes that left the buffer.
            for id in visibleIds.subtracting(nextVisible) {
                nodeMap[id]?.removeFromParentNode()
                nodeMap[id] = nil
            }

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            for cand in candidates {
                if let existing = nodeMap[cand.id] {
                    existing.simdPosition = cand.pos
                    continue
                }
                guard let meta = nodeById[cand.id] else { continue }
                let geo = NodeGeometry.makeGeometry(flavor: meta.flavor)
                let node = SCNNode(geometry: geo)
                node.name = meta.id
                node.simdPosition = cand.pos
                if labeledBudget.contains(meta.id) {
                    let label = makeBillboardLabel(shortName(meta.name))
                    label.position = SCNVector3(0, 0.55, 0)
                    node.addChildNode(label)
                }
                root.addChildNode(node)
                nodeMap[meta.id] = node
            }
            SCNTransaction.commit()

            visibleIds = nextVisible
            refreshVisibleLinks(in: root, layout: layout, visible: nextVisible)
            updateSelection(selectedId)
        }

        private func shortName(_ name: String) -> String {
            var s = name
            if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
                s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
            if s.count > 22 { return String(s.prefix(20)) + "…" }
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
            let imgSize = NSSize(
                width: ceil(size.width + padding * 2),
                height: ceil(size.height + padding * 1.2)
            )
            let image = NSImage(size: imgSize)
            image.lockFocus()
            let bg = NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: imgSize),
                xRadius: 6,
                yRadius: 6
            )
            NSColor.black.withAlphaComponent(0.72).setFill()
            bg.fill()
            (text as NSString).draw(at: NSPoint(x: padding, y: padding * 0.45), withAttributes: attrs)
            image.unlockFocus()
            return image
        }

        private func refreshVisibleLinks(
            in root: SCNNode,
            layout: ForceLayout3D,
            visible: Set<String>
        ) {
            root.childNodes.filter { $0.name?.hasPrefix("link:") == true }.forEach {
                $0.removeFromParentNode()
            }
            // Only edges touching the buffered viewport (keeps draw calls bounded).
            var drawn = 0
            let maxLinks = maxBufferedNodes * 3
            for link in graph.links {
                let aVisible = visible.contains(link.source)
                let bVisible = visible.contains(link.target)
                guard aVisible || bVisible else { continue }
                guard let a = layout.positions[link.source], let b = layout.positions[link.target]
                else { continue }
                let line = NodeGeometry.makeLinkNode(from: a, to: b, kind: link.kind)
                line.name = "link:\(link.id)"
                root.addChildNode(line)
                drawn += 1
                if drawn >= maxLinks { break }
            }
        }

        func updateSelection(_ selectedId: String?) {
            self.selectedId = selectedId
            if let selectedId, !visibleIds.contains(selectedId) {
                // Ensure selection is mounted even if outside the last frustum sample.
                syncVisibleBuffer(force: true)
            }
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
            // Ignore if this was part of a drag
            if let hover = view as? HoverSCNView, hover.didDrag {
                hover.didDrag = false
                return
            }
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

        deinit {
            stopDisplayLink()
            layoutTimer?.invalidate()
        }
    }
}

/// SCNView with smooth orbit drag + ⌘+scroll zoom.
final class HoverSCNView: SCNView {
    var onHoverChange: ((Bool) -> Void)?
    var onCommandScroll: ((CGFloat) -> Void)?
    var onOrbitDrag: ((CGFloat, CGFloat, Bool) -> Void)?
    private var scrollMonitor: Any?
    private var lastDrag: NSPoint?
    var didDrag = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installMonitor() } else { removeMonitor() }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        lastDrag = convert(event.locationInWindow, from: nil)
        didDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let last = lastDrag {
            let dx = loc.x - last.x
            let dy = loc.y - last.y
            if abs(dx) + abs(dy) > 0.5 { didDrag = true }
            // Invert Y so drag-up tilts up naturally
            onOrbitDrag?(dx, -dy, false)
        }
        lastDrag = loc
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func mouseUp(with event: NSEvent) {
        onOrbitDrag?(0, 0, true)
        lastDrag = nil
        super.mouseUp(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    private func installMonitor() {
        removeMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window != nil else { return event }
            let loc = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(loc) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), !flags.contains(.control) else { return event }
            let dy = event.scrollingDeltaY
            if abs(dy) > 0.1 { self.onCommandScroll?(dy) }
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
