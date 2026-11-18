//
//  Mesh.swift
//  ThreeDee
//
//  The single in-memory geometry representation every importer produces and
//  every exporter consumes. A mesh without indices is a point cloud.
//

import Foundation
import simd

nonisolated struct RGBA8: Hashable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(unit r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(q(r), q(g), q(b), q(a))
    }

    static let white = RGBA8(255, 255, 255)
    static let neutral = RGBA8(214, 220, 232)
}

nonisolated struct BoundingBox: Sendable, Equatable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    static let empty = BoundingBox(min: SIMD3(repeating: .greatestFiniteMagnitude),
                                   max: SIMD3(repeating: -.greatestFiniteMagnitude))

    var isEmpty: Bool { min.x > max.x || min.y > max.y || min.z > max.z }
    var size: SIMD3<Float> { isEmpty ? .zero : max - min }
    var center: SIMD3<Float> { isEmpty ? .zero : (min + max) * 0.5 }
    var diagonal: Float { simd_length(size) }

    mutating func include(_ p: SIMD3<Float>) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }

    func union(_ other: BoundingBox) -> BoundingBox {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return BoundingBox(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }
}

nonisolated struct Mesh: Sendable {
    /// Vertex positions. Units and axis convention depend on context (see `ImportedModel`).
    var positions: [SIMD3<Float>] = []
    /// Per-vertex normals; empty when the source had none.
    var normals: [SIMD3<Float>] = []
    /// Per-vertex colours; empty when the source had none.
    var colors: [RGBA8] = []
    /// Triangle list. Empty for point clouds.
    var indices: [UInt32] = []

    init() {}

    init(positions: [SIMD3<Float>], normals: [SIMD3<Float>] = [], colors: [RGBA8] = [], indices: [UInt32] = []) {
        self.positions = positions
        self.normals = normals.count == positions.count ? normals : []
        self.colors = colors.count == positions.count ? colors : []
        self.indices = indices
    }

    var isEmpty: Bool { positions.isEmpty }
    var isPointCloud: Bool { indices.isEmpty && !positions.isEmpty }
    var vertexCount: Int { positions.count }
    var triangleCount: Int { indices.count / 3 }
    var hasNormals: Bool { !normals.isEmpty && normals.count == positions.count }
    var hasColors: Bool { !colors.isEmpty && colors.count == positions.count }

    func bounds() -> BoundingBox {
        var box = BoundingBox.empty
        for p in positions where p.x.isFinite && p.y.isFinite && p.z.isFinite { box.include(p) }
        return box
    }

    /// Applies an affine transform to positions (and the matching normal transform to normals).
    mutating func apply(_ m: simd_float4x4) {
        if m == matrix_identity_float4x4 { return }
        for i in positions.indices {
            let p = m * SIMD4(positions[i], 1)
            positions[i] = SIMD3(p.x, p.y, p.z)
        }
        if hasNormals {
            let upper = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                      SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                      SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            let nm = upper.inverse.transpose
            for i in normals.indices {
                let n = nm * normals[i]
                let l = simd_length(n)
                normals[i] = l > 0 ? n / l : n
            }
        }
        // A mirroring transform flips triangle winding; restore outward orientation.
        if simd_determinant(m) < 0 { flipWinding() }
    }

    func applying(_ m: simd_float4x4) -> Mesh {
        var copy = self
        copy.apply(m)
        return copy
    }

    mutating func flipWinding() {
        var i = 0
        while i + 2 < indices.count {
            indices.swapAt(i + 1, i + 2)
            i += 3
        }
    }

    /// Appends another mesh. Attributes present in only one of the two are filled with defaults
    /// so the arrays stay parallel.
    mutating func append(_ other: Mesh) {
        if other.isEmpty { return }
        if isEmpty && indices.isEmpty {
            self = other
            return
        }
        let base = UInt32(positions.count)
        let selfHadNormals = hasNormals, otherHasNormals = other.hasNormals
        let selfHadColors = hasColors, otherHasColors = other.hasColors

        if selfHadNormals || otherHasNormals {
            if !selfHadNormals { normals = [SIMD3<Float>](repeating: .zero, count: positions.count) }
            normals += otherHasNormals ? other.normals : [SIMD3<Float>](repeating: .zero, count: other.positions.count)
        }
        if selfHadColors || otherHasColors {
            if !selfHadColors { colors = [RGBA8](repeating: .neutral, count: positions.count) }
            colors += otherHasColors ? other.colors : [RGBA8](repeating: .neutral, count: other.positions.count)
        }
        positions += other.positions
        indices.reserveCapacity(indices.count + other.indices.count)
        for i in other.indices { indices.append(i + base) }
    }

    /// Drops faces so the mesh becomes a point cloud of its vertices.
    func asPointCloud() -> Mesh {
        Mesh(positions: positions, normals: normals, colors: colors, indices: [])
    }

    /// Removes triangles referencing invalid indices or non-finite positions.
    mutating func sanitize() {
        let n = UInt32(positions.count)
        var valid = [Bool](repeating: true, count: positions.count)
        for (i, p) in positions.enumerated() where !(p.x.isFinite && p.y.isFinite && p.z.isFinite) {
            valid[i] = false
        }
        var clean: [UInt32] = []
        clean.reserveCapacity(indices.count)
        var t = 0
        while t + 2 < indices.count {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            if a < n, b < n, c < n, a != b, b != c, a != c, valid[Int(a)], valid[Int(b)], valid[Int(c)] {
                clean.append(a); clean.append(b); clean.append(c)
            }
            t += 3
        }
        indices = clean
        if indices.isEmpty && valid.contains(false) {
            // Point cloud: drop invalid points entirely.
            var p: [SIMD3<Float>] = [], nn: [SIMD3<Float>] = [], cc: [RGBA8] = []
            for i in positions.indices where valid[i] {
                p.append(positions[i])
                if hasNormals { nn.append(normals[i]) }
                if hasColors { cc.append(colors[i]) }
            }
            self = Mesh(positions: p, normals: nn, colors: cc)
        }
    }
}

/// Basic measurements, all in the mesh's own units.
nonisolated struct MeshStatistics: Sendable {
    var surfaceArea: Double
    /// Enclosed volume; only meaningful when `isClosed`.
    var volume: Double
    var isClosed: Bool
    var boundaryEdges: Int

    static func compute(_ mesh: Mesh, topology: MeshTopology? = nil) -> MeshStatistics {
        guard !mesh.indices.isEmpty else {
            return MeshStatistics(surfaceArea: 0, volume: 0, isClosed: false, boundaryEdges: 0)
        }
        var area = 0.0, volume = 0.0
        let p = mesh.positions
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = SIMD3<Double>(p[Int(mesh.indices[t])])
            let b = SIMD3<Double>(p[Int(mesh.indices[t + 1])])
            let c = SIMD3<Double>(p[Int(mesh.indices[t + 2])])
            area += simd_length(simd_cross(b - a, c - a)) * 0.5
            volume += simd_dot(a, simd_cross(b, c)) / 6.0
            t += 3
        }
        let topo = topology ?? MeshTopology(mesh: mesh)
        let boundary = topo.boundaryEdgeCount
        return MeshStatistics(surfaceArea: area, volume: abs(volume), isClosed: boundary == 0, boundaryEdges: boundary)
    }
}
