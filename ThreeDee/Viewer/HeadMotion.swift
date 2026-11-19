//
//  HeadMotion.swift
//  ThreeDee
//
//  Device attitude from the built-in IMU (gyroscope + accelerometer, fused by
//  Core Motion) for VR mode. The renderer polls it once per frame, the
//  lowest-latency way to read Core Motion, and predicts a few milliseconds
//  ahead with the gyro rate to hide display latency.
//

import CoreMotion
import QuartzCore
import simd

final class HeadMotion {
    private let manager = CMMotionManager()
    private(set) var isRunning = false
    #if DEBUG
    private let fake = ProcessInfo.processInfo.arguments.contains("-fakeMotion")
    private var fakeStart = CACurrentMediaTime()
    #endif

    var isAvailable: Bool {
        #if DEBUG
        if fake { return true }
        #endif
        return manager.isDeviceMotionAvailable
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        #if DEBUG
        if fake { fakeStart = CACurrentMediaTime(); return }
        #endif
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        // Z vertical, arbitrary heading: no compass needed, and no magnetometer jumps near metal or speakers.
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopDeviceMotionUpdates()
    }

    /// Rotation taking device coordinates (x right, y up in portrait, z out of the screen) to a
    /// Z-up world frame with arbitrary heading, predicted `ahead` seconds into the future.
    func attitude(predictingAhead ahead: Double = 0.02) -> simd_quatf? {
        #if DEBUG
        if fake { return fakeAttitude() }
        #endif
        guard isRunning, let motion = manager.deviceMotion else { return nil }
        let q = motion.attitude.quaternion
        var attitude = simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
        let rate = SIMD3(Float(motion.rotationRate.x), Float(motion.rotationRate.y), Float(motion.rotationRate.z))
        let speed = simd_length(rate)
        if speed > 1e-4 {
            // The gyro rate is in device coordinates, so the increment composes on the right.
            attitude = attitude * simd_quatf(angle: speed * Float(ahead), axis: rate / speed)
        }
        return simd_normalize(attitude)
    }

    #if DEBUG
    /// Phone upright in landscape (top edge to the left), looking at the horizon and turning slowly.
    private func fakeAttitude() -> simd_quatf {
        let t = Float(CACurrentMediaTime() - fakeStart)
        let heading = 0.5 * sin(t * 0.6)
        let tilt = 0.12 * sin(t * 0.9)
        let c = cos(heading), s = sin(heading)
        // Device x → up, device z (out of the screen) → backwards from the heading.
        let x = SIMD3<Float>(0, 0, 1), z = SIMD3<Float>(-c, -s, 0)
        let upright = simd_quatf(simd_float3x3(x, simd_cross(z, x), z))
        // Nod: rotate about the device's long (y) axis, which points left/right in landscape.
        return simd_normalize(upright * simd_quatf(angle: tilt, axis: SIMD3(0, 1, 0)))
    }
    #endif
}
