//
//  Immersion.swift
//  ThreeDee
//
//  First-person ("immersion") viewing: a walking camera standing on the
//  model's floors, off-axis projection for head-tracked window parallax, and
//  the lens geometry for split-screen phone VR headsets.
//

import CoreGraphics
import Foundation
import Metal
import simd

// MARK: - Camera pose & frustum

/// Position and orientation of a camera. Camera-local axes: +X right, +Y up, +Z back (towards the viewer).
struct CameraPose {
    var eye: SIMD3<Float>
    var orientation: simd_quatf

    init(eye: SIMD3<Float>, orientation: simd_quatf) {
        self.eye = eye
        self.orientation = orientation
    }

    init(eye: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>) {
        self.eye = eye
        orientation = simd_normalize(simd_quatf(simd_float3x3(right, up, back)))
    }

    var right: SIMD3<Float> { orientation.act(SIMD3(1, 0, 0)) }
    var up: SIMD3<Float> { orientation.act(SIMD3(0, 1, 0)) }
    var back: SIMD3<Float> { orientation.act(SIMD3(0, 0, 1)) }

    func viewMatrix() -> simd_float4x4 {
        let r = right, u = up, b = back
        return simd_float4x4(SIMD4(r.x, u.x, b.x, 0), SIMD4(r.y, u.y, b.y, 0), SIMD4(r.z, u.z, b.z, 0),
                             SIMD4(-simd_dot(r, eye), -simd_dot(u, eye), -simd_dot(b, eye), 1))
    }

    static func blend(_ a: CameraPose, _ b: CameraPose, _ t: Float) -> CameraPose {
        CameraPose(eye: simd_mix(a.eye, b.eye, SIMD3(repeating: t)), orientation: simd_slerp(a.orientation, b.orientation, t))
    }
}

/// A perspective frustum described by the tangents of its edges at unit distance, so it can be
/// off-centre (head-tracked window, VR lenses) as well as symmetric.
struct Frustum {
    var left: Float, right: Float, bottom: Float, top: Float
    var near: Float, far: Float

    static func symmetric(fieldOfView: Float, aspect: Float, near: Float, far: Float) -> Frustum {
        let ty = tan(fieldOfView / 2), tx = ty * max(aspect, 1e-4)
        return Frustum(left: -tx, right: tx, bottom: -ty, top: ty, near: near, far: far)
    }

    /// Metal clip space (depth 0…1), right-handed view space looking down −Z.
    var matrix: simd_float4x4 {
        let l = left * near, r = right * near, b = bottom * near, t = top * near
        let z = far / (near - far)
        return simd_float4x4(SIMD4(2 * near / (r - l), 0, 0, 0),
                             SIMD4(0, 2 * near / (t - b), 0, 0),
                             SIMD4((r + l) / (r - l), (t + b) / (t - b), z, -1),
                             SIMD4(0, 0, z * near, 0))
    }

    static func blend(_ a: Frustum, _ b: Frustum, _ t: Float) -> Frustum {
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        // Keep the widest depth range while blending so neither end clips mid-flight.
        return Frustum(left: mix(a.left, b.left), right: mix(a.right, b.right), bottom: mix(a.bottom, b.bottom),
                       top: mix(a.top, b.top), near: min(a.near, b.near), far: max(a.far, b.far))
    }
}

// MARK: - Walking camera

/// A standing viewer inside the model. Distances are in model units (mm); `unitsPerMetre`
/// sets how big the visitor is (1000 = true human scale).
struct WalkCamera {
    /// Feet position: x/y on the floor plan, z the ground height under the visitor.
    var feet = SIMD3<Float>(0, 0, 0)
    /// Heading in the XY plane (0 = +X, counter-clockwise from above) and look pitch (+ = up).
    var yaw: Float = 0
    var pitch: Float = 0
    var unitsPerMetre: Float = 1000
    /// Extra height above standing eye level, in metres (two-finger drag to rise or crouch).
    var lift: Float = 0
    var fieldOfView: Float = 68 * .pi / 180

    static let eyeHeight: Float = 1.6
    static let stepHeight: Float = 0.5
    static let walkSpeed: Float = 1.6

    var eye: SIMD3<Float> { feet + SIMD3(0, 0, (WalkCamera.eyeHeight + lift) * unitsPerMetre) }

    var forward: SIMD3<Float> {
        SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }

    var pose: CameraPose {
        let f = forward
        var right = simd_cross(f, SIMD3<Float>(0, 0, 1))
        if simd_length(right) < 1e-5 { right = SIMD3(sin(yaw), -cos(yaw), 0) }
        right = simd_normalize(right)
        return CameraPose(eye: eye, right: right, up: simd_cross(right, f), back: -f)
    }

    /// Near/far planes: a few centimetres in front of the eye out to beyond the scene.
    func depthRange(sceneBounds: BoundingBox) -> (near: Float, far: Float) {
        let near = max(0.03 * unitsPerMetre, 1e-4)
        var farthest: Float = 0
        if !sceneBounds.isEmpty {
            for i in 0..<8 {
                let corner = SIMD3(i & 1 == 0 ? sceneBounds.min.x : sceneBounds.max.x,
                                   i & 2 == 0 ? sceneBounds.min.y : sceneBounds.max.y,
                                   i & 4 == 0 ? sceneBounds.min.z : sceneBounds.max.z)
                farthest = max(farthest, simd_distance(corner, eye))
            }
        }
        return (near, max(farthest * 1.2, near * 2000))
    }

    /// How big the visitor should be for a model: true scale for anything room-sized, otherwise
    /// small enough that the object reads like a building around you.
    static func naturalScale(for box: BoundingBox) -> Float {
        let s = box.isEmpty ? SIMD3<Float>(repeating: 1000) : box.size
        let footprint = max(s.x, s.y)
        if footprint >= 1500 { return 1000 }
        return max(max(footprint, s.z) / 8, 1e-3)
    }

    static func scaleLabel(unitsPerMetre: Float) -> String {
        let ratio = 1000 / max(unitsPerMetre, 1e-6)
        if abs(ratio - 1) < 0.03 { return "1:1" }
        if ratio > 1 { return ratio >= 10 ? String(format: "%.0f:1", ratio) : String(format: "%.1f:1", ratio) }
        let inverse = 1 / ratio
        return inverse >= 10 ? String(format: "1:%.0f", inverse) : String(format: "1:%.1f", inverse)
    }
}

// MARK: - Head-tracked window

/// Off-axis "window" projection: the screen is a fixed window into the space and the viewer's head,
/// tracked by the front camera, looks through it from different positions.
enum HeadWindow {
    /// Front camera half field of view (tangent) across the analysed frame's width.
    static let cameraHalfTan: Float = 0.55
    /// Typical face-box width in metres.
    static let faceWidth: Float = 0.15

    /// Head position in metres relative to the front camera from a face box (centre x/y 0…1, width fraction).
    static func headPosition(x: Float, y: Float, size: Float, aspect: Float) -> SIMD3<Float> {
        let z = faceWidth / (2 * cameraHalfTan * max(size, 0.02))
        return SIMD3((x - 0.5) * 2 * cameraHalfTan * z, (y - 0.5) * 2 * cameraHalfTan * aspect * z, z)
    }

    /// Camera pose and frustum for a head offset (metres, screen axes) at a baseline viewing distance.
    static func apply(head: SIMD3<Float>, distance: Float, strength: Float, to pose: CameraPose,
                      fieldOfView: Float, aspect: Float, near: Float, far: Float, unitsPerMetre: Float) -> (CameraPose, Frustum) {
        // Exaggerate the physical setup: translation T× and window skew K× stronger than life.
        let t = 1 + 3 * strength, k = 1 + 1.5 * strength
        let d = max(distance, 0.15) * t / k * unitsPerMetre
        let e = head * t * unitsPerMetre
        let wy = d * tan(fieldOfView / 2), wx = wy * aspect
        let dist = max(d + e.z, d * 0.3)
        var moved = pose
        moved.eye += pose.right * e.x + pose.up * e.y + pose.back * e.z
        let frustum = Frustum(left: (-wx - e.x) / dist, right: (wx - e.x) / dist,
                              bottom: (-wy - e.y) / dist, top: (wy - e.y) / dist, near: near, far: far)
        return (moved, frustum)
    }
}

// MARK: - Ground

/// Answers "what is under my feet?" for the walking camera. Meshes are indexed in a 2D grid of
/// walkable (roughly horizontal) triangles; point clouds only get a floor estimate.
nonisolated final class GroundIndex: Sendable {
    /// Height of the main floor (the largest horizontal surface in the lower half of the model).
    let floorHeight: Float
    let followsSurfaces: Bool
    private let origin: SIMD2<Float>
    private let cellSize: Float
    private let nx: Int, ny: Int
    private let cellStart: [Int32]
    private let cellItems: [Int32]
    private let positions: [SIMD3<Float>]
    private let indices: [UInt32]

    init(mesh: Mesh, focus: BoundingBox) {
        let box = focus.isEmpty ? mesh.bounds() : focus
        let zLow = box.min.z, zSpan = max(box.size.z, 1e-3)
        // Floor: area- (or count-) weighted histogram of horizontal surfaces in the lower half.
        let bins = 96
        var weight = [Double](repeating: 0, count: bins)
        var heightSum = [Double](repeating: 0, count: bins)
        func record(_ z: Float, _ w: Double) {
            let f = (z - zLow) / zSpan
            guard f >= -0.02, f <= 0.55 else { return }
            let b = min(max(Int(f / 0.55 * Float(bins)), 0), bins - 1)
            weight[b] += w
            heightSum[b] += Double(z) * w
        }

        positions = mesh.positions
        indices = mesh.indices
        if mesh.isPointCloud {
            let step = max(1, mesh.positions.count / 300_000)
            var i = 0
            while i < mesh.positions.count { record(mesh.positions[i].z, 1); i += step }
            followsSurfaces = false
            origin = .zero; cellSize = 1; nx = 0; ny = 0; cellStart = [0]; cellItems = []
        } else {
            let triCount = mesh.indices.count / 3
            var walkable: [Int32] = []
            walkable.reserveCapacity(triCount / 2)
            for t in 0..<triCount {
                let a: SIMD3<Float> = mesh.positions[Int(mesh.indices[t * 3])]
                let b: SIMD3<Float> = mesh.positions[Int(mesh.indices[t * 3 + 1])]
                let c: SIMD3<Float> = mesh.positions[Int(mesh.indices[t * 3 + 2])]
                let n: SIMD3<Float> = simd_cross(b - a, c - a)
                let len = simd_length(n)
                guard len > 0, abs(n.z) / len >= 0.5 else { continue }
                walkable.append(Int32(t))
                record((a.z + b.z + c.z) / 3, Double(len) * 0.5 * Double(abs(n.z) / len))
            }
            // Grid over the footprint, finer for denser meshes.
            let extent = SIMD2(max(box.size.x, 1e-3), max(box.size.y, 1e-3))
            let cells = Float(min(max(Int(sqrt(Double(walkable.count) / 3)), 16), 384))
            let size = max(extent.x, extent.y) / cells
            let gx = max(1, Int(ceil(extent.x / size))), gy = max(1, Int(ceil(extent.y / size)))
            let positions = mesh.positions, indices = mesh.indices
            let corner = SIMD2(box.min.x, box.min.y)
            var counts = [Int32](repeating: 0, count: gx * gy + 1)
            func cellRange(_ t: Int32) -> (Int, Int, Int, Int)? {
                let i = Int(t) * 3
                let a: SIMD3<Float> = positions[Int(indices[i])]
                let b: SIMD3<Float> = positions[Int(indices[i + 1])]
                let c: SIMD3<Float> = positions[Int(indices[i + 2])]
                let lo: SIMD2<Float> = (SIMD2(min(a.x, b.x, c.x), min(a.y, b.y, c.y)) - corner) / size
                let hi: SIMD2<Float> = (SIMD2(max(a.x, b.x, c.x), max(a.y, b.y, c.y)) - corner) / size
                let x0 = max(Int(lo.x.rounded(.down)), 0), y0 = max(Int(lo.y.rounded(.down)), 0)
                let x1 = min(Int(hi.x.rounded(.down)), gx - 1), y1 = min(Int(hi.y.rounded(.down)), gy - 1)
                return x0 <= x1 && y0 <= y1 ? (x0, x1, y0, y1) : nil
            }
            for t in walkable {
                guard let (x0, x1, y0, y1) = cellRange(t) else { continue }
                for y in y0...y1 { for x in x0...x1 { counts[y * gx + x + 1] += 1 } }
            }
            for i in 0..<(gx * gy) { counts[i + 1] += counts[i] }
            var fill = counts
            var items = [Int32](repeating: 0, count: Int(counts[gx * gy]))
            for t in walkable {
                guard let (x0, x1, y0, y1) = cellRange(t) else { continue }
                for y in y0...y1 {
                    for x in x0...x1 {
                        items[Int(fill[y * gx + x])] = t
                        fill[y * gx + x] += 1
                    }
                }
            }
            origin = corner
            cellSize = size
            nx = gx
            ny = gy
            cellStart = counts
            cellItems = items
            followsSurfaces = !walkable.isEmpty
        }
        if let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 {
            floorHeight = Float(heightSum[best] / weight[best])
        } else {
            floorHeight = box.min.z
        }
    }

    /// Heights of all walkable surfaces directly under (or over) a floor-plan point.
    func surfaces(at p: SIMD2<Float>) -> [Float] {
        guard followsSurfaces else { return [] }
        let c = (p - origin) / cellSize
        let x = Int(c.x.rounded(.down)), y = Int(c.y.rounded(.down))
        guard x >= 0, y >= 0, x < nx, y < ny else { return [] }
        var heights: [Float] = []
        let cell = y * nx + x
        for k in Int(cellStart[cell])..<Int(cellStart[cell + 1]) {
            let t = Int(cellItems[k]) * 3
            let a: SIMD3<Float> = positions[Int(indices[t])]
            let b: SIMD3<Float> = positions[Int(indices[t + 1])]
            let c3: SIMD3<Float> = positions[Int(indices[t + 2])]
            // Barycentric test in the XY plane.
            let v0 = SIMD2<Float>(b.x - a.x, b.y - a.y)
            let v1 = SIMD2<Float>(c3.x - a.x, c3.y - a.y)
            let v2 = SIMD2<Float>(p.x - a.x, p.y - a.y)
            let den: Float = v0.x * v1.y - v1.x * v0.y
            guard abs(den) > 1e-12 else { continue }
            let v: Float = (v2.x * v1.y - v1.x * v2.y) / den
            let w: Float = (v0.x * v2.y - v2.x * v0.y) / den
            let eps: Float = -1e-4
            guard v >= eps, w >= eps, v + w <= 1 - eps else { continue }
            let z: Float = a.z + v * (b.z - a.z) + w * (c3.z - a.z)
            heights.append(z)
        }
        return heights
    }

    /// The highest surface at or below `maxZ` (feet height plus a step), if any.
    func ground(at p: SIMD2<Float>, below maxZ: Float) -> Float? {
        surfaces(at: p).filter { $0 <= maxZ }.max()
    }

    /// Where to stand when arriving at a floor-plan point: the surface nearest the main floor.
    func standingHeight(at p: SIMD2<Float>) -> Float {
        surfaces(at: p).min(by: { abs($0 - floorHeight) < abs($1 - floorHeight) }) ?? floorHeight
    }
}

// MARK: - VR headset geometry

/// Optical parameters of a phone VR viewer. Defaults are Google Cardboard (2015) values, which most
/// phone headsets approximate.
struct HeadsetProfile: Equatable {
    /// Distance between the lens centres, also used as the virtual eye separation (mm).
    var lensSpacing: Float = 63.5
    var screenToLens: Float = 39.3
    /// Radial distortion r' = r (1 + k1 r² + k2 r⁴) in tangent-angle units.
    var k1: Float = 0.34
    var k2: Float = 0.55
    var correctsDistortion = true
}

/// Where each eye's image goes on screen and which frustum it is rendered with.
struct StereoLayout: Equatable {
    struct Eye: Equatable {
        /// Destination rectangle in drawable pixels.
        var screen: CGRect
        /// Lens centre in drawable pixels.
        var lensCenter: SIMD2<Float>
        /// Render frustum tangents: min x, max x, min y, max y.
        var tangents: SIMD4<Float>
        /// Rectangle in the shared eye texture.
        var render: CGRect
        /// Offset of this eye from the head centre along the head's right axis (metres).
        var offset: Float
    }

    var eyes: [Eye]
    var textureSize: SIMD2<Int>
    var mmPerPixel: Float
    var drawable: CGSize
    var profile: HeadsetProfile

    static func make(drawable: CGSize, mmPerPixel: Float, profile: HeadsetProfile) -> StereoLayout {
        let w = Float(drawable.width), h = Float(drawable.height)
        let half = w / 2
        let k1 = profile.correctsDistortion ? profile.k1 : 0, k2 = profile.correctsDistortion ? profile.k2 : 0
        let spacingPx = profile.lensSpacing / mmPerPixel
        func distort(_ t: SIMD2<Float>) -> SIMD2<Float> {
            let r2 = simd_length_squared(t)
            return t * (1 + k1 * r2 + k2 * r2 * r2)
        }
        var eyes: [Eye] = []
        var widest: Float = 0
        for side in 0..<2 {
            let x0 = Float(side) * half
            let center = SIMD2(w / 2 + (side == 0 ? -1 : 1) * spacingPx / 2, h / 2)
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            // Sample the eye's screen rectangle outline; radial distortion peaks at the corners.
            for i in 0...16 {
                let f = Float(i) / 16
                for p in [SIMD2(x0 + f * half, 0), SIMD2(x0 + f * half, h), SIMD2(x0, f * h), SIMD2(x0 + half, f * h)] {
                    let mm = (p - center) * mmPerPixel
                    let t = distort(SIMD2(mm.x, -mm.y) / profile.screenToLens)
                    lo = simd_min(lo, t); hi = simd_max(hi, t)
                }
            }
            let limit: Float = 1.6 // ≈ 58°: beyond this the lenses show nothing useful
            lo = simd_max(lo, SIMD2(repeating: -limit)); hi = simd_min(hi, SIMD2(repeating: limit))
            widest = max(widest, (hi.x - lo.x) / max(hi.y - lo.y, 1e-3))
            eyes.append(Eye(screen: CGRect(x: CGFloat(x0), y: 0, width: CGFloat(half), height: CGFloat(h)),
                            lensCenter: center, tangents: SIMD4(lo.x, hi.x, lo.y, hi.y), render: .zero,
                            offset: (side == 0 ? -1 : 1) * profile.lensSpacing / 2000))
        }
        let eyeH = Int(h)
        let eyeW = Int(min(max(Float(eyeH) * widest, half * 0.5), half * 1.5))
        for i in eyes.indices {
            eyes[i].render = CGRect(x: CGFloat(i * eyeW), y: 0, width: CGFloat(eyeW), height: CGFloat(eyeH))
        }
        return StereoLayout(eyes: eyes, textureSize: SIMD2(eyeW * 2, eyeH), mmPerPixel: mmPerPixel, drawable: drawable, profile: profile)
    }
}
