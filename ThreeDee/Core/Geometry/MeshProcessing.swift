//
//  MeshProcessing.swift
//  ThreeDee
//
//  Welding, topology, crease-aware normals and feature-edge extraction.
//

import Foundation
import simd

/// Open-addressing hash that maps identical vertex keys to one canonical index.
nonisolated enum PositionWelder {
    @inline(__always)
    private static func bits(_ f: Float) -> UInt32 { f == 0 ? 0 : f.bitPattern }

    @inline(__always)
    private static func hash(_ p: SIMD3<Float>, _ extra: UInt32) -> UInt64 {
        var h = UInt64(bits(p.x)) &* 0x9E37_79B1_85EB_CA87
        h ^= UInt64(bits(p.y)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(bits(p.z)) &* 0x1656_67B1_9E37_79F9
        h ^= UInt64(extra) &* 0x27D4_EB2F_1656_67C5
        h ^= h >> 29
        return h
    }

    /// Returns, for every vertex, the index of the first vertex sharing its position
    /// (and colour, when `colors` is given).
    static func weld(_ positions: [SIMD3<Float>], colors: [RGBA8]? = nil) -> (canonical: [Int32], unique: Int) {
        let n = positions.count
        guard n > 0 else { return ([], 0) }
        var capacity = 1
        while capacity < n * 2 { capacity <<= 1 }
        let mask = UInt64(capacity - 1)
        var table = [Int32](repeating: -1, count: capacity)
        var canonical = [Int32](repeating: 0, count: n)
        var unique = 0
        let useColor = colors != nil && colors!.count == n

        positions.withUnsafeBufferPointer { pos in
            for i in 0..<n {
                let p = pos[i]
                var extra: UInt32 = 0
                if useColor {
                    let c = colors![i]
                    extra = UInt32(c.r) | UInt32(c.g) << 8 | UInt32(c.b) << 16 | UInt32(c.a) << 24
                }
                var slot = Int(hash(p, extra) & mask)
                while true {
                    let existing = table[slot]
                    if existing < 0 {
                        table[slot] = Int32(i)
                        canonical[i] = Int32(i)
                        unique += 1
                        break
                    }
                    let q = pos[Int(existing)]
                    let qx = q.x == 0 ? 0 : q.x, px = p.x == 0 ? 0 : p.x
                    if qx == px && q.y == p.y && q.z == p.z && (!useColor || colors![Int(existing)] == colors![i]) {
                        canonical[i] = existing
                        break
                    }
                    slot = (slot + 1) & Int(mask)
                }
            }
        }
        return (canonical, unique)
    }
}

/// Edge adjacency over a position-welded version of a triangle mesh.
nonisolated struct MeshTopology {
    /// Canonical (welded) vertex index per original vertex.
    let canonical: [Int32]
    /// Sorted edge records: (min canonical, max canonical) packed + triangle index.
    private let edgeKeys: [UInt64]
    private let edgeTris: [Int32]

    init(mesh: Mesh) {
        canonical = PositionWelder.weld(mesh.positions).canonical
        let triCount = mesh.indices.count / 3
        var records: [(UInt64, Int32)] = []
        records.reserveCapacity(triCount * 3)
        for t in 0..<triCount {
            for k in 0..<3 {
                let a = UInt64(UInt32(bitPattern: canonical[Int(mesh.indices[t * 3 + k])]))
                let b = UInt64(UInt32(bitPattern: canonical[Int(mesh.indices[t * 3 + (k + 1) % 3])]))
                if a == b { continue }
                records.append((a < b ? (a << 32 | b) : (b << 32 | a), Int32(t)))
            }
        }
        records.sort { $0.0 < $1.0 }
        edgeKeys = records.map(\.0)
        edgeTris = records.map(\.1)
    }

    /// Calls `body` once per unique edge with the canonical endpoints and adjacent triangles.
    func forEachEdge(_ body: (_ a: Int, _ b: Int, _ triangles: ArraySlice<Int32>) -> Void) {
        var i = 0
        while i < edgeKeys.count {
            var j = i + 1
            while j < edgeKeys.count && edgeKeys[j] == edgeKeys[i] { j += 1 }
            let key = edgeKeys[i]
            body(Int(key >> 32), Int(key & 0xFFFF_FFFF), edgeTris[i..<j])
            i = j
        }
    }

    var boundaryEdgeCount: Int {
        var count = 0
        forEachEdge { _, _, tris in if tris.count == 1 { count += 1 } }
        return count
    }
}

nonisolated enum MeshProcessing {
    static func faceNormals(_ mesh: Mesh) -> [SIMD3<Float>] {
        let triCount = mesh.indices.count / 3
        var result = [SIMD3<Float>](repeating: .zero, count: triCount)
        mesh.positions.withUnsafeBufferPointer { p in
            mesh.indices.withUnsafeBufferPointer { idx in
                for t in 0..<triCount {
                    let a = p[Int(idx[t * 3])], b = p[Int(idx[t * 3 + 1])], c = p[Int(idx[t * 3 + 2])]
                    result[t] = simd_cross(b - a, c - a) // area weighted
                }
            }
        }
        return result
    }

    /// Computes per-vertex normals, splitting vertices along creases sharper than `creaseAngle`
    /// so hard CAD edges stay crisp while curved scans shade smoothly.
    static func withCreaseNormals(_ mesh: Mesh, creaseAngle: Float = 40 * .pi / 180) -> Mesh {
        guard !mesh.indices.isEmpty else { return mesh }
        let triCount = mesh.indices.count / 3
        let weld = PositionWelder.weld(mesh.positions, colors: mesh.hasColors ? mesh.colors : nil)
        let canonical = weld.canonical
        let fn = faceNormals(mesh)
        let fu = fn.map { n -> SIMD3<Float> in
            let l = simd_length(n)
            return l > 0 ? n / l : .zero
        }

        // CSR: canonical vertex -> incident triangles.
        let vCount = mesh.positions.count
        var start = [Int32](repeating: 0, count: vCount + 1)
        for i in mesh.indices { start[Int(canonical[Int(i)]) + 1] += 1 }
        for v in 0..<vCount { start[v + 1] += start[v] }
        var fill = start
        var incident = [Int32](repeating: 0, count: mesh.indices.count)
        for t in 0..<triCount {
            for k in 0..<3 {
                let v = Int(canonical[Int(mesh.indices[t * 3 + k])])
                incident[Int(fill[v])] = Int32(t)
                fill[v] += 1
            }
        }

        let cosCrease = cos(creaseAngle)
        var outPositions: [SIMD3<Float>] = []
        var outNormals: [SIMD3<Float>] = []
        var outColors: [RGBA8] = []
        var outIndices = [UInt32](repeating: 0, count: mesh.indices.count)
        outPositions.reserveCapacity(weld.unique + weld.unique / 4)
        outNormals.reserveCapacity(weld.unique + weld.unique / 4)

        // Per canonical vertex, the output vertices created so far (linked through `nextOut`).
        var firstOut = [Int32](repeating: -1, count: vCount)
        var nextOut: [Int32] = []
        nextOut.reserveCapacity(weld.unique + weld.unique / 4)

        for t in 0..<triCount {
            let ft = fu[t]
            for k in 0..<3 {
                let original = Int(mesh.indices[t * 3 + k])
                let v = Int(canonical[original])
                var n = SIMD3<Float>.zero
                if ft == .zero {
                    n = .zero
                } else {
                    for j in Int(start[v])..<Int(start[v + 1]) {
                        let g = Int(incident[j])
                        if simd_dot(ft, fu[g]) >= cosCrease { n += fn[g] }
                    }
                }
                let len = simd_length(n)
                n = len > 0 ? n / len : ft
                // Reuse an existing output vertex with (nearly) the same normal.
                var found: Int32 = -1
                var cursor = firstOut[v]
                while cursor >= 0 {
                    if simd_dot(outNormals[Int(cursor)], n) > 0.9999 { found = cursor; break }
                    cursor = nextOut[Int(cursor)]
                }
                if found < 0 {
                    found = Int32(outPositions.count)
                    outPositions.append(mesh.positions[original])
                    outNormals.append(n)
                    if mesh.hasColors { outColors.append(mesh.colors[original]) }
                    nextOut.append(firstOut[v])
                    firstOut[v] = found
                }
                outIndices[t * 3 + k] = UInt32(found)
            }
        }
        return Mesh(positions: outPositions, normals: outNormals, colors: outColors, indices: outIndices)
    }

    /// Line segments (pairs of points) along boundaries and edges sharper than `angle`.
    static func featureEdges(_ mesh: Mesh, topology: MeshTopology, angle: Float = 35 * .pi / 180,
                             limit: Int = 3_000_000) -> [SIMD3<Float>] {
        guard !mesh.indices.isEmpty else { return [] }
        let fn = faceNormals(mesh).map { n -> SIMD3<Float> in
            let l = simd_length(n)
            return l > 0 ? n / l : .zero
        }
        let cosAngle = cos(angle)
        var lines: [SIMD3<Float>] = []
        topology.forEachEdge { a, b, tris in
            guard lines.count < limit else { return }
            var feature = false
            if tris.count != 2 {
                feature = true
            } else {
                let n0 = fn[Int(tris[tris.startIndex])], n1 = fn[Int(tris[tris.startIndex + 1])]
                feature = simd_dot(n0, n1) < cosAngle
            }
            if feature {
                lines.append(mesh.positions[a])
                lines.append(mesh.positions[b])
            }
        }
        return lines
    }
}

/// Everything the viewer needs, computed once off the main thread.
nonisolated struct PreparedMesh: Sendable {
    /// Identity for change detection in the UI.
    let id = UUID()
    var mesh: Mesh
    var edgeLines: [SIMD3<Float>]
    var bounds: BoundingBox
    var statistics: MeshStatistics

    static func prepare(_ source: Mesh) -> PreparedMesh {
        var mesh = source
        mesh.sanitize()
        if mesh.isPointCloud {
            return PreparedMesh(mesh: mesh, edgeLines: [], bounds: mesh.bounds(),
                                statistics: MeshStatistics(surfaceArea: 0, volume: 0, isClosed: false, boundaryEdges: 0))
        }
        let topology = MeshTopology(mesh: mesh)
        let edges = MeshProcessing.featureEdges(mesh, topology: topology)
        let stats = MeshStatistics.compute(mesh, topology: topology)
        if !mesh.hasNormals || mesh.normals.contains(where: { $0 == .zero }) {
            mesh = MeshProcessing.withCreaseNormals(mesh)
        }
        return PreparedMesh(mesh: mesh, edgeLines: edges, bounds: mesh.bounds(), statistics: stats)
    }
}
