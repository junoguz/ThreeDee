//
//  GridBuilder.swift
//  ThreeDee
//
//  Metric ground grid. Geometry is in millimetres, so a 10 mm cell is drawn
//  exactly 10 units wide; the grid unit only chooses the base cell (1 mm or
//  1 cm) and how the scale is labelled.
//

import Foundation
import simd

struct GridSpec: Equatable {
    /// Minor and major line spacing in millimetres.
    var minor: Double
    var major: Double
    var unit: GridUnit
    /// Plane height and half-extent (mm).
    var height: Float
    var center: SIMD2<Float>
    var halfExtent: Float
    /// Length of the vertical Z marker (mm).
    var zMarker: Float = 10

    var minorLabel: String { GridSpec.label(minor, unit) }
    var majorLabel: String { GridSpec.label(major, unit) }

    static func label(_ mm: Double, _ unit: GridUnit) -> String {
        let v = mm / unit.millimeters
        let digits = v >= 1 ? 0 : (v >= 0.1 ? 1 : 2)
        return String(format: "%.\(digits)f %@", v, unit.rawValue)
    }

    /// Chooses decade spacing so the grid reads well around the model.
    static func make(for box: BoundingBox, unit: GridUnit) -> GridSpec {
        let size = box.isEmpty ? SIMD3<Float>(repeating: 10) : box.size
        let footprint = Double(max(size.x, size.y, size.z * 0.5, 1e-3))
        let halfExtent = Float(footprint) * 1.6
        // About 10–100 minor cells across the extent; base cell is 1 mm or 1 cm.
        let base = unit.millimeters
        var minor = base
        while Double(halfExtent) * 2 / minor > 100 { minor *= 10 }
        // Small parts: allow decimal subdivisions of the base unit.
        while Double(halfExtent) * 2 / minor < 6 && minor > base / 100 { minor /= 10 }
        let center = box.isEmpty ? SIMD2<Float>(0, 0) : SIMD2(box.center.x, box.center.y)
        return GridSpec(minor: minor, major: minor * 10, unit: unit, height: box.isEmpty ? 0 : box.min.z,
                        center: center, halfExtent: max(halfExtent, Float(minor) * 5),
                        zMarker: max(size.z * 1.25, Float(minor) * 2))
    }

    /// Line vertices as (x, y, z, alpha).
    func vertices() -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = []
        let minorF = Float(minor)
        let lo = center - SIMD2(repeating: halfExtent), hi = center + SIMD2(repeating: halfExtent)
        // Snap to multiples of the minor spacing in world coordinates (true positions).
        let startX = (lo.x / minorF).rounded(.down), endX = (hi.x / minorF).rounded(.up)
        let startY = (lo.y / minorF).rounded(.down), endY = (hi.y / minorF).rounded(.up)
        guard endX - startX < 400, endY - startY < 400 else { return out }
        func alpha(_ index: Float) -> Float {
            let ratio = Float(major / minor)
            if index == 0 { return 0 }  // axes are drawn separately
            return abs(index.truncatingRemainder(dividingBy: ratio)) < 0.5 ? 0.42 : 0.16
        }
        var i = startX
        while i <= endX {
            let x = i * minorF
            let a = alpha(i)
            if a > 0 {
                out.append(SIMD4(x, startY * minorF, height, a))
                out.append(SIMD4(x, endY * minorF, height, a))
            }
            i += 1
        }
        var j = startY
        while j <= endY {
            let y = j * minorF
            let a = alpha(j)
            if a > 0 {
                out.append(SIMD4(startX * minorF, y, height, a))
                out.append(SIMD4(endX * minorF, y, height, a))
            }
            j += 1
        }
        return out
    }

    /// World axes through the origin, at grid height, plus a short vertical Z axis.
    func axisVertices() -> [SIMD4<Float>] {
        let e = halfExtent
        let c = center
        var out: [SIMD4<Float>] = []
        if abs(c.y) < e { out += [SIMD4(c.x - e, 0, height, 0.9), SIMD4(c.x + e, 0, height, 0.9)] }
        if abs(c.x) < e { out += [SIMD4(0, c.y - e, height, 0.9), SIMD4(0, c.y + e, height, 0.9)] }
        out += [SIMD4(0, 0, height, 0.9), SIMD4(0, 0, height + zMarker, 0.9)]
        return out
    }
}
