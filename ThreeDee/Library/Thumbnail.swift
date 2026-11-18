//
//  Thumbnail.swift
//  ThreeDee
//
//  Library previews are stippled point drawings: points sampled uniformly over
//  the surface, projected isometrically and stored as a few kilobytes of floats.
//

import Foundation
import simd

nonisolated struct StippleThumbnail: Codable, Sendable, Equatable {
    /// Interleaved (x, y, depth) triples, each in 0…1. y grows downwards.
    var points: [Float]
    /// Width / height of the projected drawing.
    var aspect: Float

    static let yaw: Float = -0.75
    static let pitch: Float = 0.5

    static func make(from mesh: Mesh, count: Int = 1800) -> StippleThumbnail {
        let samples = sample(mesh, count: count)
        guard !samples.isEmpty else { return StippleThumbnail(points: [], aspect: 1) }
        // Same orientation as the viewer's home view.
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let toCamera = SIMD3<Float>(cp * cy, cp * sy, sp)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), toCamera))
        let up = simd_cross(toCamera, right)
        var projected: [SIMD3<Float>] = samples.map { SIMD3(simd_dot($0, right), -simd_dot($0, up), simd_dot($0, toCamera)) }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in projected { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let span = simd_max(hi - lo, SIMD3(repeating: 1e-9))
        let side = max(span.x, span.y)
        var out: [Float] = []
        out.reserveCapacity(projected.count * 3)
        // Draw far points first so near ones overlay them.
        projected.sort { $0.z < $1.z }
        for p in projected {
            out.append((p.x - lo.x + (side - span.x) / 2) / side)
            out.append((p.y - lo.y + (side - span.y) / 2) / side)
            out.append((p.z - lo.z) / span.z)
        }
        return StippleThumbnail(points: out, aspect: span.x / span.y)
    }

    /// Area-weighted random surface samples (or a random subset for point clouds).
    private static func sample(_ mesh: Mesh, count: Int) -> [SIMD3<Float>] {
        var rng = SplitMix(seed: 0x5EED)
        if mesh.isPointCloud || mesh.indices.isEmpty {
            guard !mesh.positions.isEmpty else { return [] }
            if mesh.positions.count <= count { return mesh.positions }
            return (0..<count).map { _ in mesh.positions[Int(rng.next() % UInt64(mesh.positions.count))] }
        }
        let triCount = mesh.indices.count / 3
        var cumulative = [Float](repeating: 0, count: triCount)
        var total: Float = 0
        for t in 0..<triCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            total += simd_length(simd_cross(b - a, c - a)) * 0.5
            cumulative[t] = total
        }
        guard total > 0 else { return Array(mesh.positions.prefix(count)) }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let r = Float(rng.nextUnit()) * total
            var lo = 0, hi = triCount - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if cumulative[mid] < r { lo = mid + 1 } else { hi = mid }
            }
            let a = mesh.positions[Int(mesh.indices[lo * 3])]
            let b = mesh.positions[Int(mesh.indices[lo * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[lo * 3 + 2])]
            var u = Float(rng.nextUnit()), v = Float(rng.nextUnit())
            if u + v > 1 { u = 1 - u; v = 1 - v }
            let ab: SIMD3<Float> = (b - a) * u
            let ac: SIMD3<Float> = (c - a) * v
            out.append(a + ab + ac)
        }
        return out
    }
}

nonisolated struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
