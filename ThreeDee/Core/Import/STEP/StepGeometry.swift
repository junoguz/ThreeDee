//
//  StepGeometry.swift
//  ThreeDee
//
//  Analytic and NURBS curves/surfaces used by STEP boundary representations.
//

import Foundation
import simd

typealias V3 = SIMD3<Double>
typealias V2 = SIMD2<Double>

nonisolated struct Frame3 {
    var origin: V3
    var x: V3
    var y: V3
    var z: V3

    static let identity = Frame3(origin: .zero, x: V3(1, 0, 0), y: V3(0, 1, 0), z: V3(0, 0, 1))

    init(origin: V3, x: V3, y: V3, z: V3) {
        self.origin = origin; self.x = x; self.y = y; self.z = z
    }

    /// Builds a right-handed orthonormal frame from an axis and an approximate x direction.
    init(origin: V3, axis: V3?, refDirection: V3?) {
        var z = axis.map { simd_normalize($0) } ?? V3(0, 0, 1)
        if !(z.x.isFinite && z.y.isFinite && z.z.isFinite) || simd_length(z) < 0.5 { z = V3(0, 0, 1) }
        var x = refDirection ?? V3(1, 0, 0)
        x -= simd_dot(x, z) * z
        if simd_length(x) < 1e-9 {
            x = abs(z.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0)
            x -= simd_dot(x, z) * z
        }
        x = simd_normalize(x)
        self.init(origin: origin, x: x, y: simd_cross(z, x), z: z)
    }

    @inline(__always) func toWorld(_ p: V3) -> V3 { origin + p.x * x + p.y * y + p.z * z }
    @inline(__always) func toLocal(_ p: V3) -> V3 {
        let d = p - origin
        return V3(simd_dot(d, x), simd_dot(d, y), simd_dot(d, z))
    }

    var matrix: simd_double4x4 {
        simd_double4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(origin, 1))
    }
}

// MARK: - B-spline basis

nonisolated struct KnotVector {
    let degree: Int
    let knots: [Double]
    let controlCount: Int

    var lower: Double { knots[degree] }
    var upper: Double { knots[controlCount] }

    /// Expands STEP (multiplicities, knots) into a full knot vector, repairing common inconsistencies.
    init(degree: Int, multiplicities: [Int], values: [Double], controlCount: Int) {
        self.degree = max(1, degree)
        self.controlCount = controlCount
        var expanded: [Double] = []
        for (m, v) in zip(multiplicities, values) { expanded += Array(repeating: v, count: max(0, m)) }
        let required = controlCount + self.degree + 1
        if expanded.count != required || expanded.isEmpty {
            if expanded.count > required {
                let extra = expanded.count - required
                expanded = Array(expanded.dropFirst(extra / 2).dropLast(extra - extra / 2))
            } else if expanded.count >= 2 {
                while expanded.count < required {
                    expanded.insert(expanded.first!, at: 0)
                    if expanded.count < required { expanded.append(expanded.last!) }
                }
            } else {
                expanded = KnotVector.clampedUniform(degree: self.degree, count: controlCount)
            }
        }
        knots = expanded
    }

    init(degree: Int, knots: [Double], controlCount: Int) {
        self.degree = degree
        self.knots = knots
        self.controlCount = controlCount
    }

    static func clampedUniform(degree: Int, count: Int) -> [Double] {
        let interior = max(0, count - degree - 1)
        var k = [Double](repeating: 0, count: degree + 1)
        for i in 0..<interior { k.append(Double(i + 1) / Double(interior + 1)) }
        k += [Double](repeating: 1, count: degree + 1)
        return k
    }

    static func uniform(degree: Int, count: Int) -> [Double] {
        (0..<(count + degree + 1)).map { Double($0 - degree) }
    }

    func span(_ t: Double) -> Int {
        let n = controlCount - 1
        if t >= knots[n + 1] { return n }
        if t <= knots[degree] { return degree }
        var low = degree, high = n + 1
        var mid = (low + high) / 2
        while t < knots[mid] || t >= knots[mid + 1] {
            if t < knots[mid] { high = mid } else { low = mid }
            mid = (low + high) / 2
            if high - low <= 1 { return low }
        }
        return mid
    }

    /// Non-zero basis functions N[span-p … span] at t (Piegl & Tiller A2.2), written into `out`
    /// (capacity ≥ degree + 1) without heap allocation.
    @inline(__always)
    func basis(_ span: Int, _ t: Double, _ out: UnsafeMutablePointer<Double>) {
        let p = degree
        out[0] = 1
        if p == 0 { return }
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 2 * (p + 1)) { scratch in
            let left = scratch.baseAddress!, right = scratch.baseAddress! + (p + 1)
            knots.withUnsafeBufferPointer { k in
                for j in 1...p {
                    left[j] = t - k[span + 1 - j]
                    right[j] = k[span + j] - t
                    var saved = 0.0
                    for r in 0..<j {
                        let denom = right[r + 1] + left[j - r]
                        let temp = denom != 0 ? out[r] / denom : 0
                        out[r] = saved + right[r + 1] * temp
                        saved = left[j - r] * temp
                    }
                    out[j] = saved
                }
            }
        }
    }

    /// Number of distinct non-empty knot spans inside [a, b].
    func spanCount(from a: Double, to b: Double) -> Int {
        let lo = min(a, b), hi = max(a, b)
        var count = 0
        for i in degree..<controlCount where knots[i + 1] > knots[i] && knots[i + 1] > lo && knots[i] < hi { count += 1 }
        return max(1, count)
    }
}

// MARK: - Curves

nonisolated protocol Curve3 {
    func point(_ t: Double) -> V3
    var domain: ClosedRange<Double> { get }
    /// Period of a closed, periodic parameterisation.
    var period: Double? { get }
    func parameter(of p: V3) -> Double
    /// Points from `t0` to `t1` (inclusive) within the chord tolerance.
    func discretize(from t0: Double, to t1: Double, tolerance: Double, maxAngle: Double) -> [V3]
}

nonisolated extension Curve3 {
    var period: Double? { nil }

    func parameter(of p: V3) -> Double { projectBySampling(p) }

    func projectBySampling(_ p: V3, samples: Int = 64) -> Double {
        var lo = domain.lowerBound, hi = domain.upperBound
        if !lo.isFinite || !hi.isFinite || hi - lo > 1e6 { lo = -1e3; hi = 1e3 }
        var bestT = lo, bestD = Double.infinity
        let n = max(8, samples)
        for i in 0...n {
            let t = lo + (hi - lo) * Double(i) / Double(n)
            let d = simd_distance_squared(point(t), p)
            if d < bestD { bestD = d; bestT = t }
        }
        // Golden-section refinement in the neighbouring interval.
        var a = max(lo, bestT - (hi - lo) / Double(n)), b = min(hi, bestT + (hi - lo) / Double(n))
        let g = 0.618_033_988_749_895
        var c = b - g * (b - a), d = a + g * (b - a)
        var fc = simd_distance_squared(point(c), p), fd = simd_distance_squared(point(d), p)
        for _ in 0..<60 {
            if fc < fd { b = d; d = c; fd = fc; c = b - g * (b - a); fc = simd_distance_squared(point(c), p) } else {
                a = c; c = d; fc = fd; d = a + g * (b - a); fd = simd_distance_squared(point(d), p)
            }
            if b - a < 1e-12 * max(1, abs(a)) { break }
        }
        return (a + b) / 2
    }

    func discretize(from t0: Double, to t1: Double, tolerance: Double, maxAngle: Double) -> [V3] {
        adaptiveDiscretize(from: t0, to: t1, initialSegments: 8, tolerance: tolerance, maxAngle: maxAngle)
    }

    func adaptiveDiscretize(from t0: Double, to t1: Double, initialSegments: Int, tolerance: Double, maxAngle: Double) -> [V3] {
        let n = max(1, min(initialSegments, 4096))
        var params = (0...n).map { t0 + (t1 - t0) * Double($0) / Double(n) }
        var pts = params.map { point($0) }
        var result: [V3] = [pts[0]]
        let cosMax = cos(maxAngle)
        var budget = 20_000
        func refine(_ ta: Double, _ pa: V3, _ tb: Double, _ pb: V3, _ depth: Int) {
            let tm = (ta + tb) / 2
            let pm = point(tm)
            let chord = pb - pa
            let dev = simd_length(pm - (pa + pb) * 0.5)
            var bend = false
            let la = simd_length(pm - pa), lb = simd_length(pb - pm)
            if la > tolerance && lb > tolerance {
                bend = simd_dot((pm - pa) / la, (pb - pm) / lb) < cosMax
            }
            if depth < 14 && budget > 0 && (dev > tolerance || bend) && simd_length(chord) > tolerance * 0.05 {
                budget -= 1
                refine(ta, pa, tm, pm, depth + 1)
                result.append(pm)
                refine(tm, pm, tb, pb, depth + 1)
            }
        }
        for i in 0..<n {
            refine(params[i], pts[i], params[i + 1], pts[i + 1], 0)
            result.append(pts[i + 1])
        }
        params.removeAll(); pts.removeAll()
        return result
    }
}

nonisolated struct LineCurve: Curve3 {
    var origin: V3
    var direction: V3
    var domain: ClosedRange<Double> { -1e12...1e12 }
    func point(_ t: Double) -> V3 { origin + t * direction }
    func parameter(of p: V3) -> Double {
        let dd = simd_length_squared(direction)
        return dd > 0 ? simd_dot(p - origin, direction) / dd : 0
    }
    func discretize(from t0: Double, to t1: Double, tolerance: Double, maxAngle: Double) -> [V3] { [point(t0), point(t1)] }
}

nonisolated struct EllipseCurve: Curve3 {
    var frame: Frame3
    var a: Double
    var b: Double
    var domain: ClosedRange<Double> { 0...(2 * .pi) }
    var period: Double? { 2 * .pi }

    func point(_ t: Double) -> V3 { frame.origin + a * cos(t) * frame.x + b * sin(t) * frame.y }

    func parameter(of p: V3) -> Double {
        let l = frame.toLocal(p)
        var t = atan2(l.y / max(b, 1e-300), l.x / max(a, 1e-300))
        if t < 0 { t += 2 * .pi }
        return t
    }

    func discretize(from t0: Double, to t1: Double, tolerance: Double, maxAngle: Double) -> [V3] {
        let r = max(a, b)
        var step = maxAngle
        if r > tolerance { step = min(step, 2 * acos(max(-1, 1 - tolerance / r))) }
        let n = max(1, Int(ceil(abs(t1 - t0) / max(step, 1e-4))))
        return (0...min(n, 10_000)).map { point(t0 + (t1 - t0) * Double($0) / Double(min(n, 10_000))) }
    }
}

nonisolated struct BSplineCurve: Curve3 {
    let knots: KnotVector
    let controlPoints: [V3]
    let weights: [Double]?
    let period: Double?

    init(knots: KnotVector, controlPoints: [V3], weights: [Double]?, closed: Bool) {
        self.knots = knots
        self.controlPoints = controlPoints
        self.weights = weights
        var period: Double? = nil
        if closed, let f = controlPoints.first, let l = controlPoints.last {
            let size = controlPoints.reduce(0.0) { max($0, simd_length($1 - f)) }
            if simd_distance(f, l) <= 1e-7 * max(1, size) { period = knots.upper - knots.lower }
        }
        self.period = period
    }

    var domain: ClosedRange<Double> { knots.lower...knots.upper }

    func point(_ t: Double) -> V3 {
        let p = knots.degree
        var tt = t
        if let period, period > 0 {
            tt = knots.lower + (t - knots.lower).truncatingRemainder(dividingBy: period)
            if tt < knots.lower { tt += period }
        }
        tt = min(max(tt, knots.lower), knots.upper)
        let span = knots.span(tt)
        return withUnsafeTemporaryAllocation(of: Double.self, capacity: p + 1) { buffer in
            let n = buffer.baseAddress!
            knots.basis(span, tt, n)
            var acc = V3.zero
            var w = 0.0
            for i in 0...p {
                let idx = span - p + i
                guard idx >= 0 && idx < controlPoints.count else { continue }
                let wi = weights?[idx] ?? 1
                acc += n[i] * wi * controlPoints[idx]
                w += n[i] * wi
            }
            return w != 0 ? acc / w : acc
        }
    }

    func parameter(of p: V3) -> Double {
        projectBySampling(p, samples: max(64, controlPoints.count * 8))
    }

    func discretize(from t0: Double, to t1: Double, tolerance: Double, maxAngle: Double) -> [V3] {
        let spans = knots.spanCount(from: t0, to: t1)
        return adaptiveDiscretize(from: t0, to: t1, initialSegments: min(spans * max(2, knots.degree), 2048),
                                  tolerance: tolerance, maxAngle: maxAngle)
    }
}

nonisolated struct PolylineCurve: Curve3 {
    var points: [V3]
    var domain: ClosedRange<Double> { 0...Double(max(points.count - 1, 0)) }

    func point(_ t: Double) -> V3 {
        guard points.count > 1 else { return points.first ?? .zero }
        let c = min(max(t, 0), Double(points.count - 1))
        let i = min(Int(c), points.count - 2)
        return simd_mix(points[i], points[i + 1], V3(repeating: c - Double(i)))
    }

    func parameter(of p: V3) -> Double {
        var best = 0.0, bestD = Double.infinity
        for i in 0..<max(points.count - 1, 0) {
            let a = points[i], b = points[i + 1]
            let ab = b - a
            let l2 = simd_length_squared(ab)
            let f = l2 > 0 ? min(max(simd_dot(p - a, ab) / l2, 0), 1) : 0
            let d = simd_distance_squared(a + f * ab, p)
            if d < bestD { bestD = d; best = Double(i) + f }
        }
        return best
    }

    func discretize(from t0: Double, to t1: Double, tolerance: Double, maxAngle: Double) -> [V3] {
        var out = [point(t0)]
        if t1 >= t0 {
            var i = Int(floor(t0)) + 1
            while Double(i) < t1 { out.append(points[i]); i += 1 }
        } else {
            var i = Int(ceil(t0)) - 1
            while Double(i) > t1 { out.append(points[i]); i -= 1 }
        }
        out.append(point(t1))
        return out
    }
}

/// A 2D curve living in a surface's parameter space (PCURVE).
nonisolated struct SurfaceCurve: Curve3 {
    var surface: any Surface
    var curve2D: any Curve3 // z component ignored
    var domain: ClosedRange<Double> { curve2D.domain }
    var period: Double? { curve2D.period }
    func point(_ t: Double) -> V3 {
        let q = curve2D.point(t)
        return surface.point(V2(q.x, q.y))
    }
}

// MARK: - Surfaces

nonisolated protocol Surface {
    func point(_ uv: V2) -> V3
    /// Unit normal in the direction of Su × Sv.
    func normal(_ uv: V2) -> V3
    func uv(of p: V3, near hint: V2?) -> V2
    var uPeriod: Double? { get }
    var vPeriod: Double? { get }
    var uBounds: ClosedRange<Double>? { get }
    var vBounds: ClosedRange<Double>? { get }
    /// True where the u parameter degenerates (sphere poles, cone apex).
    func isSingular(_ uv: V2) -> Bool
    /// Approximate arc length per unit of u and v, used to make triangulation isotropic.
    var metric: V2 { get }
    var isPlanar: Bool { get }
    /// True when iso-u lines are straight (cylinders, cones, extrusions): no curvature along v.
    var straightAlongV: Bool { get }
}

nonisolated extension Surface {
    var uPeriod: Double? { nil }
    var vPeriod: Double? { nil }
    var uBounds: ClosedRange<Double>? { nil }
    var vBounds: ClosedRange<Double>? { nil }
    func isSingular(_ uv: V2) -> Bool { false }
    var metric: V2 { V2(1, 1) }
    var isPlanar: Bool { false }
    var straightAlongV: Bool { false }

    func numericNormal(_ uv: V2) -> V3 {
        let h = 1e-6 * max(1, abs(uv.x), abs(uv.y))
        let su = point(uv + V2(h, 0)) - point(uv - V2(h, 0))
        let sv = point(uv + V2(0, h)) - point(uv - V2(0, h))
        var n = simd_cross(su, sv)
        if simd_length(n) < 1e-20 {
            // Degenerate point: sample slightly inside.
            let e = 1e-4
            let su2 = point(uv + V2(h, e)) - point(uv - V2(h, -e))
            let sv2 = point(uv + V2(e, h)) - point(uv - V2(-e, h))
            n = simd_cross(su2, sv2)
        }
        let l = simd_length(n)
        return l > 0 ? n / l : V3(0, 0, 1)
    }

    /// Gauss-Newton closest-point inversion with a grid-search fallback.
    func newtonInverse(_ p: V3, start: V2, uRange: ClosedRange<Double>, vRange: ClosedRange<Double>) -> (V2, Double) {
        var uv = start
        let hu = 1e-7 * max(1, uRange.upperBound - uRange.lowerBound)
        let hv = 1e-7 * max(1, vRange.upperBound - vRange.lowerBound)
        for _ in 0..<20 {
            let s = point(uv)
            let su = (point(uv + V2(hu, 0)) - point(uv - V2(hu, 0))) / (2 * hu)
            let sv = (point(uv + V2(0, hv)) - point(uv - V2(0, hv))) / (2 * hv)
            let r = s - p
            let a = simd_dot(su, su), b = simd_dot(su, sv), c = simd_dot(sv, sv)
            let g1 = simd_dot(su, r), g2 = simd_dot(sv, r)
            let det = a * c - b * b
            var du = 0.0, dv = 0.0
            if abs(det) > 1e-30 {
                du = (c * g1 - b * g2) / det
                dv = (a * g2 - b * g1) / det
            } else {
                if a > 1e-30 { du = g1 / a }
                if c > 1e-30 { dv = g2 / c }
            }
            var next = uv - V2(du, dv)
            if uPeriod == nil { next.x = min(max(next.x, uRange.lowerBound), uRange.upperBound) }
            if vPeriod == nil { next.y = min(max(next.y, vRange.lowerBound), vRange.upperBound) }
            let moved = simd_length(next - uv)
            uv = next
            if moved < 1e-13 * max(1, simd_length(uv)) { break }
        }
        return (uv, simd_distance(point(uv), p))
    }
}

nonisolated struct PlaneSurface: Surface {
    var frame: Frame3
    func point(_ uv: V2) -> V3 { frame.origin + uv.x * frame.x + uv.y * frame.y }
    func normal(_ uv: V2) -> V3 { frame.z }
    func uv(of p: V3, near hint: V2?) -> V2 {
        let d = p - frame.origin
        return V2(simd_dot(d, frame.x), simd_dot(d, frame.y))
    }
    var isPlanar: Bool { true }
}

nonisolated struct CylinderSurface: Surface {
    var frame: Frame3
    var radius: Double
    func point(_ uv: V2) -> V3 {
        frame.origin + radius * (cos(uv.x) * frame.x + sin(uv.x) * frame.y) + uv.y * frame.z
    }
    func normal(_ uv: V2) -> V3 { cos(uv.x) * frame.x + sin(uv.x) * frame.y }
    func uv(of p: V3, near hint: V2?) -> V2 {
        let l = frame.toLocal(p)
        return V2(atan2(l.y, l.x), l.z)
    }
    var uPeriod: Double? { 2 * .pi }
    var metric: V2 { V2(radius, 1) }
    var straightAlongV: Bool { true }
}

nonisolated struct ConeSurface: Surface {
    var frame: Frame3
    var radius: Double
    var semiAngle: Double
    var apexV: Double { abs(tan(semiAngle)) > 1e-12 ? -radius / tan(semiAngle) : -.infinity }

    func rho(_ v: Double) -> Double { radius + v * tan(semiAngle) }
    func point(_ uv: V2) -> V3 {
        frame.origin + rho(uv.y) * (cos(uv.x) * frame.x + sin(uv.x) * frame.y) + uv.y * frame.z
    }
    func normal(_ uv: V2) -> V3 {
        let radial = cos(uv.x) * frame.x + sin(uv.x) * frame.y
        let s: Double = rho(uv.y) >= 0 ? 1 : -1
        return simd_normalize(s * (radial - tan(semiAngle) * frame.z))
    }
    func uv(of p: V3, near hint: V2?) -> V2 {
        let l = frame.toLocal(p)
        // Project onto the generator through the point's azimuth.
        let theta = atan2(l.y, l.x)
        let r = sqrt(l.x * l.x + l.y * l.y)
        let t = tan(semiAngle)
        // Nearest point on the generator through this azimuth, for either nappe of the cone.
        let a = V2(theta, (l.z + (r - radius) * t) / (1 + t * t))
        let b = V2(theta + .pi, (l.z + (-r - radius) * t) / (1 + t * t))
        return simd_distance(point(a), p) <= simd_distance(point(b), p) ? a : b
    }
    func isSingular(_ uv: V2) -> Bool { abs(rho(uv.y)) < 1e-9 * max(1, radius) + 1e-12 }
    var uPeriod: Double? { 2 * .pi }
    var metric: V2 { V2(max(radius, 1e-6), 1 / max(cos(semiAngle), 1e-6)) }
    var straightAlongV: Bool { true }
}

nonisolated struct SphereSurface: Surface {
    var frame: Frame3
    var radius: Double
    func point(_ uv: V2) -> V3 {
        let c = cos(uv.y)
        return frame.origin + radius * (c * (cos(uv.x) * frame.x + sin(uv.x) * frame.y) + sin(uv.y) * frame.z)
    }
    func normal(_ uv: V2) -> V3 {
        let c = cos(uv.y)
        return c * (cos(uv.x) * frame.x + sin(uv.x) * frame.y) + sin(uv.y) * frame.z
    }
    func uv(of p: V3, near hint: V2?) -> V2 {
        let l = frame.toLocal(p)
        let r = simd_length(l)
        return V2(atan2(l.y, l.x), asin(min(1, max(-1, r > 0 ? l.z / r : 0))))
    }
    func isSingular(_ uv: V2) -> Bool { abs(abs(uv.y) - .pi / 2) < 1e-7 }
    var uPeriod: Double? { 2 * .pi }
    var vBounds: ClosedRange<Double>? { (-Double.pi / 2)...(Double.pi / 2) }
    var metric: V2 { V2(radius, radius) }
}

nonisolated struct TorusSurface: Surface {
    var frame: Frame3
    var major: Double
    var minor: Double
    func point(_ uv: V2) -> V3 {
        let r = major + minor * cos(uv.y)
        return frame.origin + r * (cos(uv.x) * frame.x + sin(uv.x) * frame.y) + minor * sin(uv.y) * frame.z
    }
    func normal(_ uv: V2) -> V3 {
        // Su × Sv carries the sign of the (possibly negative, spindle) tube radius.
        let s: Double = major + minor * cos(uv.y) >= 0 ? 1 : -1
        return s * (cos(uv.y) * (cos(uv.x) * frame.x + sin(uv.x) * frame.y) + sin(uv.y) * frame.z)
    }
    func uv(of p: V3, near hint: V2?) -> V2 {
        let l = frame.toLocal(p)
        let r = sqrt(l.x * l.x + l.y * l.y)
        let theta = atan2(l.y, l.x)
        // A spindle torus (minor > major) reaches points through a negative tube radius,
        // i.e. with the azimuth flipped by π; keep whichever solution reproduces the point.
        let a = V2(theta, atan2(l.z, r - major))
        let b = V2(theta + .pi, atan2(l.z, -r - major))
        let da = simd_distance(point(a), p), db = simd_distance(point(b), p)
        let scale = 1e-9 * (major + minor)
        if abs(da - db) <= scale, let hint {
            func dist(_ q: V2) -> Double {
                let du = remainder(q.x - hint.x, 2 * .pi), dv = remainder(q.y - hint.y, 2 * .pi)
                return du * du + dv * dv
            }
            return dist(a) <= dist(b) ? a : b
        }
        return da <= db ? a : b
    }
    func isSingular(_ uv: V2) -> Bool { abs(major + minor * cos(uv.y)) < 1e-9 }
    var uPeriod: Double? { 2 * .pi }
    var vPeriod: Double? { 2 * .pi }
    var metric: V2 { V2(major + minor, minor) }
}

/// Surfaces without a closed-form inverse share a cached sample grid for initial guesses.
nonisolated final class SampleGrid {
    let uv: [V2]
    let points: [V3]
    init(surface: any Surface, u: ClosedRange<Double>, v: ClosedRange<Double>, n: Int = 24) {
        var uvs: [V2] = [], pts: [V3] = []
        for i in 0...n {
            for j in 0...n {
                let q = V2(u.lowerBound + (u.upperBound - u.lowerBound) * Double(i) / Double(n),
                           v.lowerBound + (v.upperBound - v.lowerBound) * Double(j) / Double(n))
                uvs.append(q)
                pts.append(surface.point(q))
            }
        }
        uv = uvs
        points = pts
    }
    func nearest(_ p: V3) -> V2 {
        var best = 0, bestD = Double.infinity
        for (i, q) in points.enumerated() {
            let d = simd_distance_squared(q, p)
            if d < bestD { bestD = d; best = i }
        }
        return uv[best]
    }
}

nonisolated final class BSplineSurface: Surface {
    let uKnots: KnotVector
    let vKnots: KnotVector
    let control: [[V3]] // [u][v]
    let weights: [[Double]]?
    let uClosed: Bool
    let vClosed: Bool
    private var cachedGrid: SampleGrid?
    private let characteristicSize: Double
    private(set) var metric = V2(1, 1)
    private(set) var uPeriod: Double? = nil
    private(set) var vPeriod: Double? = nil

    private var grid: SampleGrid {
        if let cachedGrid { return cachedGrid }
        let g = SampleGrid(surface: self, u: uRange, v: vRange)
        cachedGrid = g
        return g
    }

    init(uKnots: KnotVector, vKnots: KnotVector, control: [[V3]], weights: [[Double]]?, uClosed: Bool, vClosed: Bool) {
        self.uKnots = uKnots
        self.vKnots = vKnots
        self.control = control
        self.weights = weights
        self.uClosed = uClosed
        self.vClosed = vClosed
        var box = (V3(repeating: .infinity), V3(repeating: -.infinity))
        for row in control { for p in row { box.0 = simd_min(box.0, p); box.1 = simd_max(box.1, p) } }
        characteristicSize = simd_length(box.1 - box.0)
        uPeriod = closedInU() ? uRange.upperBound - uRange.lowerBound : nil
        vPeriod = closedInV() ? vRange.upperBound - vRange.lowerBound : nil
        metric = computeMetric()
    }

    var uRange: ClosedRange<Double> { uKnots.lower...uKnots.upper }
    var vRange: ClosedRange<Double> { vKnots.lower...vKnots.upper }

    private func closedInU() -> Bool {
        guard uClosed, let first = control.first, let last = control.last else { return false }
        return zip(first, last).allSatisfy { simd_distance($0, $1) <= 1e-6 * max(1, characteristicSize) }
    }

    private func closedInV() -> Bool {
        guard vClosed else { return false }
        return control.allSatisfy { row in
            guard let f = row.first, let l = row.last else { return false }
            return simd_distance(f, l) <= 1e-6 * max(1, characteristicSize)
        }
    }

    var uBounds: ClosedRange<Double>? { uRange }
    var vBounds: ClosedRange<Double>? { vRange }

    private func computeMetric() -> V2 {
        let du = max(uRange.upperBound - uRange.lowerBound, 1e-12)
        let dv = max(vRange.upperBound - vRange.lowerBound, 1e-12)
        // Average control-polygon extent per parameter unit.
        var lu = 0.0, lv = 0.0
        if let row = control.first, let col = control.last {
            for j in 0..<row.count where control.count > 1 { lu += simd_distance(control[0][j], control[control.count - 1][j]) }
            lu /= Double(max(row.count, 1))
            for i in 0..<control.count where col.count > 1 { lv += simd_distance(control[i][0], control[i][col.count - 1]) }
            lv /= Double(max(control.count, 1))
        }
        return V2(max(lu / du, 1e-9), max(lv / dv, 1e-9))
    }

    @inline(__always) private func wrap(_ x: Double, _ range: ClosedRange<Double>, _ period: Double?) -> Double {
        var t = x
        if let period, period > 0 {
            t = range.lowerBound + (x - range.lowerBound).truncatingRemainder(dividingBy: period)
            if t < range.lowerBound { t += period }
        }
        return min(max(t, range.lowerBound), range.upperBound)
    }

    func isSingular(_ uv: V2) -> Bool {
        let h = 1e-6 * max(1, uRange.upperBound - uRange.lowerBound)
        let su = point(uv + V2(h, 0)) - point(uv - V2(h, 0))
        return simd_length(su) / (2 * h) < metric.x * 1e-7
    }

    func point(_ uv: V2) -> V3 {
        let u = wrap(uv.x, uRange, uPeriod)
        let v = wrap(uv.y, vRange, vPeriod)
        let p = uKnots.degree, q = vKnots.degree
        let su = uKnots.span(u), sv = vKnots.span(v)
        return withUnsafeTemporaryAllocation(of: Double.self, capacity: p + q + 2) { buffer in
            let nu = buffer.baseAddress!, nv = buffer.baseAddress! + (p + 1)
            uKnots.basis(su, u, nu)
            vKnots.basis(sv, v, nv)
            var acc = V3.zero
            var w = 0.0
            for i in 0...p {
                let ui = su - p + i
                guard ui >= 0 && ui < control.count else { continue }
                control[ui].withUnsafeBufferPointer { row in
                    for j in 0...q {
                        let vj = sv - q + j
                        guard vj >= 0 && vj < row.count else { continue }
                        let wij = weights?[ui][vj] ?? 1
                        let b = nu[i] * nv[j] * wij
                        acc += b * row[vj]
                        w += b
                    }
                }
            }
            return w != 0 ? acc / w : acc
        }
    }

    func normal(_ uv: V2) -> V3 { numericNormal(uv) }

    func uv(of p: V3, near hint: V2?) -> V2 {
        let tol = 1e-6 * max(1, characteristicSize)
        if let hint {
            let (r, d) = newtonInverse(p, start: hint, uRange: uRange, vRange: vRange)
            if d < tol * 100 { return r }
        }
        let (r, _) = newtonInverse(p, start: grid.nearest(p), uRange: uRange, vRange: vRange)
        return r
    }
}

nonisolated final class RevolutionSurface: Surface {
    let profile: any Curve3
    let axisOrigin: V3
    let axis: V3
    private let frame: Frame3
    private var cachedGrid: SampleGrid?
    private var grid: SampleGrid {
        if let cachedGrid { return cachedGrid }
        let g = SampleGrid(surface: self, u: 0...(2 * .pi), v: vRange)
        cachedGrid = g
        return g
    }

    init(profile: any Curve3, axisOrigin: V3, axis: V3) {
        self.profile = profile
        self.axisOrigin = axisOrigin
        self.axis = simd_normalize(axis)
        // Reference x direction: towards the profile's start point.
        let start = profile.point(profile.domain.lowerBound.isFinite ? max(profile.domain.lowerBound, -1e6) : 0)
        frame = Frame3(origin: axisOrigin, axis: axis, refDirection: start - axisOrigin)
    }

    var vRange: ClosedRange<Double> {
        let d = profile.domain
        return max(d.lowerBound, -1e6)...min(d.upperBound, 1e6)
    }

    func point(_ uv: V2) -> V3 {
        let c = profile.point(uv.y) - axisOrigin
        let along = simd_dot(c, axis) * axis
        let radial = c - along
        let rotated = radial * cos(uv.x) + simd_cross(axis, radial) * sin(uv.x)
        return axisOrigin + along + rotated
    }
    func normal(_ uv: V2) -> V3 { numericNormal(uv) }
    var uPeriod: Double? { 2 * .pi }
    var vBounds: ClosedRange<Double>? { vRange }
    func isSingular(_ uv: V2) -> Bool {
        let c = profile.point(uv.y) - axisOrigin
        return simd_length(c - simd_dot(c, axis) * axis) < 1e-9
    }

    func uv(of p: V3, near hint: V2?) -> V2 {
        if let hint {
            let (r, d) = newtonInverse(p, start: hint, uRange: 0...(2 * .pi), vRange: vRange)
            if d < 1e-5 { return r }
        }
        let (r, _) = newtonInverse(p, start: grid.nearest(p), uRange: 0...(2 * .pi), vRange: vRange)
        return r
    }
}

nonisolated final class ExtrusionSurface: Surface {
    let profile: any Curve3
    let vector: V3

    init(profile: any Curve3, vector: V3) {
        self.profile = profile
        self.vector = vector
    }

    func point(_ uv: V2) -> V3 { profile.point(uv.x) + uv.y * vector }
    func normal(_ uv: V2) -> V3 { numericNormal(uv) }
    var uPeriod: Double? { profile.period }
    var uBounds: ClosedRange<Double>? { profile.domain }
    var straightAlongV: Bool { true }

    func uv(of p: V3, near hint: V2?) -> V2 {
        let d = simd_normalize(vector)
        let vv = simd_length_squared(vector)
        // Project the point along the extrusion direction onto the profile, then refine.
        var u = hint?.x ?? profile.parameter(of: p)
        if hint == nil {
            for _ in 0..<3 {
                let c = profile.point(u)
                let flattened = p - simd_dot(p - c, d) * d
                u = profile.parameter(of: flattened)
            }
        }
        let v = vv > 0 ? simd_dot(p - profile.point(u), vector) / vv : 0
        let du = profile.domain
        let (r, _) = newtonInverse(p, start: V2(u, v), uRange: du, vRange: -1e9...1e9)
        return r
    }
}

nonisolated final class OffsetSurfaceImpl: Surface {
    let basis: any Surface
    let distance: Double
    init(basis: any Surface, distance: Double) { self.basis = basis; self.distance = distance }
    func point(_ uv: V2) -> V3 { basis.point(uv) + distance * basis.normal(uv) }
    func normal(_ uv: V2) -> V3 { basis.normal(uv) }
    var uPeriod: Double? { basis.uPeriod }
    var vPeriod: Double? { basis.vPeriod }
    var uBounds: ClosedRange<Double>? { basis.uBounds }
    var vBounds: ClosedRange<Double>? { basis.vBounds }
    var metric: V2 { basis.metric }
    func isSingular(_ uv: V2) -> Bool { basis.isSingular(uv) }
    func uv(of p: V3, near hint: V2?) -> V2 {
        let guess = basis.uv(of: p, near: hint)
        let (r, _) = newtonInverse(p, start: guess, uRange: basis.uBounds ?? -1e9...1e9, vRange: basis.vBounds ?? -1e9...1e9)
        return r
    }
}
