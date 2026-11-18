//
//  ViewerRenderer.swift
//  ThreeDee
//
//  Metal renderer for meshes, point clouds, feature edges and the metric grid,
//  with an orbit camera that also receives head-tracked parallax offsets.
//

import MetalKit
import QuartzCore
import simd
import UIKit

struct ViewerUniforms {
    var viewProjection = matrix_identity_float4x4
    var view = matrix_identity_float4x4
    var shadowColor = SIMD4<Float>(0, 0.28, 0.67, 1)
    var litColor = SIMD4<Float>(1, 1, 1, 1)
    var lineColor = SIMD4<Float>(0, 0.28, 0.67, 1)
    var cameraPosition = SIMD4<Float>(0, 0, 0, 1)
    var lightDirection = SIMD4<Float>(0, 0, 1, 0)
    var params = SIMD4<Float>(2, 0, 1, 0)
    var grid = SIMD4<Float>(0, 0, 100, 0)
}

struct ViewerStyle: Equatable {
    var renderStyle: RenderStyle = .edges
    var originalColors = false
    var showGrid = true
    var showAxes = true
    var gridUnit: GridUnit = .millimeter
    var blueprint = false
    var parallaxEnabled = true
    var parallaxStrength: Float = 0.6
}

final class ViewerRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let flatPipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthRead: MTLDepthStencilState

    private var positionBuffer: MTLBuffer?
    private var normalBuffer: MTLBuffer?
    private var colorBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var edgeBuffer: MTLBuffer?
    private var gridBuffer: MTLBuffer?
    private var axisBuffer: MTLBuffer?
    private var vertexCount = 0
    private var indexCount = 0
    private var edgeVertexCount = 0
    private var gridVertexCount = 0
    private var axisVertexCount = 0
    private var hasNormals = false
    private var hasColors = false
    private var isPointCloud = false

    private(set) var bounds = BoundingBox.empty
    private(set) var gridSpec: GridSpec?
    var camera = OrbitCamera()
    var style = ViewerStyle() {
        didSet { if style.gridUnit != oldValue.gridUnit { rebuildGrid() } }
    }
    var faceTracker: FaceTracker?
    private weak var view: MTKView?

    // Interaction state.
    private var spinVelocity = SIMD2<Float>(0, 0)
    private var lastTime = CACurrentMediaTime()
    private var cameraAnimation: (from: OrbitCamera, to: OrbitCamera, start: CFTimeInterval, duration: CFTimeInterval)?
    private var needsFraming = false

    // Head-tracking baseline (the user's natural viewing position).
    private var headBaseline: SIMD3<Float>?
    private var headLostSince: CFTimeInterval?

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        self.view = view
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.preferredFramesPerSecond = 60

        func pipeline(_ vertex: String, _ fragment: String, blended: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.rasterSampleCount = view.sampleCount
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = view.colorPixelFormat
            if blended {
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let mesh = pipeline("meshVertex", "meshFragment", blended: false),
              let flat = pipeline("meshVertex", "flatFragment", blended: true),
              let points = pipeline("meshVertex", "pointFragment", blended: false),
              let lines = pipeline("lineVertex", "lineFragment", blended: true),
              let grid = pipeline("lineVertex", "gridFragment", blended: true) else { return nil }
        meshPipeline = mesh; flatPipeline = flat; pointPipeline = points; linePipeline = lines; gridPipeline = grid

        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .less
        dw.isDepthWriteEnabled = true
        let dr = MTLDepthStencilDescriptor()
        dr.depthCompareFunction = .lessEqual
        dr.isDepthWriteEnabled = false
        guard let w = device.makeDepthStencilState(descriptor: dw), let r = device.makeDepthStencilState(descriptor: dr) else { return nil }
        depthWrite = w
        depthRead = r
        super.init()
        view.delegate = self
    }

    // MARK: Content

    func setContent(_ prepared: PreparedMesh?) {
        guard let prepared else {
            positionBuffer = nil; normalBuffer = nil; colorBuffer = nil; indexBuffer = nil; edgeBuffer = nil
            vertexCount = 0; indexCount = 0; edgeVertexCount = 0
            bounds = .empty
            rebuildGrid()
            return
        }
        let m = prepared.mesh
        vertexCount = m.vertexCount
        isPointCloud = m.isPointCloud
        hasNormals = m.hasNormals
        hasColors = m.hasColors
        positionBuffer = packed(m.positions)
        normalBuffer = m.hasNormals ? packed(m.normals) : device.makeBuffer(length: 16)
        colorBuffer = m.hasColors
            ? m.colors.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            : device.makeBuffer(length: 16)
        indexCount = m.indices.count
        indexBuffer = m.indices.isEmpty ? nil : m.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        let edges = prepared.edgeLines.map { SIMD4<Float>($0, 1) }
        edgeVertexCount = edges.count
        edgeBuffer = edges.isEmpty ? nil : edges.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        bounds = prepared.bounds
        rebuildGrid()
        needsFraming = true
    }

    private func packed(_ v: [SIMD3<Float>]) -> MTLBuffer? {
        guard !v.isEmpty, let buffer = device.makeBuffer(length: v.count * 12, options: .storageModeShared) else { return nil }
        let p = buffer.contents().assumingMemoryBound(to: Float.self)
        for (i, x) in v.enumerated() {
            p[i * 3] = x.x; p[i * 3 + 1] = x.y; p[i * 3 + 2] = x.z
        }
        return buffer
    }

    private func rebuildGrid() {
        let spec = GridSpec.make(for: bounds, unit: style.gridUnit)
        var adjusted = spec
        // Sit just below the model so its base never z-fights the grid.
        adjusted.height -= max(bounds.diagonal, 1) * 0.0005
        gridSpec = adjusted
        let lines = adjusted.vertices()
        gridVertexCount = lines.count
        gridBuffer = lines.isEmpty ? nil : lines.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        let axes = adjusted.axisVertices()
        axisVertexCount = axes.count
        axisBuffer = axes.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
    }

    // MARK: Camera control

    private var aspect: Float {
        guard let v = view, v.bounds.height > 0 else { return 1 }
        return Float(v.bounds.width / v.bounds.height)
    }

    func resetView(animated: Bool) {
        var target = camera
        target.frame(bounds, aspect: aspect)
        spinVelocity = .zero
        if animated {
            cameraAnimation = (camera, target, CACurrentMediaTime(), 0.55)
        } else {
            let p = (camera.parallaxYaw, camera.parallaxPitch, camera.parallaxZoom)
            camera = target
            (camera.parallaxYaw, camera.parallaxPitch, camera.parallaxZoom) = p
        }
    }

    /// Snaps to a standard orthographic-style direction (yaw, pitch).
    func look(yaw: Float, pitch: Float) {
        var target = camera
        target.yaw = yaw
        target.pitch = pitch
        // Choose the equivalent yaw closest to the current one for a short turn.
        let twoPi = Float.pi * 2
        target.yaw = camera.yaw + remainder(target.yaw - camera.yaw, twoPi)
        spinVelocity = .zero
        cameraAnimation = (camera, target, CACurrentMediaTime(), 0.45)
    }

    func rotate(by delta: CGPoint) {
        cameraAnimation = nil
        camera.rotate(dx: Float(delta.x), dy: Float(delta.y))
    }

    func endRotate(velocity: CGPoint) {
        spinVelocity = SIMD2(Float(velocity.x), Float(velocity.y))
    }

    func stopInertia() { spinVelocity = .zero }

    func pan(by delta: CGPoint) {
        cameraAnimation = nil
        camera.pan(dx: Float(delta.x), dy: Float(delta.y), viewHeight: Float(view?.bounds.height ?? 1))
    }

    func zoom(by factor: CGFloat) {
        cameraAnimation = nil
        camera.zoom(by: Float(factor))
    }

    // MARK: Per-frame updates

    private func updateParallax(dt: Float, now: CFTimeInterval) {
        var targetYaw: Float = 0, targetPitch: Float = 0, targetZoom: Float = 1
        if style.parallaxEnabled, let pose = faceTracker?.pose, pose.valid, now - pose.timestamp < 0.5, pose.size > 0.02 {
            let sample = SIMD3<Float>(pose.x, pose.y, pose.size)
            headLostSince = nil
            if var base = headBaseline {
                // The neutral position follows the user slowly (≈ 8 s), like the Home Screen effect.
                base += (sample - base) * (1 - exp(-dt / 8))
                headBaseline = base
                let s = style.parallaxStrength
                let dx = sample.x - base.x, dy = sample.y - base.y
                // Moving the head left/up swings the camera left/up around the model.
                targetYaw = min(max(dx * 1.1, -0.3), 0.3) * s
                targetPitch = min(max(dy * 1.1, -0.25), 0.25) * s
                // Leaning in (larger face) zooms in; leaning back zooms out.
                let ratio = base.z / sample.z
                let zoom = min(max(pow(ratio, 0.85), 0.75), 1.3)
                targetZoom = 1 + (zoom - 1) * s
            } else {
                headBaseline = sample
            }
        } else {
            if headLostSince == nil { headLostSince = now }
            if let lost = headLostSince, now - lost > 2 { headBaseline = nil }
        }
        let k = 1 - exp(-dt * 5)
        camera.parallaxYaw += (targetYaw - camera.parallaxYaw) * k
        camera.parallaxPitch += (targetPitch - camera.parallaxPitch) * k
        camera.parallaxZoom += (targetZoom - camera.parallaxZoom) * k
    }

    private func updateCamera(dt: Float, now: CFTimeInterval) {
        if let anim = cameraAnimation {
            let t = Float(min(1, (now - anim.start) / anim.duration))
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let p = (camera.parallaxYaw, camera.parallaxPitch, camera.parallaxZoom)
            var c = anim.to
            c.target = simd_mix(anim.from.target, anim.to.target, SIMD3(repeating: e))
            c.distance = anim.from.distance + (anim.to.distance - anim.from.distance) * e
            c.yaw = anim.from.yaw + remainder(anim.to.yaw - anim.from.yaw, 2 * .pi) * e
            c.pitch = anim.from.pitch + (anim.to.pitch - anim.from.pitch) * e
            camera = c
            (camera.parallaxYaw, camera.parallaxPitch, camera.parallaxZoom) = p
            if t >= 1 { cameraAnimation = nil }
        } else if simd_length(spinVelocity) > 1 {
            camera.rotate(dx: spinVelocity.x * dt, dy: spinVelocity.y * dt)
            spinVelocity *= exp(-dt * 4.5)
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if needsFraming || bounds.isEmpty { needsFraming = true }
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 0), 0.1))
        lastTime = now
        if needsFraming, view.bounds.height > 0, !bounds.isEmpty {
            resetView(animated: false)
            needsFraming = false
        }
        updateCamera(dt: dt, now: now)
        updateParallax(dt: dt, now: now)

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let viewMatrix = camera.viewMatrix()
        let eye = camera.eye
        let (right, up, back) = camera.basis
        var u = ViewerUniforms()
        u.viewProjection = camera.projectionMatrix(aspect: aspect) * viewMatrix
        u.view = viewMatrix
        u.cameraPosition = SIMD4(eye, 1)
        u.lightDirection = SIMD4(simd_normalize(back * 0.75 + up * 0.55 + right * 0.35), 0)
        if style.blueprint {
            u.shadowColor = SIMD4(0.0, 0.16, 0.42, 1)
            u.litColor = SIMD4(0.96, 0.97, 1.0, 1)
        } else {
            u.shadowColor = SIMD4(0.0, 0.25, 0.62, 1)
            u.litColor = SIMD4(0.965, 0.975, 1.0, 1)
        }
        let ink: SIMD3<Float> = style.blueprint ? SIMD3(1, 1, 1) : SIMD3(0, 71.0 / 255, 171.0 / 255)
        let scale = Float(view.contentScaleFactor)
        u.params = SIMD4(pointSize() * scale, style.originalColors && hasColors ? 1 : 0, hasNormals ? 1 : 0, 0)
        if let g = gridSpec { u.grid = SIMD4(g.center.x, g.center.y, g.halfExtent, 0) }
        // Depth cue for normal-less points: spans the scene from its nearest to farthest extent.
        u.grid.w = max(bounds.diagonal / 2, 1e-4)
        if isPointCloud {
            u.grid.z = camera.effectiveDistance
        }

        // Model.
        if let positionBuffer, vertexCount > 0 {
            encoder.setDepthStencilState(depthWrite)
            encoder.setCullMode(.none)
            // Meshes use counter-clockwise (right-hand, outward) winding; Metal defaults to clockwise.
            encoder.setFrontFacing(.counterClockwise)
            encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(normalBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(colorBuffer, offset: 0, index: 2)
            let renderPoints = isPointCloud || style.renderStyle == .points
            if renderPoints {
                var pu = u
                if !isPointCloud {
                    pu.params.x = max(2, pointSize()) * scale
                    pu.grid.z = camera.effectiveDistance
                }
                encoder.setRenderPipelineState(pointPipeline)
                encoder.setVertexBytes(&pu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
                encoder.setFragmentBytes(&pu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertexCount)
            } else if let indexBuffer {
                encoder.setVertexBytes(&u, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
                encoder.setFragmentBytes(&u, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
                if style.renderStyle == .wireframe {
                    var wu = u
                    wu.lineColor = SIMD4(ink, 0.55)
                    encoder.setRenderPipelineState(flatPipeline)
                    encoder.setTriangleFillMode(.lines)
                    encoder.setVertexBytes(&wu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
                    encoder.setFragmentBytes(&wu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                                  indexBuffer: indexBuffer, indexBufferOffset: 0)
                    encoder.setTriangleFillMode(.fill)
                } else {
                    encoder.setRenderPipelineState(meshPipeline)
                    // Push faces back slightly so edges drawn on top stay crisp.
                    encoder.setDepthBias(1, slopeScale: 2, clamp: 0.01)
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                                  indexBuffer: indexBuffer, indexBufferOffset: 0)
                    encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
                    if style.renderStyle == .edges, let edgeBuffer, edgeVertexCount > 0 {
                        var eu = u
                        eu.lineColor = SIMD4(ink, style.blueprint ? 0.95 : 0.85)
                        encoder.setRenderPipelineState(linePipeline)
                        encoder.setDepthStencilState(depthRead)
                        encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
                        encoder.setVertexBytes(&eu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
                        encoder.setFragmentBytes(&eu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
                        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeVertexCount)
                    }
                }
            }
        }

        // Grid and axes, occluded by the model.
        encoder.setDepthStencilState(depthRead)
        if style.showGrid, let gridBuffer, gridVertexCount > 0 {
            var gu = u
            gu.lineColor = SIMD4(ink, style.blueprint ? 0.55 : 0.6)
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&gu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
            encoder.setFragmentBytes(&gu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
        }
        if style.showAxes, let axisBuffer, axisVertexCount > 0 {
            var au = u
            au.lineColor = SIMD4(ink, 0.9)
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setVertexBuffer(axisBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&au, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
            encoder.setFragmentBytes(&au, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: axisVertexCount)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private func pointSize() -> Float {
        switch vertexCount {
        case ..<10_000: 3
        case ..<100_000: 1.8
        case ..<1_000_000: 1.3
        default: 1
        }
    }
}
