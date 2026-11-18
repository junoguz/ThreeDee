//
//  StepImporter.swift
//  ThreeDee
//
//  Converts STEP (AP203 / AP214 / AP242) boundary representations,
//  faceted B-reps and AP242 tessellations into a triangle mesh in millimetres,
//  honouring declared units, assembly placements and surface colours.
//

import Foundation
import simd

nonisolated struct StepSummary: Sendable {
    var schema: String = ""
    var unitDescription: String = "millimetre"
    var solids = 0
    var faces = 0
    var skippedFaces = 0
    var instances = 0
}

nonisolated final class StepImporter {
    private let file: StepFile
    private let quality: TessellationQuality
    private var tolerance = 0.01
    private var maxAngle = 0.2
    private var angleFactor = 1.0
    private var summary = StepSummary()

    private var pointCache: [Int: V3] = [:]
    private var frameCache: [Int: Frame3] = [:]
    private var curveCache: [Int: (any Curve3)?] = [:]
    private var surfaceCache: [Int: (any Surface)?] = [:]
    private var edgeCache: [Int: [V3]] = [:]
    private var itemColors: [Int: RGBA8] = [:]
    private var anyColor = false
    private var progress: ((Double) -> Void)?
    private var totalFaces = 1
    private var processedFaces = 0

    private init(file: StepFile, quality: TessellationQuality, progress: ((Double) -> Void)?) {
        self.file = file
        self.quality = quality
        self.progress = progress
    }

    static func load(_ data: Data, quality: TessellationQuality = .standard,
                     progress: ((Double) -> Void)? = nil) throws -> (Mesh, StepSummary) {
        let file = try StepFile(data: data)
        let importer = StepImporter(file: file, quality: quality, progress: progress)
        let mesh = try importer.run()
        return (mesh, importer.summary)
    }

    // MARK: - Driver

    private static let brepItems: Set<String> = ["MANIFOLD_SOLID_BREP", "FACETED_BREP", "BREP_WITH_VOIDS",
                                                 "SHELL_BASED_SURFACE_MODEL", "CLOSED_SHELL", "OPEN_SHELL",
                                                 "ADVANCED_FACE", "FACE_SURFACE", "ORIENTED_CLOSED_SHELL"]
    private static let tessellatedItems: Set<String> = ["TESSELLATED_SHELL", "TESSELLATED_SOLID", "TRIANGULATED_FACE",
                                                        "COMPLEX_TRIANGULATED_FACE", "TRIANGULATED_SURFACE_SET",
                                                        "COMPLEX_TRIANGULATED_SURFACE_SET"]

    private struct Rep {
        var id: Int
        var items: [Int]
        var context: Int?
        var scale: Double
        var hasBrep: Bool
        var hasTessellation: Bool
    }

    private func run() throws -> Mesh {
        summary.schema = file.schema

        // Representations.
        var reps: [Int: Rep] = [:]
        var faceCount = 0
        for id in file.orderedIDs {
            let names = file.names(of: id)
            if names.contains(where: { ["ADVANCED_FACE", "FACE_SURFACE", "FACE", "TRIANGULATED_FACE", "COMPLEX_TRIANGULATED_FACE"].contains($0) }) {
                faceCount += 1
            }
            guard names.contains(where: { $0.hasSuffix("SHAPE_REPRESENTATION") }) else { continue }
            guard let e = file.entity(id) else { continue }
            let args = e.isComplex ? (e.part("REPRESENTATION") ?? e.parts.first { $0.name.hasSuffix("SHAPE_REPRESENTATION") }?.args ?? []) : e.args
            guard args.count >= 2 else { continue }
            let items = args[1].refs
            var hasBrep = false, hasTess = false
            for item in items {
                let n = file.name(of: item)
                if StepImporter.brepItems.contains(n) { hasBrep = true }
                if StepImporter.tessellatedItems.contains(n) { hasTess = true }
            }
            reps[id] = Rep(id: id, items: items, context: args.count > 2 ? args[2].ref : nil, scale: 1, hasBrep: hasBrep, hasTessellation: hasTess)
        }
        totalFaces = max(faceCount, 1)
        summary.faces = faceCount

        // Units: per representation context, falling back to the first length unit in the file.
        var fallbackScale: Double? = nil
        var contextScales: [Int: Double] = [:]
        for (id, rep) in reps {
            guard let ctx = rep.context else { continue }
            if contextScales[ctx] == nil, let s = lengthScale(context: ctx) { contextScales[ctx] = s }
            if let s = contextScales[ctx] {
                reps[id]?.scale = s
                if fallbackScale == nil && (rep.hasBrep || rep.hasTessellation) {
                    fallbackScale = s
                    summary.unitDescription = describe(scale: s)
                    angleFactor = planeAngleFactor(context: ctx) ?? 1
                }
            }
        }
        if fallbackScale == nil {
            for id in file.orderedIDs where file.isType(id, "LENGTH_UNIT") {
                fallbackScale = unitScale(id)
                summary.unitDescription = describe(scale: fallbackScale ?? 1)
                break
            }
        }
        for (id, rep) in reps where rep.context == nil || contextScales[rep.context!] == nil {
            reps[id]?.scale = fallbackScale ?? 1
        }

        computeTolerance()
        collectStyles()

        // Assembly structure.
        var parent: [Int: Int] = [:]
        func find(_ x: Int) -> Int {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for id in reps.keys { parent[id] = id }

        var transformRelations: [(rel: Int, rep1: Int, rep2: Int, transform: Int)] = []
        var pdsOfRelation: [Int: Int] = [:]
        var pdOfRep: [Int: Int] = [:]
        for id in file.orderedIDs {
            let names = file.names(of: id)
            if names.contains("REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION") {
                guard let e = file.entity(id) else { continue }
                let rr = e.part("REPRESENTATION_RELATIONSHIP") ?? e.args
                let rt = e.part("REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION") ?? []
                let transform = e.isComplex ? rt.first?.ref : e[4].ref
                if rr.count >= 4, let r1 = rr[2].ref, let r2 = rr[3].ref, let t = transform {
                    transformRelations.append((id, r1, r2, t))
                }
            } else if names.count == 1 && (names[0] == "SHAPE_REPRESENTATION_RELATIONSHIP" || names[0] == "REPRESENTATION_RELATIONSHIP") {
                if let e = file.entity(id), let r1 = e[2].ref, let r2 = e[3].ref, reps[r1] != nil, reps[r2] != nil {
                    union(r1, r2)
                }
            } else if names.first == "CONTEXT_DEPENDENT_SHAPE_REPRESENTATION" {
                if let e = file.entity(id), let rel = e[0].ref, let pds = e[1].ref { pdsOfRelation[rel] = pds }
            } else if names.first == "SHAPE_DEFINITION_REPRESENTATION" {
                if let e = file.entity(id), let pds = e[0].ref, let rep = e[1].ref,
                   let def = file.entity(pds)?[2].ref, file.name(of: def).hasPrefix("PRODUCT_DEFINITION") {
                    pdOfRep[rep] = def
                }
            }
        }
        var pdOfGroup: [Int: Int] = [:]
        for (rep, pd) in pdOfRep where reps[rep] != nil { pdOfGroup[find(rep)] = pd }

        struct Child { var group: Int; var transform: simd_double4x4 }
        var children: [Int: [Child]] = [:]
        var isChild = Set<Int>()

        for rel in transformRelations {
            guard reps[rel.rep1] != nil, reps[rel.rep2] != nil else { continue }
            var child = rel.rep1, parentRep = rel.rep2
            var reversed = false
            if let pds = pdsOfRelation[rel.rel], let nauo = file.entity(pds)?[2].ref, let n = file.entity(nauo),
               let relating = n[3].ref, let related = n[4].ref {
                if pdOfGroup[find(rel.rep1)] == relating && pdOfGroup[find(rel.rep2)] == related { reversed = true }
            }
            if reversed { swap(&child, &parentRep) }
            guard let d = transformMatrix(rel.transform, childScale: reps[child]!.scale, parentScale: reps[parentRep]!.scale,
                                          reversed: reversed) else { continue }
            children[find(parentRep), default: []].append(Child(group: find(child), transform: d))
            isChild.insert(find(child))
        }

        // MAPPED_ITEM instancing inside representations.
        for (id, rep) in reps {
            for item in rep.items where file.name(of: item) == "MAPPED_ITEM" {
                guard let mi = file.entity(item), let source = mi[1].ref, let target = mi[2].ref,
                      let map = file.entity(source), let origin = map[0].ref, let mapped = map[1].ref,
                      let mappedRep = reps[mapped] else { continue }
                let mo = placementMatrix(origin, scale: mappedRep.scale)
                let mt = placementMatrix(target, scale: rep.scale)
                children[find(id), default: []].append(Child(group: find(mapped), transform: mt * mo.inverse))
                isChild.insert(find(mapped))
            }
        }

        var groupReps: [Int: [Int]] = [:]
        for (id, rep) in reps where rep.hasBrep || rep.hasTessellation { groupReps[find(id), default: []].append(id) }
        // Prefer exact B-rep over an alternative tessellated rendition of the same part.
        for (g, list) in groupReps where list.contains(where: { reps[$0]!.hasBrep }) {
            groupReps[g] = list.filter { reps[$0]!.hasBrep }
        }

        var repMeshes: [Int: Mesh] = [:]
        var emitted = Set<Int>()
        var result = Mesh()

        func meshFor(_ rep: Int) -> Mesh {
            if let m = repMeshes[rep] { return m }
            let r = reps[rep]!
            var m = Mesh()
            for item in r.items { meshItem(item, into: &m, inheritedColor: nil) }
            if r.scale != 1 { m.apply(simd_float4x4(diagonal: SIMD4(Float(r.scale), Float(r.scale), Float(r.scale), 1))) }
            repMeshes[rep] = m
            return m
        }

        func emit(group: Int, transform: simd_double4x4, depth: Int) {
            guard depth < 32 else { return }
            for rep in groupReps[group] ?? [] {
                let m = meshFor(rep)
                guard !m.isEmpty else { continue }
                result.append(m.applying(transform.floatMatrix))
                emitted.insert(rep)
                summary.instances += 1
            }
            for c in children[group] ?? [] { emit(group: c.group, transform: transform * c.transform, depth: depth + 1) }
        }

        let groups = Set(reps.keys.map(find))
        let roots = groups.filter { !isChild.contains($0) && (groupReps[$0] != nil || children[$0] != nil) }
        for root in roots.sorted() { emit(group: root, transform: matrix_identity_double4x4, depth: 0) }
        // Geometry not reachable from a root (cyclic or dangling structure) is shown in place.
        for (_, list) in groupReps.sorted(by: { $0.key < $1.key }) {
            for rep in list where !emitted.contains(rep) {
                result.append(meshFor(rep))
                summary.instances += 1
            }
        }

        if result.isEmpty { throw ImportError.empty }
        if !anyColor { result.colors = [] }
        progress?(1)
        return result
    }

    // MARK: - Units

    private func unitScale(_ id: Int) -> Double {
        guard let e = file.entity(id) else { return 1 }
        if let si = e.part("SI_UNIT") ?? (e.name == "SI_UNIT" ? Array(e.args.dropFirst()) : nil) {
            let prefix = si.count > 1 ? si[0].enumValue : nil
            let base = 1000.0 // metre in mm
            let factor: Double = switch prefix {
            case "MILLI": 0.001
            case "CENTI": 0.01
            case "DECI": 0.1
            case "KILO": 1000
            case "MICRO": 1e-6
            case "NANO": 1e-9
            default: 1
            }
            return base * factor
        }
        if let cb = e.part("CONVERSION_BASED_UNIT"), cb.count >= 2, let measure = cb[1].ref, let m = file.entity(measure) {
            let value = m[0].number ?? 1
            let unit = m[1].ref.map(unitScale) ?? 1
            return value * unit
        }
        return 1
    }

    private func lengthScale(context: Int) -> Double? {
        guard let e = file.entity(context), let units = e.part("GLOBAL_UNIT_ASSIGNED_CONTEXT")?.first?.refs else { return nil }
        for u in units where file.isType(u, "LENGTH_UNIT") {
            let s = unitScale(u)
            return s.isFinite && s > 0 ? s : nil
        }
        return nil
    }

    private func planeAngleFactor(context: Int) -> Double? {
        guard let e = file.entity(context), let units = e.part("GLOBAL_UNIT_ASSIGNED_CONTEXT")?.first?.refs else { return nil }
        for u in units where file.isType(u, "PLANE_ANGLE_UNIT") {
            guard let ue = file.entity(u) else { return nil }
            if let cb = ue.part("CONVERSION_BASED_UNIT"), cb.count >= 2, let measure = cb[1].ref,
               let m = file.entity(measure), let value = m[0].number {
                return value // value of one unit in radians (base SI unit)
            }
            return 1
        }
        return nil
    }

    private func describe(scale: Double) -> String {
        switch scale {
        case 1: "millimetre"
        case 10: "centimetre"
        case 1000: "metre"
        case 25.4: "inch"
        case 304.8: "foot"
        default: String(format: "%.4g mm", scale)
        }
    }

    // MARK: - Tolerance & styles

    private func computeTolerance() {
        var lo = V3(repeating: .infinity), hi = V3(repeating: -.infinity)
        var found = false
        for id in file.orderedIDs where file.name(of: id) == "VERTEX_POINT" {
            if let p = vertexPoint(id) { lo = simd_min(lo, p); hi = simd_max(hi, p); found = true }
        }
        if !found {
            var n = 0
            for id in file.orderedIDs where file.name(of: id) == "CARTESIAN_POINT" {
                if let p = file.coordinates(id) { lo = simd_min(lo, p); hi = simd_max(hi, p); found = true }
                n += 1
                if n > 200_000 { break }
            }
        }
        let diag = found ? simd_length(hi - lo) : 100
        tolerance = max(diag * quality.relativeChordTolerance, diag * 1e-7, 1e-9)
        maxAngle = quality.maxSegmentAngle
    }

    private func collectStyles() {
        for id in file.orderedIDs {
            let n = file.name(of: id)
            guard n == "STYLED_ITEM" || n == "OVER_RIDING_STYLED_ITEM" else { continue }
            guard let e = file.entity(id), let item = e[2].ref else { continue }
            var visited = Set<Int>()
            if let c = findColor(e[1], depth: 0, visited: &visited) {
                itemColors[item] = c
                anyColor = true
            }
        }
    }

    private func findColor(_ value: StepValue, depth: Int, visited: inout Set<Int>) -> RGBA8? {
        guard depth < 12 else { return nil }
        switch value {
        case .ref(let id):
            guard visited.insert(id).inserted else { return nil }
            let name = file.name(of: id)
            if name == "CURVE_STYLE" || name == "POINT_STYLE" || name == "TEXT_STYLE" { return nil }
            guard let e = file.entity(id) else { return nil }
            if name == "COLOUR_RGB", let r = e[1].number, let g = e[2].number, let b = e[3].number {
                return RGBA8(unit: r, g, b)
            }
            if name == "DRAUGHTING_PRE_DEFINED_COLOUR", let s = e[0].string {
                return StepImporter.predefinedColor(s)
            }
            for part in e.parts {
                for a in part.args {
                    if let c = findColor(a, depth: depth + 1, visited: &visited) { return c }
                }
            }
            return nil
        case .list(let l), .typed(_, let l):
            for a in l { if let c = findColor(a, depth: depth + 1, visited: &visited) { return c } }
            return nil
        default:
            return nil
        }
    }

    private static func predefinedColor(_ name: String) -> RGBA8 {
        switch name.lowercased() {
        case "red": RGBA8(230, 40, 40)
        case "green": RGBA8(40, 190, 70)
        case "blue": RGBA8(40, 80, 230)
        case "yellow": RGBA8(240, 210, 40)
        case "magenta": RGBA8(220, 40, 200)
        case "cyan": RGBA8(40, 200, 220)
        case "black": RGBA8(30, 30, 30)
        case "white": RGBA8(245, 245, 245)
        default: .neutral
        }
    }

    // MARK: - Transforms

    private func frame(_ id: Int) -> Frame3 {
        if let f = frameCache[id] { return f }
        var f = Frame3.identity
        if let e = file.entity(id) {
            let origin = e[1].ref.flatMap { file.coordinates($0) } ?? .zero
            if e.name == "AXIS2_PLACEMENT_3D" {
                f = Frame3(origin: origin, axis: e[2].ref.flatMap { file.coordinates($0) },
                           refDirection: e[3].ref.flatMap { file.coordinates($0) })
            } else if e.name == "AXIS2_PLACEMENT_2D" {
                f = Frame3(origin: origin, axis: V3(0, 0, 1), refDirection: e[2].ref.flatMap { file.coordinates($0) })
            } else if e.name == "AXIS1_PLACEMENT" {
                f = Frame3(origin: origin, axis: e[2].ref.flatMap { file.coordinates($0) }, refDirection: nil)
            }
        }
        frameCache[id] = f
        return f
    }

    private func placementMatrix(_ id: Int, scale: Double) -> simd_double4x4 {
        var f = frame(id)
        f.origin *= scale
        return f.matrix
    }

    private func transformMatrix(_ id: Int, childScale: Double, parentScale: Double, reversed: Bool) -> simd_double4x4? {
        guard let e = file.entity(id) else { return nil }
        if e.name == "ITEM_DEFINED_TRANSFORMATION", let i1 = e[2].ref, let i2 = e[3].ref {
            // transform_item_1 lives in the child (rep_1), transform_item_2 in the parent (rep_2).
            let childPlacement = placementMatrix(reversed ? i2 : i1, scale: childScale)
            let parentPlacement = placementMatrix(reversed ? i1 : i2, scale: parentScale)
            return parentPlacement * childPlacement.inverse
        }
        if e.name.hasPrefix("CARTESIAN_TRANSFORMATION_OPERATOR") {
            let a1 = e[1].ref.flatMap { file.coordinates($0) } ?? V3(1, 0, 0)
            let a2 = e[2].ref.flatMap { file.coordinates($0) } ?? V3(0, 1, 0)
            let o = (e[3].ref.flatMap { file.coordinates($0) } ?? .zero) * parentScale
            let s = e[4].number ?? 1
            let a3 = e[5].ref.flatMap { file.coordinates($0) } ?? simd_cross(a1, a2)
            return simd_double4x4(SIMD4(simd_normalize(a1) * s, 0), SIMD4(simd_normalize(a2) * s, 0),
                                  SIMD4(simd_normalize(a3) * s, 0), SIMD4(o, 1))
        }
        return nil
    }

    // MARK: - Items, shells, faces

    private func meshItem(_ item: Int, into mesh: inout Mesh, inheritedColor: RGBA8?) {
        guard let e = file.entity(item) else { return }
        let color = itemColors[item] ?? inheritedColor
        switch e.name {
        case "MANIFOLD_SOLID_BREP", "FACETED_BREP":
            summary.solids += 1
            if let shell = e[1].ref { meshItem(shell, into: &mesh, inheritedColor: color) }
        case "BREP_WITH_VOIDS":
            summary.solids += 1
            if let shell = e[1].ref { meshItem(shell, into: &mesh, inheritedColor: color) }
            for v in e[2].refs { meshItem(v, into: &mesh, inheritedColor: color) }
        case "SHELL_BASED_SURFACE_MODEL":
            for s in e[1].refs { meshItem(s, into: &mesh, inheritedColor: color) }
        case "CLOSED_SHELL", "OPEN_SHELL":
            for f in e[1].refs { meshFace(f, into: &mesh, color: itemColors[f] ?? color, flip: false) }
        case "ORIENTED_CLOSED_SHELL", "ORIENTED_OPEN_SHELL":
            if let s = e[2].ref, let shell = file.entity(s) {
                let flip = e[3].bool == false
                for f in shell[1].refs { meshFace(f, into: &mesh, color: itemColors[f] ?? color, flip: flip) }
            }
        case "ADVANCED_FACE", "FACE_SURFACE", "FACE", "ORIENTED_FACE":
            meshFace(item, into: &mesh, color: color, flip: false)
        case "TESSELLATED_SHELL", "TESSELLATED_SOLID":
            summary.solids += 1
            for t in e[1].refs { meshItem(t, into: &mesh, inheritedColor: itemColors[t] ?? color) }
        case "TRIANGULATED_FACE", "COMPLEX_TRIANGULATED_FACE", "TRIANGULATED_SURFACE_SET", "COMPLEX_TRIANGULATED_SURFACE_SET":
            meshTessellated(e, into: &mesh, color: color)
        default:
            break
        }
    }

    private func reportFace() {
        processedFaces += 1
        if processedFaces % 64 == 0 { progress?(min(0.99, Double(processedFaces) / Double(totalFaces))) }
    }

    private func meshFace(_ faceID: Int, into mesh: inout Mesh, color: RGBA8?, flip: Bool) {
        guard var e = file.entity(faceID) else { return }
        var flipped = flip
        if e.name == "ORIENTED_FACE" {
            guard let inner = e[2].ref, let ie = file.entity(inner) else { return }
            flipped = flipped != (e[3].bool == false)
            e = ie
        }
        reportFace()
        let bounds = e[1].refs
        var loops: [[V3]] = []
        var vertexLoops: [V3] = []
        for b in bounds {
            guard let be = file.entity(b), let loopRef = be[1].ref, let le = file.entity(loopRef) else { continue }
            var pts: [V3]
            switch le.name {
            case "EDGE_LOOP": pts = edgeLoopPoints(le[1].refs)
            case "POLY_LOOP": pts = le[1].refs.compactMap { file.coordinates($0) }
            case "VERTEX_LOOP":
                if let v = le[1].ref, let p = vertexPoint(v) { vertexLoops.append(p) }
                continue
            default: continue
            }
            if be[2].bool == false { pts.reverse() }
            if pts.count >= 2 { loops.append(pts) }
        }

        var sameSense = (e.name == "ADVANCED_FACE" || e.name == "FACE_SURFACE") ? (e[3].bool ?? true) : true
        if flipped { sameSense.toggle() }
        var surface: (any Surface)? = nil
        if e.name == "ADVANCED_FACE" || e.name == "FACE_SURFACE", let s = e[2].ref { surface = self.surface(s) }

        var output: FaceOutput? = nil
        if let surface {
            output = FaceMesher.mesh(FaceInput(surface: surface, loops: loops, vertexLoops: vertexLoops, sameSense: sameSense),
                                     tolerance: tolerance, maxAngle: maxAngle)
        }
        if output == nil, let outer = loops.max(by: { $0.count < $1.count }), outer.count >= 3 {
            // Unknown surface or failed parameterisation: triangulate the loops on their best-fit plane.
            let plane = PlaneSurface(frame: newellFrame(outer))
            output = FaceMesher.mesh(FaceInput(surface: plane, loops: loops, vertexLoops: [], sameSense: !flipped),
                                     tolerance: tolerance, maxAngle: maxAngle)
        }
        guard let out = output else {
            summary.skippedFaces += 1
            return
        }
        append(out, color: color, to: &mesh)
    }

    private func append(_ out: FaceOutput, color: RGBA8?, to mesh: inout Mesh) {
        var part = Mesh()
        part.positions = out.positions.map { SIMD3<Float>($0) }
        part.normals = out.normals.map { SIMD3<Float>($0) }
        if anyColor { part.colors = [RGBA8](repeating: color ?? .neutral, count: out.positions.count) }
        part.indices = out.triangles.map { UInt32($0) }
        mesh.append(part)
    }

    private func newellFrame(_ pts: [V3]) -> Frame3 {
        var n = V3.zero
        var c = V3.zero
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
            c += a
        }
        c /= Double(pts.count)
        if simd_length(n) < 1e-30 { n = V3(0, 0, 1) }
        return Frame3(origin: c, axis: n, refDirection: pts.count > 1 ? pts[1] - pts[0] : nil)
    }

    private func vertexPoint(_ id: Int) -> V3? {
        if let p = pointCache[id] { return p }
        guard let e = file.entity(id) else { return nil }
        var p: V3? = nil
        if e.name == "VERTEX_POINT", let ref = e[1].ref { p = file.coordinates(ref) } else if e.name == "CARTESIAN_POINT" { p = file.coordinates(id) }
        if let p { pointCache[id] = p }
        return p
    }

    private func edgeLoopPoints(_ orientedEdges: [Int]) -> [V3] {
        var pts: [V3] = []
        for oe in orientedEdges {
            guard let e = file.entity(oe) else { continue }
            var edgeID = oe
            var forward = true
            if e.name == "ORIENTED_EDGE" {
                guard let r = e[3].ref else { continue }
                edgeID = r
                forward = e[4].bool ?? true
            }
            var seg = edgePoints(edgeID)
            guard !seg.isEmpty else { continue }
            if !forward { seg.reverse() }
            if let last = pts.last, let f = seg.first, let l = seg.last,
               simd_distance(last, f) > simd_distance(last, l) * 2 + tolerance {
                seg.reverse() // tolerate inconsistent orientation flags
            }
            if let last = pts.last, let f = seg.first, simd_distance(last, f) <= tolerance * 1e-2 {
                pts += seg.dropFirst()
            } else {
                pts += seg
            }
        }
        if pts.count > 1, simd_distance(pts[0], pts[pts.count - 1]) <= tolerance * 1e-2 { pts.removeLast() }
        return pts
    }

    private func edgePoints(_ id: Int) -> [V3] {
        if let cached = edgeCache[id] { return cached }
        guard let e = file.entity(id), e.name == "EDGE_CURVE",
              let v0 = e[1].ref, let v1 = e[2].ref, let p0 = vertexPoint(v0), let p1 = vertexPoint(v1) else {
            edgeCache[id] = []
            return []
        }
        let sameSense = e[4].bool ?? true
        var pts: [V3] = [p0, p1]
        if let g = e[3].ref, let curve = curve(g), !(curve is LineCurve) {
            var t0 = curve.parameter(of: p0)
            var t1 = curve.parameter(of: p1)
            let closedEdge = simd_distance(p0, p1) <= tolerance * 1e-2
            if let period = curve.period {
                if sameSense {
                    if closedEdge { t1 = t0 + period } else {
                        while t1 <= t0 { t1 += period }
                        while t1 - t0 > period { t1 -= period }
                    }
                } else {
                    if closedEdge { t1 = t0 - period } else {
                        while t1 >= t0 { t1 -= period }
                        while t0 - t1 > period { t1 += period }
                    }
                }
            } else if closedEdge || abs(t1 - t0) < 1e-12 {
                let d = curve.domain
                if d.lowerBound.isFinite && d.upperBound.isFinite && d.upperBound - d.lowerBound < 1e9 {
                    (t0, t1) = sameSense ? (d.lowerBound, d.upperBound) : (d.upperBound, d.lowerBound)
                }
            }
            if abs(t1 - t0) > 1e-14 {
                pts = curve.discretize(from: t0, to: t1, tolerance: tolerance, maxAngle: maxAngle)
                if pts.count >= 2 {
                    pts[0] = p0
                    pts[pts.count - 1] = p1
                }
            }
        }
        edgeCache[id] = pts
        return pts
    }

    // MARK: - Curves

    private func curve(_ id: Int) -> (any Curve3)? {
        if let c = curveCache[id] { return c }
        curveCache[id] = .some(nil) // recursion guard
        let c = buildCurve(id)
        curveCache[id] = c
        return c
    }

    private func buildCurve(_ id: Int) -> (any Curve3)? {
        guard let e = file.entity(id) else { return nil }
        if e.has("B_SPLINE_CURVE") || e.name.contains("B_SPLINE_CURVE") || ["BEZIER_CURVE", "QUASI_UNIFORM_CURVE", "UNIFORM_CURVE"].contains(e.name) {
            return bsplineCurve(e)
        }
        switch e.name {
        case "LINE":
            guard let p = e[1].ref.flatMap({ file.coordinates($0) }), let vec = e[2].ref, let ve = file.entity(vec),
                  let d = ve[1].ref.flatMap({ file.coordinates($0) }) else { return nil }
            let mag = ve[2].number ?? 1
            let len = simd_length(d)
            return LineCurve(origin: p, direction: len > 0 ? d / len * (mag != 0 ? mag : 1) : V3(1, 0, 0))
        case "CIRCLE":
            guard let pl = e[1].ref, let r = e[2].number else { return nil }
            return EllipseCurve(frame: frame(pl), a: r, b: r)
        case "ELLIPSE":
            guard let pl = e[1].ref, let a = e[2].number, let b = e[3].number else { return nil }
            return EllipseCurve(frame: frame(pl), a: a, b: b)
        case "POLYLINE":
            let pts = e[1].refs.compactMap { file.coordinates($0) }
            return pts.count >= 2 ? PolylineCurve(points: pts) : nil
        case "TRIMMED_CURVE":
            return e[1].ref.flatMap(curve)
        case "SURFACE_CURVE", "SEAM_CURVE", "INTERSECTION_CURVE", "BOUNDED_SURFACE_CURVE":
            if let c = e[1].ref.flatMap(curve) { return c }
            // Fall back to the first p-curve.
            for r in e[2].refs { if let c = curve(r) { return c } }
            return nil
        case "PCURVE":
            guard let s = e[1].ref.flatMap(surface), let dr = e[2].ref, let de = file.entity(dr),
                  let c2 = de[1].refs.first.flatMap(curve) else { return nil }
            return SurfaceCurve(surface: s, curve2D: c2)
        default:
            return nil
        }
    }

    private func bsplineCurve(_ e: StepEntity) -> (any Curve3)? {
        let args: [StepValue]
        var mults: [Int] = [], knots: [Double] = []
        if e.isComplex {
            guard let b = e.part("B_SPLINE_CURVE") else { return nil }
            args = [.string("")] + b
            if let k = e.part("B_SPLINE_CURVE_WITH_KNOTS"), k.count >= 2 {
                mults = k[0].numbers.map { Int($0) }
                knots = k[1].numbers
            }
        } else {
            args = e.args
            if e.name == "B_SPLINE_CURVE_WITH_KNOTS", args.count >= 8 {
                mults = args[6].numbers.map { Int($0) }
                knots = args[7].numbers
            }
        }
        guard args.count >= 3, let degree = args[1].number.map({ Int($0) }) else { return nil }
        let pts = args[2].refs.compactMap { file.coordinates($0) }
        guard pts.count >= 2 else { return nil }
        let closed = args.count > 4 ? (args[4].bool ?? false) : false
        let names = e.parts.map(\.name)
        let kv: KnotVector
        if !knots.isEmpty {
            kv = KnotVector(degree: degree, multiplicities: mults, values: knots, controlCount: pts.count)
        } else if names.contains("UNIFORM_CURVE") {
            kv = KnotVector(degree: degree, knots: KnotVector.uniform(degree: degree, count: pts.count), controlCount: pts.count)
        } else {
            kv = KnotVector(degree: degree, knots: KnotVector.clampedUniform(degree: degree, count: pts.count), controlCount: pts.count)
        }
        var weights: [Double]? = nil
        if let w = e.part("RATIONAL_B_SPLINE_CURVE")?.first?.numbers, w.count == pts.count { weights = w }
        return BSplineCurve(knots: kv, controlPoints: pts, weights: weights, closed: closed)
    }

    // MARK: - Surfaces

    private func surface(_ id: Int) -> (any Surface)? {
        if let s = surfaceCache[id] { return s }
        surfaceCache[id] = .some(nil)
        let s = buildSurface(id)
        surfaceCache[id] = s
        return s
    }

    private func buildSurface(_ id: Int) -> (any Surface)? {
        guard let e = file.entity(id) else { return nil }
        if e.has("B_SPLINE_SURFACE") || e.name.contains("B_SPLINE_SURFACE") || ["BEZIER_SURFACE", "QUASI_UNIFORM_SURFACE", "UNIFORM_SURFACE"].contains(e.name) {
            return bsplineSurface(e)
        }
        switch e.name {
        case "PLANE":
            guard let pl = e[1].ref else { return nil }
            return PlaneSurface(frame: frame(pl))
        case "CYLINDRICAL_SURFACE":
            guard let pl = e[1].ref, let r = e[2].number else { return nil }
            return CylinderSurface(frame: frame(pl), radius: r)
        case "CONICAL_SURFACE":
            guard let pl = e[1].ref, let r = e[2].number, var a = e[3].number else { return nil }
            a *= angleFactor
            if abs(a) > .pi / 2 { a *= .pi / 180 } // heuristically degrees
            return ConeSurface(frame: frame(pl), radius: r, semiAngle: a)
        case "SPHERICAL_SURFACE":
            guard let pl = e[1].ref, let r = e[2].number else { return nil }
            return SphereSurface(frame: frame(pl), radius: r)
        case "TOROIDAL_SURFACE", "DEGENERATE_TOROIDAL_SURFACE":
            guard let pl = e[1].ref, let a = e[2].number, let b = e[3].number else { return nil }
            return TorusSurface(frame: frame(pl), major: a, minor: b)
        case "SURFACE_OF_REVOLUTION":
            guard let c = e[1].ref.flatMap(curve), let ax = e[2].ref else { return nil }
            let f = frame(ax)
            return RevolutionSurface(profile: c, axisOrigin: f.origin, axis: f.z)
        case "SURFACE_OF_LINEAR_EXTRUSION":
            guard let c = e[1].ref.flatMap(curve), let vec = e[2].ref, let ve = file.entity(vec),
                  let d = ve[1].ref.flatMap({ file.coordinates($0) }) else { return nil }
            let mag = ve[2].number ?? 1
            let len = simd_length(d)
            guard len > 0 else { return nil }
            return ExtrusionSurface(profile: c, vector: d / len * mag)
        case "OFFSET_SURFACE":
            guard let b = e[1].ref.flatMap(surface), let d = e[2].number else { return nil }
            return OffsetSurfaceImpl(basis: b, distance: d)
        case "RECTANGULAR_TRIMMED_SURFACE", "CURVE_BOUNDED_SURFACE":
            return e[1].ref.flatMap(surface)
        default:
            return nil
        }
    }

    private func bsplineSurface(_ e: StepEntity) -> (any Surface)? {
        let args: [StepValue]
        var um: [Int] = [], vm: [Int] = [], uk: [Double] = [], vk: [Double] = []
        if e.isComplex {
            guard let b = e.part("B_SPLINE_SURFACE") else { return nil }
            args = [.string("")] + b
            if let k = e.part("B_SPLINE_SURFACE_WITH_KNOTS"), k.count >= 4 {
                um = k[0].numbers.map { Int($0) }; vm = k[1].numbers.map { Int($0) }
                uk = k[2].numbers; vk = k[3].numbers
            }
        } else {
            args = e.args
            if e.name == "B_SPLINE_SURFACE_WITH_KNOTS", args.count >= 12 {
                um = args[8].numbers.map { Int($0) }; vm = args[9].numbers.map { Int($0) }
                uk = args[10].numbers; vk = args[11].numbers
            }
        }
        guard args.count >= 4, let ud = args[1].number.map({ Int($0) }), let vd = args[2].number.map({ Int($0) }),
              let rows = args[3].list else { return nil }
        let grid: [[V3]] = rows.map { row in row.refs.compactMap { file.coordinates($0) } }
        guard let nv = grid.first?.count, nv >= 2, grid.count >= 2, grid.allSatisfy({ $0.count == nv }) else { return nil }
        let uClosed = args.count > 5 ? (args[5].bool ?? false) : false
        let vClosed = args.count > 6 ? (args[6].bool ?? false) : false
        let ukv = uk.isEmpty
            ? KnotVector(degree: ud, knots: KnotVector.clampedUniform(degree: ud, count: grid.count), controlCount: grid.count)
            : KnotVector(degree: ud, multiplicities: um, values: uk, controlCount: grid.count)
        let vkv = vk.isEmpty
            ? KnotVector(degree: vd, knots: KnotVector.clampedUniform(degree: vd, count: nv), controlCount: nv)
            : KnotVector(degree: vd, multiplicities: vm, values: vk, controlCount: nv)
        var weights: [[Double]]? = nil
        if let w = e.part("RATIONAL_B_SPLINE_SURFACE")?.first?.list {
            let ww = w.map(\.numbers)
            if ww.count == grid.count && ww.allSatisfy({ $0.count == nv }) { weights = ww }
        }
        return BSplineSurface(uKnots: ukv, vKnots: vkv, control: grid, weights: weights, uClosed: uClosed, vClosed: vClosed)
    }

    // MARK: - AP242 tessellation

    private var coordinateLists: [Int: [V3]] = [:]

    private func coordinates(list id: Int) -> [V3] {
        if let c = coordinateLists[id] { return c }
        var out: [V3] = []
        if let e = file.entity(id), let rows = e[2].list {
            out = rows.map { v -> V3 in
                let n = v.numbers
                return V3(n.count > 0 ? n[0] : 0, n.count > 1 ? n[1] : 0, n.count > 2 ? n[2] : 0)
            }
        }
        coordinateLists[id] = out
        return out
    }

    private func meshTessellated(_ e: StepEntity, into mesh: inout Mesh, color: RGBA8?) {
        reportFace()
        guard let coordRef = e[1].ref else { return }
        let coords = coordinates(list: coordRef)
        let isFace = e.name.hasSuffix("_FACE")
        let normalsValue = e[3]
        let pnIndex = (isFace ? e[5] : e[4]).numbers.map { Int($0) }
        let verts: [V3] = pnIndex.isEmpty ? coords : pnIndex.map { $0 >= 1 && $0 <= coords.count ? coords[$0 - 1] : .zero }
        var normals: [V3] = normalsValue.list?.map { v -> V3 in
            let n = v.numbers
            return V3(n.count > 0 ? n[0] : 0, n.count > 1 ? n[1] : 0, n.count > 2 ? n[2] : 1)
        } ?? []
        if normals.count == 1 { normals = [V3](repeating: normals[0], count: verts.count) }
        if normals.count != verts.count { normals = [] }

        var tris: [Int32] = []
        func addTri(_ a: Int, _ b: Int, _ c: Int) {
            guard a != b, b != c, a != c, a >= 1, b >= 1, c >= 1, a <= verts.count, b <= verts.count, c <= verts.count else { return }
            tris += [Int32(a - 1), Int32(b - 1), Int32(c - 1)]
        }
        if e.name.hasPrefix("COMPLEX_") {
            let stripsIndex = isFace ? 6 : 5
            for strip in e[stripsIndex].list ?? [] {
                let s = strip.numbers.map { Int($0) }
                guard s.count >= 3 else { continue }
                for i in 0..<(s.count - 2) {
                    if i % 2 == 0 { addTri(s[i], s[i + 1], s[i + 2]) } else { addTri(s[i + 1], s[i], s[i + 2]) }
                }
            }
            for fan in e[stripsIndex + 1].list ?? [] {
                let f = fan.numbers.map { Int($0) }
                guard f.count >= 3 else { continue }
                for i in 1..<(f.count - 1) { addTri(f[0], f[i], f[i + 1]) }
            }
        } else {
            for t in e[isFace ? 6 : 5].list ?? [] {
                let n = t.numbers.map { Int($0) }
                if n.count >= 3 { addTri(n[0], n[1], n[2]) }
            }
        }
        var out = FaceOutput(positions: verts, normals: normals, triangles: tris)
        if out.normals.isEmpty {
            // Compute flat-ish normals; the viewer re-smooths with crease detection anyway.
            var acc = [V3](repeating: .zero, count: verts.count)
            var i = 0
            while i + 2 < tris.count {
                let a = Int(tris[i]), b = Int(tris[i + 1]), c = Int(tris[i + 2])
                let n = simd_cross(verts[b] - verts[a], verts[c] - verts[a])
                acc[a] += n; acc[b] += n; acc[c] += n
                i += 3
            }
            out.normals = acc.map { simd_length($0) > 0 ? simd_normalize($0) : V3(0, 0, 1) }
        }
        append(out, color: color, to: &mesh)
    }
}

nonisolated extension simd_double4x4 {
    var floatMatrix: simd_float4x4 {
        simd_float4x4(SIMD4<Float>(columns.0), SIMD4<Float>(columns.1), SIMD4<Float>(columns.2), SIMD4<Float>(columns.3))
    }
}
