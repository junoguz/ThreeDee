//
//  Earcut.swift
//  ThreeDee
//
//  Polygon-with-holes triangulation. A Swift port of the ear-clipping
//  algorithm popularised by mapbox/earcut (ISC licence), using index-based
//  linked lists for speed.
//

import Foundation

nonisolated struct Earcut {
    private var xs: [Double] = []
    private var ys: [Double] = []
    private var vi: [Int] = []       // original vertex index
    private var prev: [Int] = []
    private var next: [Int] = []
    private var steiner: [Bool] = []
    private var points: [SIMD2<Double>] = []
    private var triangles: [Int] = []

    /// Triangulates `rings[0]` (outer) minus the remaining rings (holes).
    /// Rings index into `points`. Returns triangle vertex indices.
    static func triangulate(points: [SIMD2<Double>], rings: [[Int]]) -> [Int] {
        guard let outer = rings.first, outer.count >= 3 else { return [] }
        var e = Earcut()
        e.points = points
        guard var outerNode = e.linkedList(outer, clockwise: true) else { return [] }
        if e.next[outerNode] == e.prev[outerNode] { return [] }
        if rings.count > 1 {
            outerNode = e.eliminateHoles(Array(rings.dropFirst()), outerNode)
        }
        e.earcutLinked(outerNode, pass: 0)
        return e.triangles
    }

    // MARK: Nodes

    private mutating func makeNode(_ index: Int) -> Int {
        let n = xs.count
        xs.append(points[index].x)
        ys.append(points[index].y)
        vi.append(index)
        prev.append(n)
        next.append(n)
        steiner.append(false)
        return n
    }

    private mutating func insertNode(_ index: Int, after last: Int?) -> Int {
        let p = makeNode(index)
        if let last {
            next[p] = next[last]
            prev[p] = last
            prev[next[last]] = p
            next[last] = p
        }
        return p
    }

    private mutating func removeNode(_ p: Int) {
        next[prev[p]] = next[p]
        prev[next[p]] = prev[p]
    }

    @inline(__always) private func equals(_ a: Int, _ b: Int) -> Bool { xs[a] == xs[b] && ys[a] == ys[b] }

    @inline(__always) private func area(_ p: Int, _ q: Int, _ r: Int) -> Double {
        (ys[q] - ys[p]) * (xs[r] - xs[q]) - (xs[q] - xs[p]) * (ys[r] - ys[q])
    }

    private func signedArea(_ ring: [Int]) -> Double {
        var sum = 0.0
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = points[ring[j]], b = points[ring[i]]
            sum += (a.x - b.x) * (b.y + a.y)
            j = i
        }
        return sum
    }

    private mutating func linkedList(_ ring: [Int], clockwise: Bool) -> Int? {
        var last: Int? = nil
        if clockwise == (signedArea(ring) > 0) {
            for i in ring { last = insertNode(i, after: last) }
        } else {
            for i in ring.reversed() { last = insertNode(i, after: last) }
        }
        if let l = last, equals(l, next[l]) {
            let n = next[l]
            removeNode(l)
            last = n
        }
        return last
    }

    private mutating func filterPoints(_ start: Int?, _ endIn: Int? = nil) -> Int? {
        guard let start else { return nil }
        var end = endIn ?? start
        var p = start
        var again: Bool
        repeat {
            again = false
            if !steiner[p] && (equals(p, next[p]) || area(prev[p], p, next[p]) == 0) {
                removeNode(p)
                p = prev[p]
                end = p
                if p == next[p] { break }
                again = true
            } else {
                p = next[p]
            }
        } while again || p != end
        return end
    }

    // MARK: Main loop

    private mutating func earcutLinked(_ start: Int?, pass: Int) {
        guard var ear = start else { return }
        var stop = ear
        var guardCounter = 0
        while prev[ear] != next[ear] {
            guardCounter += 1
            if guardCounter > 10_000_000 { return }
            let pv = prev[ear], nx = next[ear]
            if isEar(ear) {
                triangles.append(vi[pv]); triangles.append(vi[ear]); triangles.append(vi[nx])
                removeNode(ear)
                ear = next[nx]
                stop = next[nx]
                continue
            }
            ear = nx
            if ear == stop {
                if pass == 0 {
                    earcutLinked(filterPoints(ear), pass: 1)
                } else if pass == 1 {
                    let cured = cureLocalIntersections(filterPoints(ear) ?? ear)
                    earcutLinked(cured, pass: 2)
                } else if pass == 2 {
                    splitEarcut(ear)
                }
                break
            }
        }
    }

    private func isEar(_ ear: Int) -> Bool {
        let a = prev[ear], b = ear, c = next[ear]
        if area(a, b, c) >= 0 { return false }
        let ax = xs[a], bx = xs[b], cx = xs[c], ay = ys[a], by = ys[b], cy = ys[c]
        let x0 = min(ax, bx, cx), y0 = min(ay, by, cy), x1 = max(ax, bx, cx), y1 = max(ay, by, cy)
        var p = next[c]
        while p != a {
            if xs[p] >= x0 && xs[p] <= x1 && ys[p] >= y0 && ys[p] <= y1 &&
                pointInTriangle(ax, ay, bx, by, cx, cy, xs[p], ys[p]) &&
                area(prev[p], p, next[p]) >= 0 { return false }
            p = next[p]
        }
        return true
    }

    @inline(__always) private func pointInTriangle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                                                   _ cx: Double, _ cy: Double, _ px: Double, _ py: Double) -> Bool {
        (cx - px) * (ay - py) >= (ax - px) * (cy - py) &&
        (ax - px) * (by - py) >= (bx - px) * (ay - py) &&
        (bx - px) * (cy - py) >= (cx - px) * (by - py)
    }

    private mutating func cureLocalIntersections(_ startIn: Int) -> Int? {
        var start = startIn
        var p = start
        repeat {
            let a = prev[p], b = next[next[p]]
            if !equals(a, b) && intersects(a, p, next[p], b) && locallyInside(a, b) && locallyInside(b, a) {
                triangles.append(vi[a]); triangles.append(vi[p]); triangles.append(vi[b])
                removeNode(p)
                removeNode(next[p])
                p = b
                start = b
            }
            p = next[p]
        } while p != start
        return filterPoints(p)
    }

    private mutating func splitEarcut(_ start: Int) {
        var a = start
        repeat {
            var b = next[next[a]]
            while b != prev[a] {
                if vi[a] != vi[b] && isValidDiagonal(a, b) {
                    var c = splitPolygon(a, b)
                    let fa = filterPoints(a, next[a]) ?? a
                    c = filterPoints(c, next[c]) ?? c
                    earcutLinked(fa, pass: 0)
                    earcutLinked(c, pass: 0)
                    return
                }
                b = next[b]
            }
            a = next[a]
        } while a != start
    }

    // MARK: Holes

    private mutating func eliminateHoles(_ holes: [[Int]], _ outerIn: Int) -> Int {
        var queue: [Int] = []
        for ring in holes where ring.count >= 3 {
            guard let list = linkedList(ring, clockwise: false) else { continue }
            if list == next[list] { steiner[list] = true }
            queue.append(leftmost(list))
        }
        queue.sort { xs[$0] < xs[$1] || (xs[$0] == xs[$1] && ys[$0] < ys[$1]) }
        var outer = outerIn
        for h in queue { outer = eliminateHole(h, outer) }
        return outer
    }

    private mutating func eliminateHole(_ hole: Int, _ outer: Int) -> Int {
        guard let bridge = findHoleBridge(hole, outer) else { return outer }
        let bridgeReverse = splitPolygon(bridge, hole)
        _ = filterPoints(bridgeReverse, next[bridgeReverse])
        return filterPoints(bridge, next[bridge]) ?? bridge
    }

    private func findHoleBridge(_ hole: Int, _ outer: Int) -> Int? {
        var p = outer
        let hx = xs[hole], hy = ys[hole]
        var qx = -Double.infinity
        var m: Int? = nil
        repeat {
            let n = next[p]
            if hy <= ys[p] && hy >= ys[n] && ys[n] != ys[p] {
                let x = xs[p] + (hy - ys[p]) * (xs[n] - xs[p]) / (ys[n] - ys[p])
                if x <= hx && x > qx {
                    qx = x
                    m = xs[p] < xs[n] ? p : n
                    if x == hx { return m }
                }
            }
            p = n
        } while p != outer
        guard var best = m else { return nil }
        let stop = best
        let mx = xs[best], my = ys[best]
        var tanMin = Double.infinity
        p = best
        repeat {
            if hx >= xs[p] && xs[p] >= mx && hx != xs[p] &&
                pointInTriangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, xs[p], ys[p]) {
                let tan = abs(hy - ys[p]) / (hx - xs[p])
                if locallyInside(p, hole) &&
                    (tan < tanMin || (tan == tanMin && (xs[p] > xs[best] || (xs[p] == xs[best] && sectorContainsSector(best, p))))) {
                    best = p
                    tanMin = tan
                }
            }
            p = next[p]
        } while p != stop
        return best
    }

    private func sectorContainsSector(_ m: Int, _ p: Int) -> Bool {
        area(prev[m], m, prev[p]) < 0 && area(next[p], m, next[m]) < 0
    }

    private func leftmost(_ start: Int) -> Int {
        var p = start, best = start
        repeat {
            if xs[p] < xs[best] || (xs[p] == xs[best] && ys[p] < ys[best]) { best = p }
            p = next[p]
        } while p != start
        return best
    }

    // MARK: Predicates

    private func isValidDiagonal(_ a: Int, _ b: Int) -> Bool {
        vi[next[a]] != vi[b] && vi[prev[a]] != vi[b] && !intersectsPolygon(a, b) &&
        ((locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b) &&
          (area(prev[a], a, prev[b]) != 0 || area(a, prev[b], b) != 0)) ||
         (equals(a, b) && area(prev[a], a, next[a]) > 0 && area(prev[b], b, next[b]) > 0))
    }

    @inline(__always) private func sign(_ v: Double) -> Int { v > 0 ? 1 : (v < 0 ? -1 : 0) }

    private func onSegment(_ p: Int, _ q: Int, _ r: Int) -> Bool {
        xs[q] <= max(xs[p], xs[r]) && xs[q] >= min(xs[p], xs[r]) && ys[q] <= max(ys[p], ys[r]) && ys[q] >= min(ys[p], ys[r])
    }

    private func intersects(_ p1: Int, _ q1: Int, _ p2: Int, _ q2: Int) -> Bool {
        let o1 = sign(area(p1, q1, p2)), o2 = sign(area(p1, q1, q2))
        let o3 = sign(area(p2, q2, p1)), o4 = sign(area(p2, q2, q1))
        if o1 != o2 && o3 != o4 { return true }
        if o1 == 0 && onSegment(p1, p2, q1) { return true }
        if o2 == 0 && onSegment(p1, q2, q1) { return true }
        if o3 == 0 && onSegment(p2, p1, q2) { return true }
        if o4 == 0 && onSegment(p2, q1, q2) { return true }
        return false
    }

    private func intersectsPolygon(_ a: Int, _ b: Int) -> Bool {
        var p = a
        repeat {
            let n = next[p]
            if vi[p] != vi[a] && vi[n] != vi[a] && vi[p] != vi[b] && vi[n] != vi[b] && intersects(p, n, a, b) { return true }
            p = n
        } while p != a
        return false
    }

    private func locallyInside(_ a: Int, _ b: Int) -> Bool {
        area(prev[a], a, next[a]) < 0
            ? area(a, b, next[a]) >= 0 && area(a, prev[a], b) >= 0
            : area(a, b, prev[a]) < 0 || area(a, next[a], b) < 0
    }

    private func middleInside(_ a: Int, _ b: Int) -> Bool {
        var p = a
        var inside = false
        let px = (xs[a] + xs[b]) / 2, py = (ys[a] + ys[b]) / 2
        repeat {
            let n = next[p]
            if (ys[p] > py) != (ys[n] > py) && ys[n] != ys[p] &&
                px < (xs[n] - xs[p]) * (py - ys[p]) / (ys[n] - ys[p]) + xs[p] {
                inside.toggle()
            }
            p = n
        } while p != a
        return inside
    }

    private mutating func splitPolygon(_ a: Int, _ b: Int) -> Int {
        let a2 = makeNode(vi[a]), b2 = makeNode(vi[b])
        xs[a2] = xs[a]; ys[a2] = ys[a]; xs[b2] = xs[b]; ys[b2] = ys[b]
        let an = next[a], bp = prev[b]
        next[a] = b; prev[b] = a
        next[a2] = an; prev[an] = a2
        next[b2] = a2; prev[a2] = b2
        next[bp] = b2; prev[b2] = bp
        return b2
    }
}
