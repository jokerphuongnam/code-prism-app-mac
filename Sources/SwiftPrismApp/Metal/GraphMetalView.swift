import AppKit
import Metal
import MetalKit
import QuartzCore
import SwiftUI
import simd

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

        init(onSelect: @escaping (String?) -> Void, onZoomChange: @escaping (CGFloat) -> Void) {
            self.onSelect = onSelect
            self.onZoomChange = onZoomChange
        }

        func attach(host: GraphMetalHostView) {
            self.host = host
            host.onSelect = { [weak self] id in self?.onSelect(id) }
            host.onZoomDelta = { [weak self] factor in
                guard let self else { return }
                let next = min(max(self.externalZoom * factor, 0.35), 4.0)
                self.externalZoom = next
                self.onZoomChange(next)
            }
        }

        func apply(document: GraphDocument, selectedId: String?, zoom: CGFloat, forceRebuild: Bool) {
            externalZoom = zoom
            let sig =
                "\(document.nodes.count)|\(document.links.count)|\(document.generatedAt)|\(document.projectRoot)"
            host?.setZoom(zoom)
            host?.setSelectedId(selectedId)
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

    private var metalView: MTKView!
    private var renderer: GraphMetalRenderer!
    private var scrollMonitor: Any?
    private var lastDrag: NSPoint?
    private var didDrag = false
    private var lastGestureMagnification: CGFloat = 0

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
        mtk.isPaused = false
        mtk.enableSetNeedsDisplay = false
        mtk.preferredFramesPerSecond = 60
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
    }

    func load(document: GraphDocument) {
        renderer?.rebuild(document: document)
    }

    func setZoom(_ zoom: CGFloat) {
        renderer?.zoom = Float(zoom)
    }

    func setSelectedId(_ id: String?) {
        renderer?.selectedId = id
        renderer?.refreshSelectionColors()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            installScrollMonitor()
        } else {
            removeScrollMonitor()
        }
    }

    override func mouseDown(with event: NSEvent) {
        lastDrag = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let last = lastDrag {
            let dx = Float(loc.x - last.x)
            let dy = Float(loc.y - last.y)
            if abs(dx) + abs(dy) > 0.5 { didDrag = true }
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
            onZoomDelta?(max(0.5, min(1.8, 1 + m * 1.45)))
        }
    }

    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastGestureMagnification = 0
        case .changed:
            let delta = gesture.magnification - lastGestureMagnification
            lastGestureMagnification = gesture.magnification
            if abs(delta) > 0.0005 {
                onZoomDelta?(max(0.5, min(1.8, 1 + delta * 1.45)))
            }
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

    private func installScrollMonitor() {
        removeScrollMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window != nil else { return event }
            let loc = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(loc) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), !flags.contains(.control) else { return event }
            let dy = event.scrollingDeltaY
            if abs(dy) > 0.1 {
                self.onZoomDelta?(dy > 0 ? 1.08 : 0.92)
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

    deinit { removeScrollMonitor() }
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
    private var nodePipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!

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
    private var baseDistance: Float = 16
    private var lastTick = CACurrentMediaTime()

    init(device: MTLDevice, view: MTKView) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        super.init()
        buildPipelines(view: view)
        uniformBuffer = device.makeBuffer(length: MemoryLayout<GPUUniforms>.stride, options: [.storageModeShared])
    }

    private func buildPipelines(view: MTKView) {
        // Runtime-compile shaders so the app builds without the Xcode Metal toolchain component.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: GraphShaderSource.metal, options: nil)
        } catch {
            fatalError("Metal shader compile failed: \(error)")
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

        desc.vertexFunction = library.makeFunction(name: "node_vertex")
        desc.fragmentFunction = library.makeFunction(name: "node_fragment")
        nodePipeline = try! device.makeRenderPipelineState(descriptor: desc)

        desc.vertexFunction = library.makeFunction(name: "line_vertex")
        desc.fragmentFunction = library.makeFunction(name: "line_fragment")
        linePipeline = try! device.makeRenderPipelineState(descriptor: desc)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)
    }

    func rebuild(document: GraphDocument) {
        layoutWorkItem?.cancel()
        nodeIds = document.nodes.map(\.id)
        flavors = document.nodes.map(\.flavor)
        let idToIndex = Dictionary(uniqueKeysWithValues: nodeIds.enumerated().map { ($0.element, $0.offset) })
        linkPairs = document.links.compactMap { link in
            guard let a = idToIndex[link.source], let b = idToIndex[link.target] else { return nil }
            return (a, b, link.kind)
        }

        let n = max(nodeIds.count, 1)
        baseDistance = max(12, min(90, Float(n) * 0.18 + 10))
        updateCameraDistance()

        let force = ForceLayout3D(nodeIds: nodeIds, links: document.links.map { ($0.source, $0.target) })
        force.linkDistance = n > 400 ? 3.2 : 4.0
        force.charge = n > 300 ? 0 : -36
        layout = force

        // Warm a little on background so UI stays responsive.
        let warm = n > 800 ? 12 : (n > 300 ? 30 : 80)
        let settle = n > 400 ? 40 : 80
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self, let layout = self.layout else { return }
            for _ in 0..<warm {
                if work.isCancelled { return }
                _ = layout.tick(1)
            }
            let pos = self.nodeIds.map { layout.positions[$0] ?? .zero }
            DispatchQueue.main.async {
                self.positions = pos
                self.uploadGPUBuffers()
            }
            for i in 0..<settle {
                if work.isCancelled { return }
                _ = layout.tick(n > 400 ? 1 : 2)
                if i % 8 == 0 {
                    let pos2 = self.nodeIds.map { layout.positions[$0] ?? .zero }
                    DispatchQueue.main.async {
                        self.positions = pos2
                        self.uploadGPUBuffers()
                    }
                }
            }
            let finalPos = self.nodeIds.map { layout.positions[$0] ?? .zero }
            DispatchQueue.main.async {
                self.positions = finalPos
                self.uploadGPUBuffers()
            }
        }
        layoutWorkItem = work
        // Seed immediate sphere so first frame isn't empty.
        positions = nodeIds.map { force.positions[$0] ?? .zero }
        uploadGPUBuffers()
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    func refreshSelectionColors() {
        uploadGPUBuffers()
    }

    private func updateCameraDistance() {
        radius = baseDistance / max(zoom, 0.2)
    }

    func orbit(dx: Float, dy: Float) {
        dragging = true
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
    }

    private func uploadGPUBuffers() {
        guard !nodeIds.isEmpty else {
            nodeCount = 0
            lineVertexCount = 0
            return
        }
        var nodes: [GPUNode] = []
        nodes.reserveCapacity(nodeIds.count)
        for (i, id) in nodeIds.enumerated() {
            let p = i < positions.count ? positions[i] : .zero
            let flavor = i < flavors.count ? flavors[i] : "type"
            let selected = id == selectedId
            var c = color(for: flavor)
            if selected { c = SIMD4(1, 0.9, 0.2, 1) }
            let size = selected ? size(for: flavor) * 1.45 : size(for: flavor)
            nodes.append(GPUNode(position: p, size: size, color: c))
        }
        nodeCount = nodes.count
        nodeBuffer = device.makeBuffer(
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
            let col: SIMD4<Float> =
                kind == "call"
                ? SIMD4(0.25, 0.55, 1.0, 0.55)
                : SIMD4(0.55, 0.55, 0.58, 0.35)
            lines.append(GPULine(position: positions[a], color: col))
            lines.append(GPULine(position: positions[b], color: col))
        }
        lineVertexCount = lines.count
        if !lines.isEmpty {
            lineBuffer = device.makeBuffer(
                bytes: lines,
                length: MemoryLayout<GPULine>.stride * lines.count,
                options: [.storageModeShared]
            )
        } else {
            lineBuffer = nil
        }
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
        let view = lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        let proj = perspective(fovY: 50 * .pi / 180, aspect: aspect, near: 0.05, far: 800)
        return proj * view
    }

    private func cameraEye() -> SIMD3<Float> {
        let cp = cos(pitch), sp = sin(pitch)
        let cy = cos(yaw), sy = sin(yaw)
        // Orbit around origin (matches prior SceneKit pivot).
        return SIMD3(radius * cp * sy, radius * sp, radius * cp * cy)
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
                let damp = exp(-8.5 * dt)
                yawVel *= damp
                pitchVel *= damp
            }
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let ub = uniformBuffer
        else { return }

        let w = Float(view.drawableSize.width)
        let h = max(Float(view.drawableSize.height), 1)
        var uniforms = GPUUniforms(
            viewProjection: viewProjection(aspect: w / h),
            viewport: SIMD2(w, h),
            pointScale: 1.0
        )
        memcpy(ub.contents(), &uniforms, MemoryLayout<GPUUniforms>.stride)

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
