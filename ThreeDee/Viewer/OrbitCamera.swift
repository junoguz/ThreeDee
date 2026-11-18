//
//  OrbitCamera.swift
//  ThreeDee
//
//  Turntable camera in a Z-up world, plus the small view offsets driven by
//  head tracking.
//

import Foundation
import simd

struct OrbitCamera {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 100
    var yaw: Float = -0.75
    var pitch: Float = 0.5
    var fieldOfView: Float = 35 * .pi / 180
    /// Radius of the content, used for clipping planes and zoom limits.
    var sceneRadius: Float = 50

    // Offsets applied on top of the user's view (head-tracked parallax).
    var parallaxYaw: Float = 0
    var parallaxPitch: Float = 0
    var parallaxZoom: Float = 1

    static let homeYaw: Float = -0.75
    static let homePitch: Float = 0.5

    var effectiveYaw: Float { yaw + parallaxYaw }
    var effectivePitch: Float { min(max(pitch + parallaxPitch, -1.55), 1.55) }
    var effectiveDistance: Float { distance * parallaxZoom }

    var eye: SIMD3<Float> {
        let cp = cos(effectivePitch), sp = sin(effectivePitch)
        return target + effectiveDistance * SIMD3(cp * cos(effectiveYaw), cp * sin(effectiveYaw), sp)
    }

    /// Camera basis (right, up, toward-camera).
    var basis: (right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>) {
        let back = simd_normalize(eye - target)
        var right = simd_cross(SIMD3<Float>(0, 0, 1), back)
        if simd_length(right) < 1e-5 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        return (right, simd_cross(back, right), back)
    }

    func viewMatrix() -> simd_float4x4 {
        let (r, u, b) = basis
        let e = eye
        return simd_float4x4(SIMD4(r.x, u.x, b.x, 0), SIMD4(r.y, u.y, b.y, 0), SIMD4(r.z, u.z, b.z, 0),
                             SIMD4(-simd_dot(r, e), -simd_dot(u, e), -simd_dot(b, e), 1))
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let d = effectiveDistance
        let near = max(d - sceneRadius * 3, d * 0.002, 1e-4)
        let far = d + sceneRadius * 6
        let y = 1 / tan(fieldOfView / 2)
        let x = y / max(aspect, 1e-4)
        let z = far / (near - far)
        return simd_float4x4(SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0))
    }

    // MARK: Interaction

    mutating func rotate(dx: Float, dy: Float) {
        yaw -= dx * 0.009
        pitch = min(max(pitch + dy * 0.009, -1.5), 1.5)
    }

    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let (r, u, _) = basis
        let worldPerPoint = 2 * effectiveDistance * tan(fieldOfView / 2) / max(viewHeight, 1)
        target += (-dx * r + dy * u) * worldPerPoint
    }

    mutating func zoom(by factor: Float) {
        distance = min(max(distance / factor, sceneRadius * 0.05), sceneRadius * 40)
    }

    /// Frames a bounding box from the home angle.
    mutating func frame(_ box: BoundingBox, aspect: Float) {
        target = box.isEmpty ? .zero : box.center
        sceneRadius = max(box.diagonal / 2, 1e-3)
        yaw = OrbitCamera.homeYaw
        pitch = OrbitCamera.homePitch
        let fitV = sceneRadius / sin(fieldOfView / 2)
        let fitH = sceneRadius / sin(atan(tan(fieldOfView / 2) * max(aspect, 0.1)))
        distance = max(fitV, fitH) * 1.08
    }
}
