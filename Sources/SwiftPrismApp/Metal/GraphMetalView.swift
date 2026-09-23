import AppKit
import Metal
import MetalKit
import QuartzCore
import SwiftUI
import simd

extension Notification.Name {
    static let graphFitAll = Notification.Name("codeprism.graph.fitAll")
}

/// GPU (Metal) graph view — instanced point sprites + line list. Avoids SceneKit node churn.
struct GraphMetalView: NSViewRepresentable {
    var document: GraphDocument
    var selectedId: String?
    var zoom: CGFloat
    var onSelect: (String?) -> Void
    var onZoomChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onZoomChange: onZoomChange)
    }

    func makeNSView(context: Context) -> GraphMetalHostView {
        let view = GraphMetalHostView(frame: .zero)
        context.coordinator.attach(host: view)
        context.coordinator.apply(
            document: document,
            selectedId: selectedId,
            zoom: zoom,
            forceRebuild: true
        )
        return view
    }

    func updateNSView(_ nsView: GraphMetalHostView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onZoomChange = onZoomChange
        context.coordinator.apply(
            document: document,
            selectedId: selectedId,
            zoom: zoom,
            forceRebuild: false
        )
    }

    final class Coordinator {
        var onSelect: (String?) -> Void
        var onZoomChange: (CGFloat) -> Void
        private weak var host: GraphMetalHostView?
        private var signature = ""
        private var externalZoom: CGFloat = 1
        private var publishZoomWork: DispatchWorkItem?
        /// Ignore model→view zoom pushes briefly after a gesture (prevents feedback lag).
        private var ignoreModelZoomUntil: CFTimeInterval = 0

        init(onSelect: @escaping (String?) -> Void, onZoomChange: @escaping (CGFloat) -> Void) {
            self.onSelect = onSelect
            self.onZoomChange = onZoomChange
        }

        func attach(host: GraphMetalHostView) {
            self.host = host
            host.onSelect = { [weak self] id in self?.onSelect(id) }
            // Zoom stays on the Metal view during the gesture — SwiftUI only gets a throttled sync.
            host.onZoomDelta = { [weak self] factor in
                guard let self else { return }
                self.host?.nudgeZoomLocal(factor: factor)
                self.externalZoom = CGFloat(self.host?.currentZoom ?? Float(self.externalZoom))
                self.ignoreModelZoomUntil = CACurrentMediaTime() + 0.2
                self.schedulePublishZoom()
            }
            host.onFocusRequest = { [weak self] in
                self?.host?.focusOnSelection(suggestedZoom: max(self?.externalZoom ?? 1, 12))
            }
            host.onFitAll = { [weak self] zoom in
                guard let self else { return }
                self.externalZoom = zoom
                self.ignoreModelZoomUntil = CACurrentMediaTime() + 0.2
                self.onZoomChange(zoom)
            }
        }

        private func schedulePublishZoom() {
            publishZoomWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.onZoomChange(self.externalZoom)
            }
            publishZoomWork = work
            // Toolbar % updates after the finger settles — not every scroll tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        func apply(document: GraphDocument, selectedId: String?, zoom: CGFloat, forceRebuild: Bool) {
            let sig =
                "\(document.nodes.count)|\(document.links.count)|\(document.generatedAt)|\(document.projectRoot)"
            if CACurrentMediaTime() >= ignoreModelZoomUntil,
               abs(zoom - externalZoom) > 0.001
            {
                externalZoom = zoom
                host?.setZoom(zoom)
            }
            let selectionChanged = host?.rendererSelectedId != selectedId
            host?.setSelectedId(selectedId)
            // Auto-frame newly selected node so zoom/orbit inspects it, not the cloud center.
            if selectionChanged, let selectedId {
                host?.focusOnNode(id: selectedId, suggestedZoom: 0, bumpZoom: zoom < 2.5)
            }
            if forceRebuild || sig != signature {
                signature = sig
                host?.load(document: document)
            }
        }
    }
}

// MARK: - Host view (gestures + MTKView)

final class GraphMetalHostView: NSView {
    var onSelect: ((String?) -> Void)?
    /// Multiplicative zoom factor for one gesture step (e.g. 1.08).
    var onZoomDelta: ((CGFloat) -> Void)?
    var onFocusRequest: (() -> Void)?
    /// Absolute zoom after Fit All (usually ~1).
    var onFitAll: ((CGFloat) -> Void)?

    private var metalView: MTKView!
    private var renderer: GraphMetalRenderer!
    private var scrollMonitor: Any?
    private var lastDrag: NSPoint?
    private var didDrag = false
    private var lastGestureMagnification: CGFloat = 0
    private var lastClickTime: TimeInterval = 0

    var rendererSelectedId: String? { renderer?.selectedId }
    var currentZoom: Float { renderer?.zoom ?? 1 }

    func focusOnSelection(suggestedZoom: CGFloat) {
        guard let id = renderer?.selectedId else { return }
        focusOnNode(id: id, suggestedZoom: suggestedZoom, bumpZoom: true)
    }

    func focusOnNode(id: String, suggestedZoom: CGFloat, bumpZoom: Bool = true) {
        let inspectZoom = renderer?.focus(on: id) ?? 8
        wakeRender()
        guard bumpZoom else { return }
        let target = suggestedZoom > 1 ? suggestedZoom : CGFloat(inspectZoom)
        let current = max(CGFloat(renderer?.zoom ?? 1), 0.35)
        if current < target * 0.85 {
            nudgeZoomLocal(factor: target / current)
            onFitAll?(CGFloat(currentZoom)) // absolute publish for toolbar %
        }
    }

    /// Apply zoom on the GPU camera immediately — do not round-trip through SwiftUI each tick.
    func nudgeZoomLocal(factor: CGFloat) {
        renderer?.nudgeZoom(factor: Float(factor))
        wakeRender(fps: 60)
    }

    func pullFocusHome(strength: Float) {
        renderer?.pullFocusHome(strength: strength)
        wakeRender()
    }

    func ensureInspectPivot() {
        renderer?.ensureInspectPivot(force: true)
        wakeRender()
    }

    func fitAll() {
        let zoom = renderer?.fitAll() ?? 1
        onFitAll?(CGFloat(zoom))
        wakeRender()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupMetal()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupMetal()
        setupGestures()
    }

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }
        let mtk = MTKView(frame: bounds, device: device)
        mtk.autoresizingMask = [.width, .height]
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.depthStencilPixelFormat = .depth32Float
        mtk.clearColor = MTLClearColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        // Start paused — renderer resumes only while orbiting / settling layout.
        mtk.isPaused = true
        mtk.enableSetNeedsDisplay = true
        mtk.preferredFramesPerSecond = 30
        addSubview(mtk)
        metalView = mtk
        renderer = GraphMetalRenderer(device: device, view: mtk)
        mtk.delegate = renderer
    }

    private func setupGestures() {
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        addGestureRecognizer(click)
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    func load(document: GraphDocument) {
        renderer?.rebuild(document: document)
        wakeRender()
    }

    func setZoom(_ zoom: CGFloat) {
        let z = Float(zoom)
        guard abs((renderer?.zoom ?? z) - z) > 0.0005 else { return }
        renderer?.zoom = z
        wakeRender()
    }

    func setSelectedId(_ id: String?) {
        guard renderer?.selectedId != id else { return }
        renderer?.selectedId = id
        renderer?.refreshSelectionColors()
        wakeRender()
    }

    private func wakeRender(fps: Int = 30) {
        metalView?.isPaused = false
        metalView?.preferredFramesPerSecond = fps
        metalView?.setNeedsDisplay(metalView.bounds)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            installScrollMonitor()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFitAllNote(_:)),
                name: .graphFitAll,
                object: nil
            )
        } else {
            removeScrollMonitor()
            NotificationCenter.default.removeObserver(self, name: .graphFitAll, object: nil)
        }
    }

    @objc private func handleFitAllNote(_ note: Notification) {
        fitAll()
    }

    override func mouseDown(with event: NSEvent) {
        lastDrag = convert(event.locationInWindow, from: nil)
        didDrag = false
        wakeRender()
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let last = lastDrag {
            let dx = Float(loc.x - last.x)
            let dy = Float(loc.y - last.y)
            if abs(dx) + abs(dy) > 0.5 { didDrag = true }
            wakeRender()
            renderer?.orbit(dx: dx, dy: -dy)
        }
        lastDrag = loc
    }

    override func mouseUp(with event: NSEvent) {
        lastDrag = nil
        renderer?.endOrbit()
    }

    override func magnify(with event: NSEvent) {
        let m = event.magnification
        if abs(m) > 0.0005 {
            onZoomDelta?(max(0.85, min(1.18, 1 + m * 1.1)))
        }
    }

    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastGestureMagnification = 0
            wakeRender(fps: 60)
        case .changed:
            let delta = gesture.magnification - lastGestureMagnification
            lastGestureMagnification = gesture.magnification
            if abs(delta) > 0.0005 {
                // Smaller steps → fewer SwiftUI syncs feel smoother under trackpad flood.
                onZoomDelta?(max(0.88, min(1.14, 1 + delta * 1.05)))
            }
        case .ended, .cancelled:
            lastGestureMagnification = 0
            metalView?.preferredFramesPerSecond = 30
        default:
            lastGestureMagnification = 0
        }
    }

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard !didDrag else {
            didDrag = false
            return
        }
        let p = gesture.location(in: self)
        if let id = renderer?.pickNode(at: p, in: bounds) {
            onSelect?(id)
        } else {
            onSelect?(nil)
        }
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        guard !didDrag else { return }
        let p = gesture.location(in: self)
        if let id = renderer?.pickNode(at: p, in: bounds) {
            onSelect?(id)
            focusOnNode(id: id, suggestedZoom: 0, bumpZoom: true)
        } else {
            // Double-click empty space → reset focus to graph center (keep zoom).
            fitAll()
        }
    }

    private func installScrollMonitor() {
        removeScrollMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window != nil else { return event }
            let loc = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(loc) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Plain two-finger scroll OR ⌘+scroll zooms (⌃+scroll left to system).
            if flags.contains(.control) { return event }
            let dy = event.scrollingDeltaY
            if abs(dy) > 0.05 {
                // Trackpad floods scroll events — keep steps tiny; zoom is applied locally.
                let step: CGFloat = abs(dy) < 1.5 ? 1.04 : 1.10
                self.onZoomDelta?(dy > 0 ? step : 1 / step)
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    deinit {
        removeScrollMonitor()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Renderer

private struct GPUNode {
    var position: SIMD3<Float>
    var size: Float
    var color: SIMD4<Float>
}

private struct GPULine {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

private struct GPUUniforms {
    var viewProjection: simd_float4x4
    var viewport: SIMD2<Float>
    var pointScale: Float
    var _pad: Float = 0
}

final class GraphMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var nodePipeline: MTLRenderPipelineState?
    private var linePipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var pipelineError: String?

    private var nodeBuffer: MTLBuffer?
    private var lineBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?

    private var nodeCount = 0
    private var lineVertexCount = 0
    private var nodeIds: [String] = []
    private var positions: [SIMD3<Float>] = []
    private var flavors: [String] = []
    private var linkPairs: [(Int, Int, String)] = []

    private var layout: ForceLayout3D?
    private var layoutWorkItem: DispatchWorkItem?
    private weak var metalView: MTKView?
    private var layoutSettling = false
    private var islandCenters: [(name: String, center: SIMD3<Float>, nodeCount: Int)] = []
    private var islandOf: [String: String] = [:]

    var selectedId: String?
    var zoom: Float = 1 {
        didSet { updateCameraDistance() }
    }

    private var yaw: Float = 0.55
    private var pitch: Float = 0.35
    private var yawVel: Float = 0
    private var pitchVel: Float = 0
    private var dragging = false
    private var radius: Float = 16
    /// Distance at zoom == 1 that frames the whole graph.
    private var fitRadius: Float = 80
    private let minInspectRadius: Float = 2.8
    private let maxOverviewMul: Float = 2.2
    /// Orbit pivot — content centroid by default; jumps to a node when focusing.
    private var focusCenter: SIMD3<Float> = .zero
    private var contentCentroid: SIMD3<Float> = .zero
    private var lastTick = CACurrentMediaTime()

    init(device: MTLDevice, view: MTKView) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.metalView = view
        super.init()
        buildPipelines(view: view)
        uniformBuffer = device.makeBuffer(length: MemoryLayout<GPUUniforms>.stride, options: [.storageModeShared])
    }

    private func requestFrames() {
        metalView?.isPaused = false
        metalView?.preferredFramesPerSecond = 30
    }

    private func pauseIfIdle() {
        let spinning = abs(yawVel) > 0.00008 || abs(pitchVel) > 0.00008
        if !dragging && !spinning && !layoutSettling {
            metalView?.isPaused = true
        }
    }

    private func buildPipelines(view: MTKView) {
        // Runtime-compile shaders so the app builds without the Xcode Metal toolchain component.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: GraphShaderSource.metal, options: nil)
        } catch {
            pipelineError = "Metal shader compile failed: \(error)"
            return
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        desc.depthAttachmentPixelFormat = .depth32Float

        do {
            desc.vertexFunction = library.makeFunction(name: "node_vertex")
            desc.fragmentFunction = library.makeFunction(name: "node_fragment")
            nodePipeline = try device.makeRenderPipelineState(descriptor: desc)

            desc.vertexFunction = library.makeFunction(name: "line_vertex")
            desc.fragmentFunction = library.makeFunction(name: "line_fragment")
            linePipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            pipelineError = "Metal pipeline failed: \(error)"
            return
        }

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)
    }

    func rebuild(document: GraphDocument) {
        layoutWorkItem?.cancel()
        layoutSettling = true
        requestFrames()

        // Island layout + buffer packing stay off the main thread.
        let nodesSnapshot = document.nodes
        let linksSnapshot = document.links
        let projectRoot = document.projectRoot
        let selected = selectedId
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = nodesSnapshot.map(\.id)
            let flavorsLocal = nodesSnapshot.map(\.flavor)
            let idToIndex = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            let pairs: [(Int, Int, String)] = linksSnapshot.compactMap { link in
                guard let a = idToIndex[link.source], let b = idToIndex[link.target] else { return nil }
                return (a, b, link.kind)
            }
            let n = max(ids.count, 1)
            let warm = n > 800 ? 8 : (n > 300 ? 16 : 36)
            let settle = n > 400 ? 18 : 28
            // Each top-level project/folder = one island (mpm, libraries, projects/…, …).
            let islanded = IslandLayout.layout(
                nodes: nodesSnapshot,
                links: linksSnapshot,
                projectRoot: projectRoot,
                warmSteps: warm,
                settleSteps: settle
            )
            if work.isCancelled { return }

            var finalPos = ids.map { islanded.positions[$0] ?? .zero }
            // Drop every edge that touches an ungrouped/loose pile — kept as a quiet language heap.
            var scopedPairs: [(Int, Int, String)] = pairs.compactMap { a, b, kind in
                let left = islanded.scopeOf[ids[a]]
                let right = islanded.scopeOf[ids[b]]
                if left?.isLoose == true || right?.isLoose == true { return nil }
                let leftIsland = islanded.islandOf[ids[a]] ?? ""
                let rightIsland = islanded.islandOf[ids[b]] ?? ""
                if leftIsland.hasPrefix("ungrouped") || rightIsland.hasPrefix("ungrouped") {
                    return nil
                }
                guard let left, let right else { return (a, b, kind) }
                if left.file == right.file && left.archipelago == right.archipelago {
                    return (a, b, "inner")
                }
                if left.archipelago == right.archipelago && left.region == right.region {
                    return (a, b, "arch")
                }
                if left.region == right.region { return (a, b, "region") }
                return (a, b, "outer")
            }
            for link in linksSnapshot where link.kind == "depends" || link.target.hasPrefix("island:") {
                guard let source = idToIndex[link.source] else { continue }
                let island = link.target.replacingOccurrences(of: "island:", with: "")
                let members = ids.indices.filter { i in
                    let group = nodesSnapshot[i].group
                    return group == island || group.hasPrefix(island + " / ")
                }
                guard !members.isEmpty else { continue }
                var center = SIMD3<Float>(repeating: 0)
                for i in members { center += finalPos[i] }
                center /= Float(members.count)
                finalPos.append(center)
                scopedPairs.append((source, finalPos.count - 1, "outer"))
            }
            let pack = self.packGPU(
                ids: ids,
                flavors: flavorsLocal,
                positions: finalPos,
                linkPairs: scopedPairs,
                selectedId: selected
            )
            DispatchQueue.main.async {
                guard !work.isCancelled else { return }
                self.nodeIds = ids
                self.flavors = flavorsLocal
                self.linkPairs = scopedPairs
                self.layout = nil
                self.positions = finalPos
                self.islandCenters = islanded.islandCenters
                self.islandOf = islanded.islandOf
                self.applyPackedGPU(pack)
                self.layoutSettling = false
                // After islands land, snap to overview so the whole company is visible.
                NotificationCenter.default.post(name: .graphFitAll, object: nil)
                self.pauseIfIdle()
            }
        }
        layoutWorkItem = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    func refreshSelectionColors() {
        let ids = nodeIds
        let flavorsLocal = flavors
        let pos = positions
        let pairs = linkPairs
        let selected = selectedId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let pack = self.packGPU(
                ids: ids,
                flavors: flavorsLocal,
                positions: pos,
                linkPairs: pairs,
                selectedId: selected
            )
            DispatchQueue.main.async {
                self.applyPackedGPU(pack)
                self.requestFrames()
                self.pauseIfIdle()
            }
        }
    }

    private struct PackedGPU {
        var nodeBuffer: MTLBuffer?
        var lineBuffer: MTLBuffer?
        var nodeCount: Int
        var lineVertexCount: Int
    }

    private func packGPU(
        ids: [String],
        flavors: [String],
        positions: [SIMD3<Float>],
        linkPairs: [(Int, Int, String)],
        selectedId: String?
    ) -> PackedGPU {
        guard !ids.isEmpty else {
            return PackedGPU(nodeBuffer: nil, lineBuffer: nil, nodeCount: 0, lineVertexCount: 0)
        }
        var nodes: [GPUNode] = []
        nodes.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() {
            let p = i < positions.count ? positions[i] : .zero
            let flavor = i < flavors.count ? flavors[i] : "type"
            let selected = id == selectedId
            var c = color(for: flavor)
            if selected { c = SIMD4(1, 0.9, 0.2, 1) }
            let size = selected ? size(for: flavor) * 1.45 : size(for: flavor)
            nodes.append(GPUNode(position: p, size: size, color: c))
        }
        let nodeBuf = device.makeBuffer(
            bytes: nodes,
            length: MemoryLayout<GPUNode>.stride * nodes.count,
            options: [.storageModeShared]
        )

        var lines: [GPULine] = []
        lines.reserveCapacity(min(linkPairs.count, 20_000) * 2)
        let maxLinks = 20_000
        for (idx, pair) in linkPairs.enumerated() {
            if idx >= maxLinks { break }
            let (a, b, kind) = pair
            guard a < positions.count, b < positions.count else { continue }
            let col: SIMD4<Float> = switch kind {
            case "inner", "call": SIMD4(0.24, 0.78, 1.0, 0.7)
            case "arch": SIMD4(0.24, 0.78, 1.0, 0.45)
            case "region": SIMD4(0.75, 0.52, 0.98, 0.7)
            case "outer": SIMD4(1.0, 0.62, 0.26, 0.75)
            default: SIMD4(0.55, 0.55, 0.58, 0.35)
            }
            lines.append(GPULine(position: positions[a], color: col))
            lines.append(GPULine(position: positions[b], color: col))
        }
        let lineBuf: MTLBuffer? =
            lines.isEmpty
            ? nil
            : device.makeBuffer(
                bytes: lines,
                length: MemoryLayout<GPULine>.stride * lines.count,
                options: [.storageModeShared]
            )
        return PackedGPU(
            nodeBuffer: nodeBuf,
            lineBuffer: lineBuf,
            nodeCount: nodes.count,
            lineVertexCount: lines.count
        )
    }

    private func applyPackedGPU(_ pack: PackedGPU) {
        nodeBuffer = pack.nodeBuffer
        lineBuffer = pack.lineBuffer
        nodeCount = pack.nodeCount
        lineVertexCount = pack.lineVertexCount
        requestFrames()
    }

    private func updateCameraDistance() {
        // zoom 1 → fitRadius (full overview); zoom up → closer inspect; zoom down → wider.
        let z = max(zoom, 0.05)
        radius = min(fitRadius * maxOverviewMul, max(minInspectRadius, fitRadius / z))
    }

    /// True while the look-at is still the empty middle of the archipelago.
    private var isOnOverviewPivot: Bool {
        let slack = max(fitRadius * 0.1, 25)
        return length(focusCenter - contentCentroid) < slack
    }

    /// Gesture zoom — cheap camera update only (no buffer rebuild).
    func nudgeZoom(factor: Float) {
        let f = max(0.85, min(1.18, factor))
        if f < 1 {
            pullFocusHome(strength: 1 - f)
        } else if isOnOverviewPivot {
            // Archipelagos leave a void at the centroid — snap onto a real island/node
            // BEFORE dollying in, or the whole graph flies off-screen.
            ensureInspectPivot(force: true)
        }
        zoom = min(40, max(0.35, zoom * f))
        updateCameraDistance()
        requestFrames()
    }

    private func recomputeFitRadius() {
        guard !positions.isEmpty else {
            fitRadius = 48
            contentCentroid = .zero
            return
        }
        var mn = positions[0]
        var mx = positions[0]
        for p in positions {
            mn = simd_min(mn, p)
            mx = simd_max(mx, p)
        }
        contentCentroid = (mn + mx) * 0.5
        let half = (mx - mn) * 0.5
        let sphereR = max(length(half), 10)
        let fovY: Float = 55 * .pi / 180
        // Extra margin so outermost islands aren't clipped at zoom == 1.
        fitRadius = sphereR / max(tan(fovY * 0.5), 0.01) * 1.55
    }

    /// Returns recommended inspect zoom (fitRadius / ~5.5).
    @discardableResult
    func focus(on id: String) -> Float {
        guard let idx = nodeIds.firstIndex(of: id), idx < positions.count else { return zoom }
        focusCenter = positions[idx]
        selectedId = id
        if fitRadius < 8 { recomputeFitRadius() }
        let targetR: Float = 5.5
        let inspectZoom = min(40, max(2.5, fitRadius / targetR))
        requestFrames()
        return inspectZoom
    }

    func clearFocus() {
        focusCenter = contentCentroid
        requestFrames()
    }

    /// While zooming out, ease the orbit pivot back to the content center.
    func pullFocusHome(strength: Float) {
        let t = min(max(strength * 1.8, 0), 0.6)
        focusCenter = focusCenter + (contentCentroid - focusCenter) * t
        if length_squared(focusCenter - contentCentroid) < 4 {
            focusCenter = contentCentroid
        }
        requestFrames()
    }

    /// Jump look-at onto selected node, largest island, or nearest real node.
    func ensureInspectPivot(force: Bool = false) {
        if !force && !isOnOverviewPivot { return }
        if let sel = selectedId, let idx = nodeIds.firstIndex(of: sel), idx < positions.count {
            focusCenter = positions[idx]
            requestFrames()
            return
        }
        if let best = islandCenters.max(by: { $0.nodeCount < $1.nodeCount }) {
            focusCenter = best.center
            requestFrames()
            return
        }
        // Fallback: node closest to current pivot / centroid (never stay in the void).
        guard !positions.isEmpty else { return }
        let origin = focusCenter
        var best = positions[0]
        var bestD = length_squared(best - origin)
        for p in positions {
            let d = length_squared(p - origin)
            if d < bestD {
                bestD = d
                best = p
            }
        }
        focusCenter = best
        requestFrames()
    }

    /// Frame every island: pivot at content center, zoom 1 = full overview.
    @discardableResult
    func fitAll() -> Float {
        recomputeFitRadius()
        focusCenter = contentCentroid
        zoom = 1
        updateCameraDistance()
        requestFrames()
        return 1
    }

    func orbit(dx: Float, dy: Float) {
        dragging = true
        requestFrames()
        let sens: Float = 0.0055
        yaw += dx * sens
        pitch = min(max(pitch + dy * sens, -1.2), 1.35)
        yawVel = dx * sens * 1.2
        pitchVel = dy * sens * 1.2
    }

    func endOrbit() {
        dragging = false
        yawVel = min(max(yawVel, -0.25), 0.25)
        pitchVel = min(max(pitchVel, -0.25), 0.25)
        // Keep a few frames for inertia, then pauseIfIdle in draw().
        requestFrames()
    }

    private func color(for flavor: String) -> SIMD4<Float> {
        switch flavor.lowercased() {
        case "class", "actor": return SIMD4(0.2, 0.45, 1.0, 1)
        case "struct", "enum": return SIMD4(0.15, 0.75, 0.75, 1)
        case "protocol": return SIMD4(0.65, 0.3, 0.95, 1)
        case "function", "member": return SIMD4(0.25, 0.8, 0.35, 1)
        case "variable": return SIMD4(1.0, 0.55, 0.15, 1)
        case "target", "entry_point": return SIMD4(0.6, 0.6, 0.65, 1)
        case "external": return SIMD4(0.95, 0.85, 0.2, 0.9)
        default: return SIMD4(0.45, 0.4, 0.95, 1)
        }
    }

    private func size(for flavor: String) -> Float {
        switch flavor.lowercased() {
        case "class", "actor", "struct", "enum", "protocol": return 1.15
        case "function", "member": return 0.75
        case "variable": return 0.55
        case "target": return 1.5
        default: return 0.85
        }
    }

    private func viewProjection(aspect: Float) -> simd_float4x4 {
        let eye = cameraEye()
        let view = lookAt(eye: eye, center: focusCenter, up: SIMD3(0, 1, 0))
        // Tiny near plane when close so focused nodes aren't clipped away.
        let near: Float = max(0.01, min(0.35, radius * 0.004))
        let far: Float = max(3_000, max(radius, fitRadius) * 50)
        let proj = perspective(fovY: 55 * .pi / 180, aspect: aspect, near: near, far: far)
        return proj * view
    }

    private func cameraEye() -> SIMD3<Float> {
        let cp = cos(pitch), sp = sin(pitch)
        let cy = cos(yaw), sy = sin(yaw)
        // Orbit around focusCenter (selected node or graph origin).
        let offset = SIMD3(radius * cp * sy, radius * sp, radius * cp * cy)
        return focusCenter + offset
    }

    func pickNode(at point: NSPoint, in bounds: CGRect) -> String? {
        guard !nodeIds.isEmpty, bounds.width > 1, bounds.height > 1 else { return nil }
        let aspect = Float(bounds.width / bounds.height)
        let mvp = viewProjection(aspect: aspect)
        var best: (String, CGFloat)?
        // NSView coords: origin bottom-left (not flipped) — matches NDC y mapping below.
        let target = point
        for (i, id) in nodeIds.enumerated() {
            guard i < positions.count else { continue }
            let clip = mvp * SIMD4<Float>(positions[i].x, positions[i].y, positions[i].z, 1)
            guard abs(clip.w) > 0.0001 else { continue }
            let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
            if ndc.z < -1 || ndc.z > 1 { continue }
            let sx = CGFloat((ndc.x * 0.5 + 0.5) * Float(bounds.width))
            let sy = CGFloat((ndc.y * 0.5 + 0.5) * Float(bounds.height))
            let dx = sx - target.x
            let dy = sy - target.y
            let d2 = dx * dx + dy * dy
            let hitR: CGFloat = id == selectedId ? 22 : 14
            if d2 <= hitR * hitR {
                if best == nil || d2 < best!.1 {
                    best = (id, d2)
                }
            }
        }
        return best?.0
    }

    func draw(in view: MTKView) {
        // Inertia
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTick, 1.0 / 240.0), 1.0 / 20.0))
        lastTick = now
        if !dragging {
            if abs(yawVel) > 0.00002 || abs(pitchVel) > 0.00002 {
                yaw += yawVel * dt
                pitch = min(max(pitch + pitchVel * dt, -1.2), 1.35)
                let damp = exp(-10.0 * dt)
                yawVel *= damp
                pitchVel *= damp
                if abs(yawVel) < 0.00008 { yawVel = 0 }
                if abs(pitchVel) < 0.00008 { pitchVel = 0 }
            }
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let ub = uniformBuffer
        else {
            pauseIfIdle()
            return
        }

        let w = Float(view.drawableSize.width)
        let h = max(Float(view.drawableSize.height), 1)
        // Keep dots visible in overview; shrink sprites when very close.
        let pointScale = min(2.8, max(0.7, radius / max(fitRadius * 0.35, 1)))
        var uniforms = GPUUniforms(
            viewProjection: viewProjection(aspect: w / h),
            viewport: SIMD2(w, h),
            pointScale: pointScale
        )
        memcpy(ub.contents(), &uniforms, MemoryLayout<GPUUniforms>.stride)

        guard let nodePipeline, let linePipeline, let depthState else {
            pauseIfIdle()
            return
        }
        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setDepthStencilState(depthState)

        if lineVertexCount > 0, let lineBuffer {
            enc.setRenderPipelineState(linePipeline)
            enc.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(ub, offset: 0, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineVertexCount)
        }

        if nodeCount > 0, let nodeBuffer {
            enc.setRenderPipelineState(nodePipeline)
            enc.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(ub, offset: 0, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: nodeCount)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        pauseIfIdle()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// MARK: - Math

private func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / aspect
    let zRange = far - near
    return simd_float4x4(columns: (
        SIMD4(x, 0, 0, 0),
        SIMD4(0, y, 0, 0),
        SIMD4(0, 0, -(far + near) / zRange, -1),
        SIMD4(0, 0, -2 * far * near / zRange, 0)
    ))
}

private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = normalize(eye - center)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    let t = SIMD3(-dot(x, eye), -dot(y, eye), -dot(z, eye))
    return simd_float4x4(columns: (
        SIMD4(x.x, y.x, z.x, 0),
        SIMD4(x.y, y.y, z.y, 0),
        SIMD4(x.z, y.z, z.z, 0),
        SIMD4(t.x, t.y, t.z, 1)
    ))
}
