//
//  ViewerRenderer.swift
//  ThreeDee
//
//  Metal renderer for meshes, point clouds, feature edges and the metric grid.
//  Two cameras: the orbit camera (with head-tracked parallax offsets) and the
//  immersion walking camera, which can also render split-screen for phone VR
//  headsets with lens pre-distortion and IMU head tracking.
//

import GameController
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
    var material = SIMD4<Float>(0, 0, 1, 0)
    var baseColor = SIMD4<Float>(1, 1, 1, 1)
    var emissive = SIMD4<Float>(0, 0, 0, 0)
    var points = SIMD4<Float>(0, 0, 0, 64)
    var splat = SIMD4<Float>(0, 0, 0, 0)
}

struct DistortionUniforms {
    var lens = SIMD4<Float>(0, 0, 0.06, 39.3)
    var distortion = SIMD4<Float>(0, 0, 0, 0)
    var tangents = SIMD4<Float>(-1, 1, -1, 1)
    var uvRect = SIMD4<Float>(0, 0, 1, 1)
    var background = SIMD4<Float>(0, 0, 0, 1)
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
    var headset = HeadsetProfile()
}

/// What the immersion HUD shows.
struct ImmersionStatus: Equatable {
    var scaleLabel = "1:1"
    var isTrueScale = true
}

/// One rendered view: camera pose, projection and the pixel height of its viewport.
private struct RenderView {
    var pose: CameraPose
    var frustum: Frustum
    var viewportWidth: Float
    var viewportHeight: Float
}

final class ViewerRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let flatPipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let distortionPipeline: MTLRenderPipelineState
    private let splatPipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthRead: MTLDepthStencilState
    private let depthIgnore: MTLDepthStencilState

    private var positionBuffer: MTLBuffer?
    private var normalBuffer: MTLBuffer?
    private var colorBuffer: MTLBuffer?
    private var uvBuffer: MTLBuffer?
    private var radiusBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var edgeBuffer: MTLBuffer?
    private var gridBuffer: MTLBuffer?
    private var axisBuffer: MTLBuffer?
    private let placeholderBuffer: MTLBuffer
    private var vertexCount = 0
    private var indexCount = 0
    private var edgeVertexCount = 0
    private var gridVertexCount = 0
    private var axisVertexCount = 0
    private var hasNormals = false
    private var hasColors = false
    private var hasUVs = false
    private var hasRadii = false
    private var hasAppearance = false
    private var isPointCloud = false
    /// Typical spacing-derived radius for point clouds without per-point sizes (immersion only).
    private var spacingRadius: Float = 0

    // Gaussian splats: shapes plus a far-to-near draw order, re-sorted in the background as the view moves.
    private var splatShapeBuffer: MTLBuffer?
    private var splatOrder: MTLBuffer?
    private var splatCount = 0
    private var splatSortInFlight = false
    private var splatSortedFrom: (eye: SIMD3<Float>, forward: SIMD3<Float>)?

    // Materials and their textures (uploaded in the background; white until ready).
    private var materials: [MeshMaterial] = []
    private var materialRanges: [MaterialRange] = []
    private var materialTextures: [MTLTexture?] = []
    private let whiteTexture: MTLTexture
    private var textureGeneration = 0

    private(set) var bounds = BoundingBox.empty
    private(set) var focusBounds = BoundingBox.empty
    private(set) var gridSpec: GridSpec?
    private var content: PreparedMesh?
    var camera = OrbitCamera()
    var style = ViewerStyle() {
        didSet { if style.gridUnit != oldValue.gridUnit { rebuildGrid() } }
    }
    var faceTracker: FaceTracker?
    private weak var view: MTKView?

    // Orbit interaction state.
    private var spinVelocity = SIMD2<Float>(0, 0)
    private var lastTime = CACurrentMediaTime()
    private var cameraAnimation: (from: OrbitCamera, to: OrbitCamera, start: CFTimeInterval, duration: CFTimeInterval)?
    private var needsFraming = false

    // Head-tracking baseline (the user's natural viewing position).
    private var headBaseline: SIMD3<Float>?
    private var headLostSince: CFTimeInterval?
    /// Smoothed head offset from the baseline in metres (screen right, up, towards the viewer).
    private var headOffset = SIMD3<Float>(0, 0, 0)
    private var headDistance: Float = 0.4

    // Immersion.
    private(set) var isImmersive = false
    private var walk = WalkCamera()
    private var arrival = WalkCamera()
    private var naturalScale: Float = 1000
    /// 0 = orbit view, 1 = standing inside; animated in between.
    private var immersion: Float = 0
    private var immersionAnimation: (from: Float, to: Float, start: CFTimeInterval, duration: CFTimeInterval)?
    private var walkAnimation: (from: WalkCamera, to: WalkCamera, start: CFTimeInterval, duration: CFTimeInterval)?
    private var ground: GroundIndex?
    private var groundBuildID: UUID?
    private var lookVelocity = SIMD2<Float>(0, 0)
    /// Joystick deflection (x: strafe right, y: forward), −1…1.
    var moveInput = SIMD2<Float>(0, 0)
    /// Finger held on the screen in VR mode (the headset's button): walk where you look.
    var touchHeld = false
    var onImmersionChange: ((ImmersionStatus) -> Void)?

    // VR (split screen).
    private(set) var isStereo = false
    var headMotion: HeadMotion?
    private var vrYawOffset: Float = 0
    private var vrAligned = false
    private var stereoLayout: StereoLayout?
    private var eyeTexture: MTLTexture?
    private var eyeMSAA: MTLTexture?
    private var eyeDepth: MTLTexture?
    private static let vrBackground = SIMD4<Float>(0.015, 0.03, 0.08, 1)

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
              let grid = pipeline("lineVertex", "gridFragment", blended: true),
              let distortion = pipeline("fullscreenVertex", "distortionFragment", blended: false) else { return nil }
        meshPipeline = mesh; flatPipeline = flat; pointPipeline = points; linePipeline = lines; gridPipeline = grid
        distortionPipeline = distortion
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = library.makeFunction(name: "splatVertex")
        sd.fragmentFunction = library.makeFunction(name: "splatFragment")
        sd.rasterSampleCount = view.sampleCount
        sd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        let sc = sd.colorAttachments[0]!
        sc.pixelFormat = view.colorPixelFormat
        sc.isBlendingEnabled = true
        sc.sourceRGBBlendFactor = .one
        sc.sourceAlphaBlendFactor = .one
        sc.destinationRGBBlendFactor = .oneMinusSourceAlpha
        sc.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let splat = try? device.makeRenderPipelineState(descriptor: sd) else { return nil }
        splatPipeline = splat

        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .less
        dw.isDepthWriteEnabled = true
        let dr = MTLDepthStencilDescriptor()
        dr.depthCompareFunction = .lessEqual
        dr.isDepthWriteEnabled = false
        let di = MTLDepthStencilDescriptor()
        di.depthCompareFunction = .always
        di.isDepthWriteEnabled = false
        guard let w = device.makeDepthStencilState(descriptor: dw), let r = device.makeDepthStencilState(descriptor: dr),
              let ignore = device.makeDepthStencilState(descriptor: di),
              let placeholder = device.makeBuffer(length: 16) else { return nil }
        depthWrite = w
        depthRead = r
        depthIgnore = ignore
        placeholderBuffer = placeholder

        let whiteDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        whiteDesc.usage = .shaderRead
        guard let white = device.makeTexture(descriptor: whiteDesc) else { return nil }
        var texel: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &texel, bytesPerRow: 4)
        whiteTexture = white
        super.init()
        view.delegate = self
    }

    // MARK: Content

    func setContent(_ prepared: PreparedMesh?) {
        textureGeneration += 1
        content = prepared
        ground = nil
        groundBuildID = nil
        splatShapeBuffer = nil; splatOrder = nil; splatCount = 0; splatSortedFrom = nil
        guard let prepared else {
            positionBuffer = nil; normalBuffer = nil; colorBuffer = nil; uvBuffer = nil; radiusBuffer = nil
            indexBuffer = nil; edgeBuffer = nil
            vertexCount = 0; indexCount = 0; edgeVertexCount = 0
            materials = []; materialRanges = []; materialTextures = []
            bounds = .empty
            focusBounds = .empty
            rebuildGrid()
            return
        }
        let m = prepared.mesh
        vertexCount = m.vertexCount
        isPointCloud = m.isPointCloud
        hasNormals = m.hasNormals
        hasColors = m.hasColors
        hasUVs = m.hasTexCoords
        hasRadii = m.hasPointRadii
        hasAppearance = m.hasAppearance
        positionBuffer = packed(m.positions)
        normalBuffer = m.hasNormals ? packed(m.normals) : nil
        colorBuffer = m.hasColors ? m.colors.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) } : nil
        uvBuffer = m.hasTexCoords ? m.texCoords.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) } : nil
        radiusBuffer = m.hasPointRadii ? m.pointRadii.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) } : nil
        indexCount = m.indices.count
        indexBuffer = m.indices.isEmpty ? nil : m.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        let edges = prepared.edgeLines.map { SIMD4<Float>($0, 1) }
        edgeVertexCount = edges.count
        edgeBuffer = edges.isEmpty ? nil : edges.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        if m.hasSplats {
            splatCount = m.vertexCount
            splatShapeBuffer = m.splats.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        }
        materials = m.hasMaterials ? m.materials : []
        materialRanges = m.hasMaterials ? prepared.materialRanges : []
        materialTextures = [MTLTexture?](repeating: nil, count: m.textures.count)
        bounds = prepared.bounds
        focusBounds = prepared.focusBounds
        let s = focusBounds.size
        let area = max(2 * (s.x * s.y + s.y * s.z + s.z * s.x), 1e-6)
        spacingRadius = 0.7 * sqrt(area / Float(max(vertexCount, 1)))
        rebuildGrid()
        needsFraming = true
        if m.hasTextures { loadTextures(m.textures) }
    }

    private func loadTextures(_ textures: [MeshTexture]) {
        let generation = textureGeneration
        let uploads = TextureLoader.uploads(textures, device: device)
        Task { [weak self] in
            for await (index, texture) in uploads {
                guard let self, self.textureGeneration == generation else { return }
                if index < self.materialTextures.count { self.materialTextures[index] = texture.value }
            }
        }
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
        let spec = GridSpec.make(for: focusBounds, unit: style.gridUnit)
        var adjusted = spec
        // Sit just below the model so its base never z-fights the grid.
        adjusted.height -= max(focusBounds.diagonal, 1) * 0.0005
        gridSpec = adjusted
        let lines = adjusted.vertices()
        gridVertexCount = lines.count
        gridBuffer = lines.isEmpty ? nil : lines.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        let axes = adjusted.axisVertices()
        axisVertexCount = axes.count
        axisBuffer = axes.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
    }

    // MARK: Camera control (routed to the orbit or walking camera)

    private var aspect: Float {
        guard let v = view, v.bounds.height > 0 else { return 1 }
        return Float(v.bounds.width / v.bounds.height)
    }

    func resetView(animated: Bool) {
        if isImmersive {
            returnToArrival()
            return
        }
        var target = camera
        target.frame(focusBounds, aspect: aspect)
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
        guard !isImmersive else { return }
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
        if isImmersive {
            walkAnimation = nil
            turnHead(by: SIMD2(Float(delta.x), Float(delta.y)))
            return
        }
        cameraAnimation = nil
        camera.rotate(dx: Float(delta.x), dy: Float(delta.y))
    }

    func endRotate(velocity: CGPoint) {
        if isImmersive {
            lookVelocity = SIMD2(Float(velocity.x), Float(velocity.y))
        } else {
            spinVelocity = SIMD2(Float(velocity.x), Float(velocity.y))
        }
    }

    func stopInertia() {
        spinVelocity = .zero
        lookVelocity = .zero
    }

    func pan(by delta: CGPoint) {
        if isImmersive {
            // Two fingers: grab the world — drag sideways to strafe, drag down to rise.
            walkAnimation = nil
            let metresPerPoint: Float = 0.012
            let h = walk.yaw
            let right = SIMD2(sin(h), -cos(h))
            let side = -Float(delta.x) * metresPerPoint * walk.unitsPerMetre
            walk.feet.x += right.x * side
            walk.feet.y += right.y * side
            walk.lift = min(max(walk.lift + Float(delta.y) * metresPerPoint, -WalkCamera.eyeHeight + 0.15), 200)
            return
        }
        cameraAnimation = nil
        camera.pan(dx: Float(delta.x), dy: Float(delta.y), viewHeight: Float(view?.bounds.height ?? 1))
    }

    func zoom(by factor: CGFloat) {
        if isImmersive {
            // Pinch out: you shrink, so the world grows around you (eye height and pace scale with you).
            walkAnimation = nil
            let u = walk.unitsPerMetre / Float(factor)
            walk.unitsPerMetre = min(max(u, naturalScale / 200), naturalScale * 50)
            publishImmersion()
            return
        }
        cameraAnimation = nil
        camera.zoom(by: Float(factor))
    }

    /// One-finger drag in immersion: the world follows the finger (inverted rotation, scaled so the
    /// point under the finger stays under it).
    private func turnHead(by points: SIMD2<Float>) {
        let radiansPerPoint = walk.fieldOfView / Float(max(view?.bounds.height ?? 600, 1))
        if isStereo && headMotion?.isAvailable == true {
            vrYawOffset += points.x * radiansPerPoint
        } else {
            walk.yaw += points.x * radiansPerPoint
            walk.pitch = min(max(walk.pitch + points.y * radiansPerPoint, -1.45), 1.45)
        }
    }

    // MARK: Immersion

    func enterImmersion() {
        guard !isImmersive, !focusBounds.isEmpty else { return }
        isImmersive = true
        cameraAnimation = nil
        spinVelocity = .zero
        lookVelocity = .zero
        naturalScale = WalkCamera.naturalScale(for: focusBounds)
        var w = WalkCamera()
        w.unitsPerMetre = naturalScale
        // Step in where the orbit camera was looking, facing the same way, eyes level.
        let target = simd_clamp(camera.target, focusBounds.min, focusBounds.max)
        w.feet = SIMD3(target.x, target.y, ground?.standingHeight(at: SIMD2(target.x, target.y)) ?? focusBounds.min.z)
        w.yaw = camera.effectiveYaw + .pi
        w.pitch = 0
        walk = w
        arrival = w
        buildGround()
        immersionAnimation = (immersion, 1, CACurrentMediaTime(), 0.9)
        publishImmersion()
    }

    func exitImmersion() {
        guard isImmersive else { return }
        setStereo(false)
        isImmersive = false
        moveInput = .zero
        touchHeld = false
        lookVelocity = .zero
        walkAnimation = nil
        immersionAnimation = (immersion, 0, CACurrentMediaTime(), 0.7)
    }

    func resetWorldScale() {
        guard isImmersive else { return }
        var to = walk
        to.unitsPerMetre = naturalScale
        walkAnimation = (walk, to, CACurrentMediaTime(), 0.45)
    }

    private func returnToArrival() {
        var to = arrival
        to.unitsPerMetre = walk.unitsPerMetre
        if isStereo { to.yaw = walk.yaw; to.pitch = walk.pitch }
        lookVelocity = .zero
        walkAnimation = (walk, to, CACurrentMediaTime(), 0.6)
    }

    private func publishImmersion() {
        let status = ImmersionStatus(scaleLabel: WalkCamera.scaleLabel(unitsPerMetre: walk.unitsPerMetre),
                                     isTrueScale: abs(walk.unitsPerMetre - 1000) < 30)
        onImmersionChange?(status)
    }

    private func buildGround() {
        guard ground == nil, groundBuildID == nil, let content else { return }
        let id = content.id
        groundBuildID = id
        let mesh = content.mesh, focus = content.focusBounds
        Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) { GroundIndex(mesh: mesh, focus: focus) }.value
            guard let self, self.content?.id == id else { return }
            self.ground = index
            // Stand on the real floor now that it's known.
            let p = SIMD2(self.arrival.feet.x, self.arrival.feet.y)
            let z = index.standingHeight(at: p)
            self.arrival.feet.z = z
            if self.isImmersive, self.walkAnimation == nil, simd_distance(SIMD2(self.walk.feet.x, self.walk.feet.y), p) < 1e-3 {
                self.walk.feet.z = z
            }
        }
    }

    // MARK: VR

    func setStereo(_ on: Bool) {
        guard on != isStereo else { return }
        if on {
            guard isImmersive else { return }
            isStereo = true
            vrAligned = false
            headMotion?.start()
        } else {
            // Carry the head direction back into the hand-held view so nothing jumps.
            if let pose = vrHeadPose() {
                let f = -pose.back
                walk.yaw = atan2(f.y, f.x)
                walk.pitch = min(max(asin(min(max(f.z, -1), 1)), -1.45), 1.45)
            }
            isStereo = false
            touchHeld = false
            headMotion?.stop()
            stereoLayout = nil
            eyeTexture = nil; eyeMSAA = nil; eyeDepth = nil
        }
    }

    /// Camera axes (right, up) in device coordinates for the current interface orientation;
    /// the camera always looks out of the back of the phone.
    private func deviceAxes() -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        switch view?.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .landscapeRight {
        case .landscapeRight: (SIMD3(0, -1, 0), SIMD3(1, 0, 0))
        case .landscapeLeft: (SIMD3(0, 1, 0), SIMD3(-1, 0, 0))
        case .portraitUpsideDown: (SIMD3(-1, 0, 0), SIMD3(0, -1, 0))
        default: (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
    }

    /// Head pose from the IMU, aligned on first use so you keep facing where you were looking.
    private func vrHeadPose() -> CameraPose? {
        guard isStereo, let attitude = headMotion?.attitude() else { return nil }
        let (r, u) = deviceAxes()
        let back = SIMD3<Float>(0, 0, 1)
        if !vrAligned {
            let f = -attitude.act(back)
            let horizontal = abs(f.z) < 0.95 ? SIMD2(f.x, f.y) : SIMD2(attitude.act(u).x, attitude.act(u).y)
            vrYawOffset = walk.yaw - atan2(horizontal.y, horizontal.x)
            vrAligned = true
        }
        let world = simd_quatf(angle: vrYawOffset, axis: SIMD3(0, 0, 1)) * attitude
        let right = world.act(r), up = world.act(u), b = world.act(back)
        // Neck model: eyes sit in front of and above the pivot, so nodding moves them slightly.
        let neck = up * 0.075 - b * 0.08 - SIMD3(0, 0, 0.075)
        return CameraPose(eye: walk.eye + neck * walk.unitsPerMetre, right: right, up: up, back: b)
    }

    // MARK: Per-frame updates

    private func updateParallax(dt: Float, now: CFTimeInterval) {
        var targetYaw: Float = 0, targetPitch: Float = 0, targetZoom: Float = 1
        var targetHead = SIMD3<Float>(0, 0, 0)
        if style.parallaxEnabled, !isStereo, let pose = faceTracker?.pose, pose.valid, now - pose.timestamp < 0.5, pose.size > 0.02 {
            let sample = SIMD3<Float>(pose.x, pose.y, pose.size)
            headLostSince = nil
            if var base = headBaseline {
                // The neutral position follows the user slowly (≈ 8 s), like the Home Screen effect.
                base += (sample - base) * (1 - exp(-dt / 8))
                headBaseline = base
                let s = style.parallaxStrength
                if isImmersive {
                    // Immersion: the screen becomes a window; the head moves the eye behind it.
                    let now3 = HeadWindow.headPosition(x: sample.x, y: sample.y, size: sample.z, aspect: pose.aspect)
                    let base3 = HeadWindow.headPosition(x: base.x, y: base.y, size: base.z, aspect: pose.aspect)
                    targetHead = simd_clamp(now3 - base3, SIMD3(-0.15, -0.15, -0.2), SIMD3(0.15, 0.15, 0.25))
                    headDistance = base3.z
                } else {
                    let dx = sample.x - base.x, dy = sample.y - base.y
                    // Moving the head left/up swings the camera left/up around the model.
                    targetYaw = min(max(dx * 1.1, -0.3), 0.3) * s
                    targetPitch = min(max(dy * 1.1, -0.25), 0.25) * s
                    // Leaning in (larger face) zooms in; leaning back zooms out.
                    let ratio = base.z / sample.z
                    let zoom = min(max(pow(ratio, 0.85), 0.75), 1.3)
                    targetZoom = 1 + (zoom - 1) * s
                }
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
        headOffset += (targetHead - headOffset) * (1 - exp(-dt * 8))
    }

    private func updateCamera(dt: Float, now: CFTimeInterval) {
        if let anim = cameraAnimation {
            let t = Float(min(1, (now - anim.start) / anim.duration))
            let e = ViewerRenderer.ease(t)
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

    private func updateWalk(dt: Float, now: CFTimeInterval) {
        if let anim = immersionAnimation {
            let t = Float(min(1, (now - anim.start) / anim.duration))
            immersion = anim.from + (anim.to - anim.from) * ViewerRenderer.ease(t)
            if t >= 1 { immersionAnimation = nil }
        }
        guard isImmersive else { return }
        if let anim = walkAnimation {
            let t = Float(min(1, (now - anim.start) / anim.duration))
            let e = ViewerRenderer.ease(t)
            var w = anim.to
            w.feet = simd_mix(anim.from.feet, anim.to.feet, SIMD3(repeating: e))
            w.yaw = anim.from.yaw + remainder(anim.to.yaw - anim.from.yaw, 2 * .pi) * e
            w.pitch = anim.from.pitch + (anim.to.pitch - anim.from.pitch) * e
            w.lift = anim.from.lift + (anim.to.lift - anim.from.lift) * e
            // Interpolate size geometrically so scale changes feel even.
            w.unitsPerMetre = anim.from.unitsPerMetre * pow(anim.to.unitsPerMetre / anim.from.unitsPerMetre, e)
            walk = w
            if t >= 1 { walkAnimation = nil; publishImmersion() } else { publishImmersion() }
            return
        }
        if simd_length(lookVelocity) > 1 {
            turnHead(by: lookVelocity * dt)
            lookVelocity *= exp(-dt * 6)
        }

        // Inputs: on-screen joystick, game controller, or (VR) holding the screen.
        var move = moveInput
        if let pad = GCController.current?.extendedGamepad {
            let l = SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
            if simd_length(l) > 0.15 { move += l }
            let r = SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
            if simd_length(r) > 0.15 {
                if isStereo && headMotion?.isAvailable == true {
                    vrYawOffset -= r.x * 2.0 * dt
                } else {
                    walk.yaw -= r.x * 2.0 * dt
                    walk.pitch = min(max(walk.pitch + r.y * 1.4 * dt, -1.45), 1.45)
                }
            }
        }
        if isStereo && touchHeld { move.y += 1 }
        if simd_length(move) > 1 { move = simd_normalize(move) }

        if move != .zero {
            var heading = walk.yaw
            if isStereo, let pose = vrHeadPose() {
                let f = -pose.back
                if abs(f.z) < 0.97 { heading = atan2(f.y, f.x) }
            }
            let forward = SIMD2(cos(heading), sin(heading)), right = SIMD2(sin(heading), -cos(heading))
            let step = (forward * move.y + right * move.x) * WalkCamera.walkSpeed * walk.unitsPerMetre * dt
            walk.feet.x += step.x
            walk.feet.y += step.y
        }

        // Follow floors, stairs and ramps; never climb more than a step.
        if let ground {
            var target = walk.feet.z
            if ground.followsSurfaces {
                let maxZ = walk.feet.z + WalkCamera.stepHeight * walk.unitsPerMetre
                if let z = ground.ground(at: SIMD2(walk.feet.x, walk.feet.y), below: maxZ) { target = z }
            } else {
                target = ground.floorHeight
            }
            let rate: Float = target > walk.feet.z ? 14 : 7
            walk.feet.z += (target - walk.feet.z) * (1 - exp(-dt * rate))
        }
    }

    private static func ease(_ t: Float) -> Float {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: Views

    private func orbitView(aspect: Float, width: Float, height: Float) -> RenderView {
        let (r, u, b) = camera.basis
        let (near, far) = camera.depthRange
        return RenderView(pose: CameraPose(eye: camera.eye, right: r, up: u, back: b),
                          frustum: .symmetric(fieldOfView: camera.fieldOfView, aspect: aspect, near: near, far: far),
                          viewportWidth: width, viewportHeight: height)
    }

    /// The hand-held immersion view, with head-tracked window parallax.
    private func walkView(aspect: Float, width: Float, height: Float) -> RenderView {
        let (near, far) = walk.depthRange(sceneBounds: bounds)
        let base = walk.pose
        if style.parallaxEnabled, simd_length(headOffset) > 1e-5 {
            let (pose, frustum) = HeadWindow.apply(head: headOffset, distance: headDistance, strength: style.parallaxStrength,
                                                   to: base, fieldOfView: walk.fieldOfView, aspect: aspect,
                                                   near: near, far: far, unitsPerMetre: walk.unitsPerMetre)
            return RenderView(pose: pose, frustum: frustum, viewportWidth: width, viewportHeight: height)
        }
        return RenderView(pose: base, frustum: .symmetric(fieldOfView: walk.fieldOfView, aspect: aspect, near: near, far: far),
                          viewportWidth: width, viewportHeight: height)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if needsFraming || focusBounds.isEmpty { needsFraming = true }
        stereoLayout = nil
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 0), 0.1))
        lastTime = now
        if needsFraming, view.bounds.height > 0, !focusBounds.isEmpty {
            resetView(animated: false)
            needsFraming = false
        }
        if !isImmersive { updateCamera(dt: dt, now: now) }
        updateWalk(dt: dt, now: now)
        updateParallax(dt: dt, now: now)

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }

        let size = view.drawableSize
        if isStereo && immersion >= 1, let layout = ensureStereoTargets(size: size, view: view),
           let eyeTexture, let eyeMSAA, let eyeDepth {
            renderStereo(layout: layout, eyeTexture: eyeTexture, eyeMSAA: eyeMSAA, eyeDepth: eyeDepth,
                         pass: pass, commands: commands)
        } else if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            let aspect = Float(size.width / max(size.height, 1))
            let width = Float(size.width), height = Float(size.height)
            var rv = orbitView(aspect: aspect, width: width, height: height)
            if immersion > 0 {
                let w = walkView(aspect: aspect, width: width, height: height)
                rv = immersion >= 1 ? w : RenderView(pose: .blend(rv.pose, w.pose, immersion),
                                                     frustum: .blend(rv.frustum, w.frustum, immersion),
                                                     viewportWidth: width, viewportHeight: height)
            }
            sortSplatsIfNeeded(eye: rv.pose.eye, forward: -rv.pose.back)
            drawScene(encoder, rv)
            encoder.endEncoding()
        }
        commands.present(drawable)
        commands.commit()
    }

    // MARK: Splat sorting

    /// Starts a background re-sort when the view has moved or turned noticeably since the last one.
    private func sortSplatsIfNeeded(eye: SIMD3<Float>, forward: SIMD3<Float>) {
        guard splatCount > 0, !splatSortInFlight, let content else { return }
        if let last = splatSortedFrom, splatOrder != nil {
            let moved = simd_distance(last.eye, eye) > max(focusBounds.diagonal, 1e-3) * 0.01
            let turned = simd_dot(last.forward, forward) < 0.9986 // ~3°
            if !moved && !turned { return }
        }
        splatSortInFlight = true
        splatSortedFrom = (eye, forward)
        let positions = content.mesh.positions, box = focusBounds, id = content.id
        let gpu = UncheckedBox(device)
        Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) { () -> UncheckedBox<MTLBuffer>? in
                SplatSorter.order(positions, eye: eye, forward: forward, focus: box, device: gpu.value).map(UncheckedBox.init)
            }.value
            guard let self else { return }
            self.splatSortInFlight = false
            guard self.content?.id == id, let sorted else { return }
            self.splatOrder = sorted.value
        }
    }

    // MARK: Stereo

    /// Physical size of one drawable pixel. iOS doesn't expose the panel's density, so it's derived
    /// from the screen class (460 ppi for @3x, 401 for downsampled Plus panels, 326 for @2x).
    private func millimetresPerPixel(_ view: MTKView) -> Float {
        let native = Float(view.window?.windowScene?.screen.nativeScale ?? view.contentScaleFactor)
        let ppi: Float = native >= 2.9 ? 460 : (native > 2.5 ? 401 : 326)
        return 25.4 / ppi * native / Float(max(view.contentScaleFactor, 1))
    }

    private func ensureStereoTargets(size: CGSize, view: MTKView) -> StereoLayout? {
        guard size.width > 0, size.height > 0 else { return nil }
        if let layout = stereoLayout, layout.drawable == size, layout.profile == style.headset, eyeTexture != nil {
            return layout
        }
        let layout = StereoLayout.make(drawable: size, mmPerPixel: millimetresPerPixel(view), profile: style.headset)
        let w = layout.textureSize.x, h = layout.textureSize.y
        let resolve = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.colorPixelFormat, width: w, height: h, mipmapped: false)
        resolve.usage = [.renderTarget, .shaderRead]
        resolve.storageMode = .private
        let msaa = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.colorPixelFormat, width: w, height: h, mipmapped: false)
        msaa.textureType = .type2DMultisample
        msaa.sampleCount = view.sampleCount
        msaa.usage = .renderTarget
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.depthStencilPixelFormat, width: w, height: h, mipmapped: false)
        depth.textureType = .type2DMultisample
        depth.sampleCount = view.sampleCount
        depth.usage = .renderTarget
        #if targetEnvironment(simulator)
        msaa.storageMode = .private
        depth.storageMode = .private
        #else
        // Tile memory only: the samples never leave the GPU.
        msaa.storageMode = .memoryless
        depth.storageMode = .memoryless
        #endif
        eyeTexture = device.makeTexture(descriptor: resolve)
        eyeMSAA = device.makeTexture(descriptor: msaa)
        eyeDepth = device.makeTexture(descriptor: depth)
        stereoLayout = layout
        return eyeTexture != nil && eyeMSAA != nil && eyeDepth != nil ? layout : nil
    }

    private func renderStereo(layout: StereoLayout, eyeTexture: MTLTexture, eyeMSAA: MTLTexture, eyeDepth: MTLTexture,
                              pass: MTLRenderPassDescriptor, commands: MTLCommandBuffer) {
        // 1. Both eyes, undistorted, side by side in one texture.
        let eyePass = MTLRenderPassDescriptor()
        let bg = ViewerRenderer.vrBackground
        eyePass.colorAttachments[0].texture = eyeMSAA
        eyePass.colorAttachments[0].resolveTexture = eyeTexture
        eyePass.colorAttachments[0].loadAction = .clear
        eyePass.colorAttachments[0].storeAction = .multisampleResolve
        eyePass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        eyePass.depthAttachment.texture = eyeDepth
        eyePass.depthAttachment.loadAction = .clear
        eyePass.depthAttachment.storeAction = .dontCare
        eyePass.depthAttachment.clearDepth = 1
        guard let eyes = commands.makeRenderCommandEncoder(descriptor: eyePass) else { return }
        let head = vrHeadPose() ?? walk.pose
        sortSplatsIfNeeded(eye: head.eye, forward: -head.back)
        let (near, far) = walk.depthRange(sceneBounds: bounds)
        for eye in layout.eyes {
            let r = eye.render
            eyes.setViewport(MTLViewport(originX: r.minX, originY: r.minY, width: r.width, height: r.height, znear: 0, zfar: 1))
            eyes.setScissorRect(MTLScissorRect(x: Int(r.minX), y: Int(r.minY), width: Int(r.width), height: Int(r.height)))
            var pose = head
            pose.eye += head.right * eye.offset * walk.unitsPerMetre
            let t = eye.tangents
            drawScene(eyes, RenderView(pose: pose, frustum: Frustum(left: t.x, right: t.y, bottom: t.z, top: t.w, near: near, far: far),
                                       viewportWidth: Float(r.width), viewportHeight: Float(r.height)))
        }
        eyes.endEncoding()

        // 2. Pre-distort each eye image into its half of the screen for the headset's lenses.
        guard let screen = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        screen.setRenderPipelineState(distortionPipeline)
        screen.setDepthStencilState(depthIgnore)
        let tex = SIMD2(Float(layout.textureSize.x), Float(layout.textureSize.y))
        let profile = layout.profile
        for eye in layout.eyes {
            let s = eye.screen
            screen.setViewport(MTLViewport(originX: s.minX, originY: s.minY, width: s.width, height: s.height, znear: 0, zfar: 1))
            var d = DistortionUniforms()
            d.lens = SIMD4(eye.lensCenter.x, eye.lensCenter.y, layout.mmPerPixel, profile.screenToLens)
            d.distortion = SIMD4(profile.correctsDistortion ? profile.k1 : 0, profile.correctsDistortion ? profile.k2 : 0,
                                 Float(layout.drawable.width) / 2, 1.5)
            d.tangents = eye.tangents
            d.uvRect = SIMD4(Float(eye.render.minX) / tex.x, Float(eye.render.minY) / tex.y,
                             Float(eye.render.maxX) / tex.x, Float(eye.render.maxY) / tex.y)
            d.background = ViewerRenderer.vrBackground
            screen.setFragmentBytes(&d, length: MemoryLayout<DistortionUniforms>.stride, index: 0)
            screen.setFragmentTexture(eyeTexture, index: 0)
            screen.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        screen.endEncoding()
    }

    // MARK: Scene

    private func drawScene(_ encoder: MTLRenderCommandEncoder, _ rv: RenderView) {
        let pose = rv.pose
        let viewMatrix = pose.viewMatrix()
        let projection = rv.frustum.matrix
        let right = pose.right, up = pose.up, back = pose.back
        let immersed = immersion > 0.5
        var u = ViewerUniforms()
        u.viewProjection = projection * viewMatrix
        u.view = viewMatrix
        u.cameraPosition = SIMD4(pose.eye, 1)
        u.lightDirection = SIMD4(simd_normalize(back * 0.75 + up * 0.55 + right * 0.35), 0)
        if style.blueprint {
            u.shadowColor = SIMD4(0.0, 0.16, 0.42, 1)
            u.litColor = SIMD4(0.96, 0.97, 1.0, 1)
        } else {
            u.shadowColor = SIMD4(0.0, 0.25, 0.62, 1)
            u.litColor = SIMD4(0.965, 0.975, 1.0, 1)
        }
        let ink: SIMD3<Float> = style.blueprint ? SIMD3(1, 1, 1) : SIMD3(0, 71.0 / 255, 171.0 / 255)
        let scale = Float(view?.contentScaleFactor ?? 3)
        let appearance = style.originalColors && hasAppearance
        u.params = SIMD4(pointSize() * scale, appearance ? 1 : 0, hasNormals ? 1 : 0, 0)
        // Colour-preserving light: lighter touch inside a space, where scans carry their own lighting.
        u.material = SIMD4(0, 0, immersed ? 0.35 : 1, 0)
        u.emissive = SIMD4(0, 0, 0, hasColors ? 1 : 0)
        if let g = gridSpec { u.grid = SIMD4(g.center.x, g.center.y, g.halfExtent, 0) }
        // Depth cue for normal-less points: spans the scene from its nearest to farthest extent.
        u.grid.w = max(focusBounds.diagonal / 2, 1e-4)
        if isPointCloud {
            u.grid.z = simd_distance(pose.eye, focusBounds.center)
        }
        // Splats (and, inside a scan, every point) are drawn as world-sized discs.
        let focal = projection.columns.1.y * rv.viewportHeight / 2
        u.points = SIMD4(immersed && !hasRadii ? spacingRadius : 0, focal, hasRadii ? 1 : 0, immersed ? 96 : 64)

        if let positionBuffer, vertexCount > 0 {
            encoder.setDepthStencilState(depthWrite)
            encoder.setCullMode(.none)
            // Meshes use counter-clockwise (right-hand, outward) winding; Metal defaults to clockwise.
            encoder.setFrontFacing(.counterClockwise)
            encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(normalBuffer ?? placeholderBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(colorBuffer ?? placeholderBuffer, offset: 0, index: 2)
            encoder.setVertexBuffer(uvBuffer ?? placeholderBuffer, offset: 0, index: 4)
            encoder.setVertexBuffer(radiusBuffer ?? placeholderBuffer, offset: 0, index: 5)
            encoder.setFragmentTexture(whiteTexture, index: 0)
            encoder.setFragmentTexture(whiteTexture, index: 1)
            let renderPoints = isPointCloud || style.renderStyle == .points
            if splatCount > 0 {
                // Transparent: drawn last, after the grid.
            } else if renderPoints {
                var pu = u
                if !isPointCloud {
                    pu.params.x = max(2, pointSize()) * scale
                    pu.grid.z = simd_distance(pose.eye, focusBounds.center)
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
                    if appearance && !materialRanges.isEmpty {
                        drawMaterials(encoder, u, indexBuffer: indexBuffer)
                    } else {
                        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
                    }
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

        if splatCount > 0, let positionBuffer, let colorBuffer, let splatShapeBuffer, let splatOrder {
            var su = u
            let p = rv.frustum.matrix
            su.points = SIMD4(p.columns.0.x * rv.viewportWidth / 2, p.columns.1.y * rv.viewportHeight / 2,
                              rv.viewportWidth, rv.viewportHeight)
            // Splats right in front of the eye would fill the view with blur; skip them, like splat viewers do.
            su.splat.x = immersed ? 0.15 * walk.unitsPerMetre : rv.frustum.near
            encoder.setRenderPipelineState(splatPipeline)
            encoder.setDepthStencilState(depthRead)
            encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(colorBuffer, offset: 0, index: 2)
            encoder.setVertexBytes(&su, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
            encoder.setVertexBuffer(splatShapeBuffer, offset: 0, index: 5)
            encoder.setVertexBuffer(splatOrder, offset: 0, index: 6)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCount)
        }
    }

    /// One draw per material with its colour, textures, emission and cut-out settings.
    private func drawMaterials(_ encoder: MTLRenderCommandEncoder, _ u: ViewerUniforms, indexBuffer: MTLBuffer) {
        for range in materialRanges {
            guard range.material < materials.count else { continue }
            let m = materials[range.material]
            var mu = u
            let base = m.baseColorTexture.flatMap { $0 < materialTextures.count ? materialTextures[$0] : nil }
            let emission = m.emissiveTexture.flatMap { $0 < materialTextures.count ? materialTextures[$0] : nil }
            let textured = hasUVs && m.baseColorTexture != nil
            mu.material = SIMD4(textured ? 1 : 0, hasUVs && m.emissiveTexture != nil ? 1 : 0, m.unlit ? 0 : u.material.z, m.alphaCutoff)
            mu.baseColor = m.baseColor
            // A texture still uploading shouldn't flash the scene to full emission.
            let emissiveReady = m.emissiveTexture == nil || emission != nil
            mu.emissive = SIMD4(emissiveReady ? m.emissive : .zero, u.emissive.w)
            encoder.setFragmentTexture(base ?? whiteTexture, index: 0)
            encoder.setFragmentTexture(emission ?? whiteTexture, index: 1)
            encoder.setVertexBytes(&mu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
            encoder.setFragmentBytes(&mu, length: MemoryLayout<ViewerUniforms>.stride, index: 3)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.indexCount, indexType: .uint32,
                                          indexBuffer: indexBuffer, indexBufferOffset: range.indexStart * 4)
        }
        encoder.setFragmentTexture(whiteTexture, index: 0)
        encoder.setFragmentTexture(whiteTexture, index: 1)
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

