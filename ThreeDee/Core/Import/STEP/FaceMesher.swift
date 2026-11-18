//
//  FaceMesher.swift
//  ThreeDee
//
//  Triangulates one trimmed B-rep face: boundary loops are mapped into the
//  surface's parameter space (handling seams, poles and full revolutions),
//  triangulated there, refined until the chords follow the true surface, and
//  mapped back to 3D. Boundary vertices keep their exact 3D positions so
//  neighbouring faces meet without cracks.
//

import Foundation
import simd

nonisolated struct FaceInput {
    var surface: any Surface
    /// Boundary loops in 3D, oriented according to their FACE_BOUND flags; not closed (last != first).
    var loops: [[V3]]
    /// Degenerate VERTEX_LOOP bounds (cone apex, sphere pole).
    var vertexLoops: [V3]
    var sameSense: Bool
}

nonisolated struct FaceOutput {
    var positions: [V3] = []
    var normals: [V3] = []
    var triangles: [Int32] = []
}

nonisolated enum FaceMesher {
    private struct Ring {
        var uv: [V2]
        var xyz: [V3]
    }

    static func mesh(_ input: FaceInput, tolerance: Double, maxAngle: Double) -> FaceOutput? {
        let s = input.surface
        let periods = [s.uPeriod, s.vPeriod]

        func unwrap(_ value: Double, near ref: Double, _ period: Double?) -> Double {
            guard let period, period > 0 else { return value }
            return value + period * ((ref - value) / period).rounded()
        }

        // 1. Map loops into UV with continuous unwrapping and pole handling.
        var regular: [Ring] = []
        var wrapping: [(ring: Ring, axis: Int, dir: Int)] = []

        for loop3D in input.loops {
            var pts = dedupe(loop3D, tolerance: tolerance * 1e-3)
            guard pts.count >= 2 else { continue }
            var raw = pts.map { s.uv(of: $0, near: nil) }
            var singular = raw.map { s.isSingular($0) }
            if singular.allSatisfy({ $0 }) { continue }
            // Rotate so the loop starts on a regular point.
            if let first = singular.firstIndex(of: false), first > 0 {
                pts = Array(pts[first...] + pts[..<first])
                raw = Array(raw[first...] + raw[..<first])
                singular = Array(singular[first...] + singular[..<first])
            }
            // Refine each point's UV near its predecessor (better for numeric inversions) and unwrap.
            var uv: [V2] = []
            var last = raw[0]
            for (i, p) in pts.enumerated() {
                var q = i == 0 ? raw[0] : s.uv(of: p, near: last)
                if !(q.x.isFinite && q.y.isFinite) { q = raw[i] }
                if i > 0 {
                    q.x = unwrap(q.x, near: last.x, periods[0])
                    q.y = unwrap(q.y, near: last.y, periods[1])
                }
                uv.append(q)
                if !singular[i] { last = q }
            }
            // Replace singular points by a run along the degenerate line between neighbours.
            var ring = Ring(uv: [], xyz: [])
            for i in uv.indices {
                if !singular[i] {
                    ring.uv.append(uv[i]); ring.xyz.append(pts[i])
                    continue
                }
                let prevU = ring.uv.last?.x ?? uv[i].x
                var j = (i + 1) % uv.count
                while singular[j] && j != i { j = (j + 1) % uv.count }
                var nextU = uv[j].x
                if j <= i { nextU = unwrap(nextU, near: prevU, periods[0]) } // wrapped around the start
                let span = nextU - prevU
                let steps = max(1, Int(ceil(abs(span) / maxAngle)))
                for k in 0...steps {
                    ring.uv.append(V2(prevU + span * Double(k) / Double(steps), uv[i].y))
                    ring.xyz.append(pts[i])
                }
            }
            guard ring.uv.count >= 2 else { continue }
            // Winding across the seam.
            let first = ring.uv[0], end = ring.uv[ring.uv.count - 1]
            let closeU = unwrap(first.x, near: end.x, periods[0])
            let closeV = unwrap(first.y, near: end.y, periods[1])
            let wu = periods[0].map { Int(((closeU - first.x) / $0).rounded()) } ?? 0
            let wv = periods[1].map { Int(((closeV - first.y) / $0).rounded()) } ?? 0
            if wu != 0 {
                wrapping.append((ring, 0, wu > 0 ? 1 : -1))
            } else if wv != 0 {
                wrapping.append((ring, 1, wv > 0 ? 1 : -1))
            } else if ring.uv.count >= 3 {
                regular.append(ring)
            }
        }

        // 2. Assemble an outer ring plus holes in UV.
        var outer: Ring
        var holes: [Ring] = []
        let metric = s.metric

        func scaledArea(_ r: Ring) -> Double {
            var a = 0.0
            for i in r.uv.indices {
                let p = r.uv[i] * metric, q = r.uv[(i + 1) % r.uv.count] * metric
                a += p.x * q.y - q.x * p.y
            }
            return a * 0.5
        }

        if let w1 = wrapping.first {
            let axis = w1.axis
            guard let period = periods[axis] else { return nil }
            let other = 1 - axis
            // The cap coordinate (other axis) when the face closes at a pole/apex.
            func capCoordinate(for w: (ring: Ring, axis: Int, dir: Int)) -> Double? {
                if let apex = input.vertexLoops.first {
                    return s.uv(of: apex, near: nil)[other]
                }
                if let cone = s as? ConeSurface, axis == 0 { return cone.apexV }
                let sense: Double = input.sameSense ? 1 : -1
                // Region lies to the left of the loop in UV; left of +u is +v, left of +v is -u.
                let towardsMax = axis == 0 ? Double(w.dir) * sense > 0 : -Double(w.dir) * sense > 0
                let bounds = other == 1 ? s.vBounds : s.uBounds
                guard let bounds else { return nil }
                return towardsMax ? bounds.upperBound : bounds.lowerBound
            }

            let partner = wrapping.dropFirst().first { $0.axis == axis }
            var l1 = w1
            var band = Ring(uv: [], xyz: [])
            if var l2 = partner {
                if l1.dir == l2.dir { // inconsistent orientation in the file; flip one
                    l2.ring.uv.reverse(); l2.ring.xyz.reverse(); l2.dir = -l2.dir
                    l2.ring = reunwrap(l2.ring, periods: periods)
                }
                if l1.dir < 0 { swap(&l1, &l2) }
                // L1 runs +period; append its closing point shifted by one period.
                band.uv = l1.ring.uv; band.xyz = l1.ring.xyz
                var close = l1.ring.uv[0]; close[axis] += period
                band.uv.append(close); band.xyz.append(l1.ring.xyz[0])
                // L2 runs -period; start it at the vertex nearest L1's end.
                let target = close[axis]
                var bestIndex = 0, bestDist = Double.infinity
                for (i, q) in l2.ring.uv.enumerated() {
                    let d = abs(unwrap(q[axis], near: target, period) - target)
                    if d < bestDist { bestDist = d; bestIndex = i }
                }
                var rotated = Ring(uv: Array(l2.ring.uv[bestIndex...] + l2.ring.uv[..<bestIndex]),
                                   xyz: Array(l2.ring.xyz[bestIndex...] + l2.ring.xyz[..<bestIndex]))
                rotated = reunwrap(rotated, periods: periods)
                let shift = unwrap(rotated.uv[0][axis], near: target, period) - rotated.uv[0][axis]
                for i in rotated.uv.indices { rotated.uv[i][axis] += shift }
                var close2 = rotated.uv[0]; close2[axis] -= period
                band.uv += rotated.uv; band.xyz += rotated.xyz
                band.uv.append(close2); band.xyz.append(rotated.xyz[0])
            } else {
                guard let cap = capCoordinate(for: l1) else { return nil }
                band.uv = l1.ring.uv; band.xyz = l1.ring.xyz
                var close = l1.ring.uv[0]; close[axis] += Double(l1.dir) * period
                band.uv.append(close); band.xyz.append(l1.ring.xyz[0])
                // Walk back along the degenerate cap line.
                let steps = max(2, Int(ceil(period / maxAngle)))
                let a0 = close[axis], a1 = l1.ring.uv[0][axis]
                for k in 0...steps {
                    var q = V2.zero
                    q[axis] = a0 + (a1 - a0) * Double(k) / Double(steps)
                    q[other] = cap
                    band.uv.append(q)
                    band.xyz.append(s.point(q))
                }
            }
            outer = band
            holes = regular
        } else if !regular.isEmpty {
            let order = regular.indices.sorted { abs(scaledArea(regular[$0])) > abs(scaledArea(regular[$1])) }
            outer = regular[order[0]]
            holes = order.dropFirst().map { regular[$0] }
        } else if input.loops.isEmpty, let ub = s.uBounds ?? (s.uPeriod.map { 0...$0 }),
                  let vb = s.vBounds ?? (s.vPeriod.map { 0...$0 }) {
            // Closed surface with no trimming (full sphere / torus).
            outer = Ring(uv: [], xyz: [])
            let nu = max(4, Int(ceil((ub.upperBound - ub.lowerBound) * metric.x / max(tolerance * 20, 1e-9))))
            let nv = max(4, Int(ceil((vb.upperBound - vb.lowerBound) * metric.y / max(tolerance * 20, 1e-9))))
            let cu = min(nu, 64), cv = min(nv, 64)
            for i in 0..<cu { outer.uv.append(V2(ub.lowerBound + (ub.upperBound - ub.lowerBound) * Double(i) / Double(cu), vb.lowerBound)) }
            for j in 0..<cv { outer.uv.append(V2(ub.upperBound, vb.lowerBound + (vb.upperBound - vb.lowerBound) * Double(j) / Double(cv))) }
            for i in 0..<cu { outer.uv.append(V2(ub.upperBound - (ub.upperBound - ub.lowerBound) * Double(i) / Double(cu), vb.upperBound)) }
            for j in 0..<cv { outer.uv.append(V2(ub.lowerBound, vb.upperBound - (vb.upperBound - vb.lowerBound) * Double(j) / Double(cv))) }
            outer.xyz = outer.uv.map { s.point($0) }
        } else {
            return nil
        }

        // Move holes into the same period window as the outer ring.
        if periods[0] != nil || periods[1] != nil {
            for h in holes.indices {
                holes[h] = shiftInside(holes[h], outer: outer, periods: periods)
            }
        }

        // 3. Triangulate in metric-scaled UV.
        var uv: [V2] = []
        var xyz: [V3] = []
        var rings: [[Int]] = []
        var boundary = Set<UInt64>()
        for r in [outer] + holes {
            var ring: [Int] = []
            for i in r.uv.indices {
                ring.append(uv.count)
                uv.append(r.uv[i])
                xyz.append(r.xyz[i])
            }
            for i in ring.indices { boundary.insert(edgeKey(ring[i], ring[(i + 1) % ring.count])) }
            rings.append(ring)
        }
        // Along straight generators nothing needs resolving, so compress that direction until the
        // whole face spans about one boundary step; Delaunay then zips opposite boundaries together
        // instead of cutting chords through the solid.
        var triangulationMetric = metric
        if s.straightAlongV, uv.count > 2 {
            var lo = uv[0], hi = uv[0]
            for q in uv { lo = simd_min(lo, q); hi = simd_max(hi, q) }
            var steps: [Double] = []
            for r in rings {
                for i in r.indices {
                    let d = simd_length((uv[r[i]] - uv[r[(i + 1) % r.count]]) * metric)
                    if d > 0 { steps.append(d) }
                }
            }
            steps.sort()
            let step = steps.isEmpty ? 0 : steps[steps.count / 2]
            let vExtent = (hi.y - lo.y) * metric.y
            if step > 0 && vExtent > step { triangulationMetric.y *= step / vExtent }
        }
        let scaled = uv.map { $0 * triangulationMetric }
        let tri = Earcut.triangulate(points: scaled, rings: rings)
        guard tri.count >= 3 else { return nil }

        var mesh = Refiner(surface: s, uv: uv, xyz: xyz, boundary: boundary, triangles: tri, metric: triangulationMetric)
        if !s.isPlanar {
            mesh.refine(tolerance: tolerance, maxAngle: maxAngle)
        }

        // 4. Normals and consistent orientation.
        let sense: Double = input.sameSense ? 1 : -1
        var out = FaceOutput()
        out.positions = mesh.xyz
        out.normals = mesh.uv.map { q -> V3 in
            let n = s.normal(q) * sense
            return n.x.isFinite ? n : V3(0, 0, 1)
        }
        out.triangles.reserveCapacity(mesh.tris.count * 3)
        for t in mesh.tris {
            let a = Int(t.x), b = Int(t.y), c = Int(t.z)
            let g = simd_cross(out.positions[b] - out.positions[a], out.positions[c] - out.positions[a])
            if simd_length_squared(g) == 0 { continue }
            let n = out.normals[a] + out.normals[b] + out.normals[c]
            if simd_dot(g, n) < 0 {
                out.triangles += [t.x, t.z, t.y]
            } else {
                out.triangles += [t.x, t.y, t.z]
            }
        }
        return out.triangles.isEmpty ? nil : out
    }

    // MARK: Helpers

    @inline(__always) static func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
        a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a)
    }

    private static func dedupe(_ pts: [V3], tolerance: Double) -> [V3] {
        var out: [V3] = []
        out.reserveCapacity(pts.count)
        for p in pts where out.last.map({ simd_distance($0, p) > tolerance }) ?? true { out.append(p) }
        while out.count > 1, let f = out.first, let l = out.last, simd_distance(f, l) <= tolerance { out.removeLast() }
        return out
    }

    private static func reunwrap(_ r: Ring, periods: [Double?]) -> Ring {
        var out = r
        for i in 1..<max(out.uv.count, 1) {
            for axis in 0..<2 {
                if let p = periods[axis] {
                    out.uv[i][axis] += p * ((out.uv[i - 1][axis] - out.uv[i][axis]) / p).rounded()
                }
            }
        }
        return out
    }

    private static func pointInPolygon(_ p: V2, _ poly: [V2]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func shiftInside(_ hole: Ring, outer: Ring, periods: [Double?]) -> Ring {
        let centroid = hole.uv.reduce(V2.zero, +) / Double(hole.uv.count)
        let pu = periods[0] ?? 0, pv = periods[1] ?? 0
        let ks: [Int] = [0, -1, 1, -2, 2]
        for ku in (pu > 0 ? ks : [0]) {
            for kv in (pv > 0 ? ks : [0]) {
                let shift = V2(Double(ku) * pu, Double(kv) * pv)
                if pointInPolygon(centroid + shift, outer.uv) || pointInPolygon(hole.uv[0] + shift, outer.uv) {
                    var moved = hole
                    for i in moved.uv.indices { moved.uv[i] += shift }
                    return moved
                }
            }
        }
        return hole
    }
}

/// Refinement of a UV triangulation by Delaunay insertion: edges whose chords
/// stray from the true surface are bisected and the triangulation is kept
/// (constrained) Delaunay in metric-scaled UV with Lawson flips. Boundary edges
/// are fixed so neighbouring faces stay watertight.
nonisolated struct Refiner {
    let surface: any Surface
    var uv: [V2]
    var xyz: [V3]
    var normals: [V3]
    var tris: [SIMD3<Int32>]
    let boundary: Set<UInt64>
    private let metric: V2
    /// S(uv) per vertex. Equal to `xyz` except on boundary vertices whose parameter
    /// inversion carries a residual; refinement measures against these so it converges.
    private var onSurface: [V3]
    private var edges: [UInt64: SIMD2<Int32>] = [:]
    private var dirty: [Int] = []
    private var frozen = Set<UInt64>()

    init(surface: any Surface, uv: [V2], xyz: [V3], boundary: Set<UInt64>, triangles: [Int], metric: V2) {
        self.surface = surface
        self.uv = uv
        self.xyz = xyz
        self.boundary = boundary
        self.metric = metric
        normals = uv.map { surface.normal($0) }
        onSurface = uv.map { surface.point($0) }
        tris = []
        tris.reserveCapacity(triangles.count / 3)
        var i = 0
        while i + 2 < triangles.count {
            tris.append(SIMD3(Int32(triangles[i]), Int32(triangles[i + 1]), Int32(triangles[i + 2])))
            i += 3
        }
    }

    // MARK: Edge bookkeeping

    private mutating func addEdge(_ a: Int32, _ b: Int32, _ t: Int32) {
        let key = FaceMesher.edgeKey(Int(a), Int(b))
        var e = edges[key] ?? SIMD2(-1, -1)
        if e.x < 0 { e.x = t } else if e.y < 0 && e.x != t { e.y = t }
        edges[key] = e
    }

    private mutating func replaceEdgeTriangle(_ a: Int32, _ b: Int32, _ old: Int32, _ new: Int32) {
        let key = FaceMesher.edgeKey(Int(a), Int(b))
        guard var e = edges[key] else { return }
        if e.x == old { e.x = new } else if e.y == old { e.y = new }
        edges[key] = e
    }

    private mutating func addVertex(_ q: V2) -> Int32 {
        let p = surface.point(q)
        uv.append(q)
        xyz.append(p)
        onSurface.append(p)
        normals.append(surface.normal(q))
        return Int32(uv.count - 1)
    }

    /// Rotates triangle `t` so that its first two vertices are the edge {a, b}; returns the opposite vertex.
    private func opposite(_ t: Int, _ a: Int32, _ b: Int32) -> (SIMD3<Int32>)? {
        var tri = tris[t]
        for _ in 0..<3 {
            if (tri.x == a && tri.y == b) || (tri.x == b && tri.y == a) { return tri }
            tri = SIMD3(tri.y, tri.z, tri.x)
        }
        return nil
    }

    @inline(__always) private func m(_ i: Int32) -> V2 { uv[Int(i)] * metric }

    @inline(__always) private func orient(_ a: Int32, _ b: Int32, _ c: Int32) -> Double {
        let pa = m(a), pb = m(b), pc = m(c)
        return (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
    }

    /// True when `d` lies strictly inside the circumcircle of triangle (a, b, c).
    private func inCircle(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32) -> Bool {
        let pa = m(a) - m(d), pb = m(b) - m(d), pc = m(c) - m(d)
        let det = (pa.x * pa.x + pa.y * pa.y) * (pb.x * pc.y - pc.x * pb.y)
            - (pb.x * pb.x + pb.y * pb.y) * (pa.x * pc.y - pc.x * pa.y)
            + (pc.x * pc.x + pc.y * pc.y) * (pa.x * pb.y - pb.x * pa.y)
        let o = orient(a, b, c)
        let scale = max(simd_length_squared(pa), simd_length_squared(pb), simd_length_squared(pc))
        return det * (o > 0 ? 1 : -1) > 1e-12 * scale * scale
    }

    // MARK: Topological operations

    /// Bisects edge `key`; returns the new vertex and the edges that need legalising.
    @discardableResult
    private mutating func split(_ key: UInt64) -> [UInt64] {
        guard let inc = edges[key] else { return [] }
        let a = Int32(key >> 32), b = Int32(key & 0xFFFF_FFFF)
        let incident = [inc.x, inc.y].filter { $0 >= 0 }.compactMap { t in opposite(Int(t), a, b).map { (t, $0) } }
        guard !incident.isEmpty else {
            frozen.insert(key) // inconsistent topology (degenerate input); never retry
            return []
        }
        let mid = addVertex((uv[Int(a)] + uv[Int(b)]) * 0.5)
        edges[key] = nil
        var toCheck: [UInt64] = []
        for (t, tri) in incident {
            let i = tri.x, j = tri.y, k = tri.z
            let n = Int32(tris.count)
            tris[Int(t)] = SIMD3(i, mid, k)
            tris.append(SIMD3(mid, j, k))
            addEdge(i, mid, t)
            addEdge(mid, k, t)
            addEdge(mid, k, n)
            addEdge(mid, j, n)
            replaceEdgeTriangle(j, k, t, n)
            dirty.append(Int(t)); dirty.append(Int(n))
            toCheck.append(FaceMesher.edgeKey(Int(i), Int(k)))
            toCheck.append(FaceMesher.edgeKey(Int(j), Int(k)))
        }
        return toCheck
    }

    /// Inserts the centroid of triangle `t`; returns the edges that need legalising.
    private mutating func insertCentroid(_ t: Int) -> [UInt64] {
        let tri = tris[t]
        let c = addVertex((uv[Int(tri.x)] + uv[Int(tri.y)] + uv[Int(tri.z)]) / 3)
        let n1 = Int32(tris.count), n2 = n1 + 1, ti = Int32(t)
        tris[t] = SIMD3(tri.x, tri.y, c)
        tris.append(SIMD3(tri.y, tri.z, c))
        tris.append(SIMD3(tri.z, tri.x, c))
        replaceEdgeTriangle(tri.y, tri.z, ti, n1)
        replaceEdgeTriangle(tri.z, tri.x, ti, n2)
        addEdge(tri.x, c, ti); addEdge(tri.y, c, ti)
        addEdge(tri.y, c, n1); addEdge(tri.z, c, n1)
        addEdge(tri.z, c, n2); addEdge(tri.x, c, n2)
        dirty += [t, Int(n1), Int(n2)]
        return [FaceMesher.edgeKey(Int(tri.x), Int(tri.y)), FaceMesher.edgeKey(Int(tri.y), Int(tri.z)),
                FaceMesher.edgeKey(Int(tri.z), Int(tri.x))]
    }

    /// Lawson flips until the touched region is constrained-Delaunay again.
    private mutating func legalize(_ initial: [UInt64]) {
        var stack = initial
        var budget = 20_000
        while let key = stack.popLast(), budget > 0 {
            budget -= 1
            guard !boundary.contains(key), let inc = edges[key], inc.x >= 0, inc.y >= 0 else { continue }
            let a = Int32(key >> 32), b = Int32(key & 0xFFFF_FFFF)
            guard let t1 = opposite(Int(inc.x), a, b), let t2 = opposite(Int(inc.y), a, b) else { continue }
            // t1 = (p, q, c) with edge p→q, t2 = (q, p, d).
            let p = t1.x, q = t1.y, c = t1.z
            let d = t2.z
            guard c != d, edges[FaceMesher.edgeKey(Int(c), Int(d))] == nil, inCircle(p, q, c, d) else { continue }
            // Only flip convex quads (both new triangles keep the original orientation).
            // Only flip strictly convex quads; near-collinear configurations (common along
            // straight trimming edges with inversion jitter) would otherwise undo bisections.
            let o = orient(p, q, c)
            let o1 = orient(c, p, d), o2 = orient(d, q, c)
            let span = max(simd_length_squared(m(p) - m(q)), simd_length_squared(m(c) - m(d)))
            let eps = 1e-9 * span
            guard o1 * o > 0, o2 * o > 0, abs(o1) > eps, abs(o2) > eps, abs(o) > eps,
                  abs(orient(q, p, d)) > eps else { continue }
            let i1 = inc.x, i2 = inc.y
            tris[Int(i1)] = SIMD3(c, p, d)
            tris[Int(i2)] = SIMD3(d, q, c)
            edges[key] = nil
            edges[FaceMesher.edgeKey(Int(c), Int(d))] = SIMD2(i1, i2)
            replaceEdgeTriangle(q, c, i1, i2)
            replaceEdgeTriangle(p, d, i2, i1)
            dirty.append(Int(i1)); dirty.append(Int(i2))
            stack.append(FaceMesher.edgeKey(Int(p), Int(c)))
            stack.append(FaceMesher.edgeKey(Int(q), Int(c)))
            stack.append(FaceMesher.edgeKey(Int(p), Int(d)))
            stack.append(FaceMesher.edgeKey(Int(q), Int(d)))
        }
    }

    // MARK: Refinement

    /// The worst offending interior edge of `t`, or `centroid` when only the interior bulges.
    private enum Defect { case none, edge(UInt64), centroid }

    private func defect(_ t: Int, tolerance: Double, cosMax: Double, minLength: Double) -> Defect {
        let tri = tris[t]
        // Degenerate (collinear in UV) triangles cannot be improved by bisection.
        let e2 = max(simd_length_squared(m(tri.x) - m(tri.y)), simd_length_squared(m(tri.y) - m(tri.z)),
                     simd_length_squared(m(tri.z) - m(tri.x)))
        if abs(orient(tri.x, tri.y, tri.z)) <= 1e-9 * e2 { return .none }
        var worst: UInt64? = nil
        var worstScore = 0.0
        var longest = 0.0
        for (a, b) in [(Int(tri.x), Int(tri.y)), (Int(tri.y), Int(tri.z)), (Int(tri.z), Int(tri.x))] {
            let len = simd_distance(onSurface[a], onSurface[b])
            longest = max(longest, len, simd_length((uv[a] - uv[b]) * metric))
            let key = FaceMesher.edgeKey(a, b)
            if boundary.contains(key) || frozen.contains(key) { continue }
            // Degenerate in parameter space: bisecting cannot improve it.
            if simd_length((uv[a] - uv[b]) * metric) < tolerance * 1e-3 { continue }
            let mid = surface.point((uv[a] + uv[b]) * 0.5)
            let dev = simd_distance(mid, (onSurface[a] + onSurface[b]) * 0.5)
            var score = dev / tolerance
            if len > tolerance * 4 {
                let cosAngle = simd_dot(normals[a], normals[b])
                if cosAngle < cosMax { score = max(score, 1 + (cosMax - cosAngle) * 100) }
            }
            if score > 1 && score > worstScore { worstScore = score; worst = key }
        }
        if let worst { return .edge(worst) }
        if longest < minLength { return .none }
        let a = Int(tri.x), b = Int(tri.y), c = Int(tri.z)
        let centroid: V2 = (uv[a] + uv[b] + uv[c]) / 3
        let flat: V3 = (onSurface[a] + onSurface[b] + onSurface[c]) / 3
        return simd_distance(surface.point(centroid), flat) > tolerance ? .centroid : .none
    }

    mutating func refine(tolerance: Double, maxAngle: Double) {
        for (t, tri) in tris.enumerated() {
            addEdge(tri.x, tri.y, Int32(t)); addEdge(tri.y, tri.z, Int32(t)); addEdge(tri.z, tri.x, Int32(t))
        }
        // Start from the constrained Delaunay triangulation of the boundary.
        legalize(Array(edges.keys.filter { !boundary.contains($0) }).sorted())

        // Boundary curves are cut at exactly `maxAngle`; leave headroom so diagonals between
        // neighbouring boundary samples are not split for being marginally over.
        let cosMax = cos(maxAngle * 1.75)
        let maxVertices = 25_000
        let minLength = tolerance * 0.5
        var work = Array(tris.indices.reversed())
        dirty.removeAll()
        var iterations = 0
        while let t = work.popLast() {
            iterations += 1
            if uv.count >= maxVertices || iterations > 2_000_000 { return }
            switch defect(t, tolerance: tolerance, cosMax: cosMax, minLength: minLength) {
            case .none:
                continue
            case .edge(let key):
                legalize(split(key))
            case .centroid:
                legalize(insertCentroid(t))
            }
            work.append(contentsOf: dirty)
            dirty.removeAll(keepingCapacity: true)
        }
    }
}
