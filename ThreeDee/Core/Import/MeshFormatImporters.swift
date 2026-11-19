//
//  MeshFormatImporters.swift
//  ThreeDee
//
//  STL, PLY, OBJ and OFF readers.
//

import Foundation
import simd

// MARK: - STL

nonisolated enum STLImporter {
    static func load(_ data: Data) throws -> Mesh {
        if data.count >= 84 {
            let triCount = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian) }
            let looksASCII = data.prefix(5).elementsEqual("solid".utf8) && data.prefix(1024).contains(where: { $0 == 10 })
                && String(decoding: data.prefix(2048), as: UTF8.self).contains("facet")
            if 84 + triCount * 50 == data.count && !(looksASCII && triCount == 0) {
                return try loadBinary(data, triangles: triCount)
            }
            if !looksASCII && 84 + triCount * 50 <= data.count && triCount > 0 {
                return try loadBinary(data, triangles: triCount)
            }
        }
        return try loadASCII(data)
    }

    private static func loadBinary(_ data: Data, triangles: Int) throws -> Mesh {
        guard triangles > 0 else { throw ImportError.empty }
        var positions = [SIMD3<Float>](repeating: .zero, count: triangles * 3)
        data.withUnsafeBytes { raw in
            for t in 0..<triangles {
                let base = 84 + t * 50 + 12
                for k in 0..<3 {
                    let o = base + k * 12
                    positions[t * 3 + k] = SIMD3(
                        Float(bitPattern: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian),
                        Float(bitPattern: raw.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self).littleEndian),
                        Float(bitPattern: raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self).littleEndian))
                }
            }
        }
        return Mesh(positions: positions, indices: (0..<UInt32(positions.count)).map { $0 })
    }

    private static func loadASCII(_ data: Data) throws -> Mesh {
        let s = TextScanner(data: data)
        var positions: [SIMD3<Float>] = []
        let keyword = Array("vertex".utf8)
        while s.advance(past: keyword) {
            guard let x = s.double(), let y = s.double(), let z = s.double() else { continue }
            positions.append(SIMD3(Float(x), Float(y), Float(z)))
        }
        positions.removeLast(positions.count % 3)
        guard !positions.isEmpty else { throw ImportError.empty }
        return Mesh(positions: positions, indices: (0..<UInt32(positions.count)).map { $0 })
    }
}

// MARK: - PLY

nonisolated enum PLYImporter {
    /// Splats less opaque than this contribute nothing visible and are skipped.
    static let splatOpacityCutoff = 0.01

    private enum Encoding { case ascii, binaryLE, binaryBE }

    private enum ScalarType {
        case int8, uint8, int16, uint16, int32, uint32, float32, float64

        init?(_ s: String) {
            switch s {
            case "char", "int8": self = .int8
            case "uchar", "uint8": self = .uint8
            case "short", "int16": self = .int16
            case "ushort", "uint16": self = .uint16
            case "int", "int32": self = .int32
            case "uint", "uint32": self = .uint32
            case "float", "float32": self = .float32
            case "double", "float64": self = .float64
            default: return nil
            }
        }

        var size: Int {
            switch self {
            case .int8, .uint8: 1
            case .int16, .uint16: 2
            case .int32, .uint32, .float32: 4
            case .float64: 8
            }
        }

        var isInteger8: Bool { self == .uint8 || self == .int8 }
        var isFloat: Bool { self == .float32 || self == .float64 }
    }

    private struct Property {
        var name: String
        var type: ScalarType
        var listCountType: ScalarType?
    }

    private struct Element {
        var name: String
        var count: Int
        var properties: [Property] = []
    }

    static func load(_ data: Data) throws -> Mesh {
        let s = TextScanner(data: data)
        guard s.line()?.trimmingCharacters(in: .whitespaces) == "ply" else { throw ImportError.malformed("missing PLY signature") }
        var encoding = Encoding.ascii
        var elements: [Element] = []
        var headerDone = false
        while let line = s.line() {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = parts.first else { continue }
            switch head {
            case "format":
                guard parts.count >= 2 else { break }
                switch parts[1] {
                case "ascii": encoding = .ascii
                case "binary_little_endian": encoding = .binaryLE
                case "binary_big_endian": encoding = .binaryBE
                default: throw ImportError.malformed("unknown PLY format \(parts[1])")
                }
            case "element":
                guard parts.count >= 3, let n = Int(parts[2]) else { throw ImportError.malformed("bad element line") }
                elements.append(Element(name: parts[1], count: n))
            case "property":
                guard !elements.isEmpty else { break }
                if parts.count >= 5 && parts[1] == "list" {
                    guard let ct = ScalarType(parts[2]), let it = ScalarType(parts[3]) else { throw ImportError.malformed("bad list property") }
                    elements[elements.count - 1].properties.append(Property(name: parts[4], type: it, listCountType: ct))
                } else if parts.count >= 3, let t = ScalarType(parts[1]) {
                    elements[elements.count - 1].properties.append(Property(name: parts[2], type: t, listCountType: nil))
                } else {
                    throw ImportError.malformed("bad property line: \(line)")
                }
            case "end_header":
                headerDone = true
            default:
                break // comment, obj_info …
            }
            if headerDone { break }
        }
        guard headerDone else { throw ImportError.malformed("missing end_header") }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colors: [RGBA8] = []
        var indices: [UInt32] = []
        var radii: [Float] = []
        var splats: [SplatShape] = []
        // Gaussian-splat files are pure point sets, so dropping near-transparent splats can't break faces.
        let hasFaces = elements.contains { $0.name == "face" && $0.count > 0 }

        // Reads one scalar value at a byte offset for binary encodings.
        func readBinary(_ raw: UnsafeRawBufferPointer, _ offset: Int, _ type: ScalarType, _ big: Bool) -> Double {
            switch type {
            case .int8: return Double(raw.loadUnaligned(fromByteOffset: offset, as: Int8.self))
            case .uint8: return Double(raw[offset])
            case .int16:
                let v = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                return Double(big ? Int16(bigEndian: v) : Int16(littleEndian: v))
            case .uint16:
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                return Double(big ? UInt16(bigEndian: v) : UInt16(littleEndian: v))
            case .int32:
                let v = raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)
                return Double(big ? Int32(bigEndian: v) : Int32(littleEndian: v))
            case .uint32:
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Double(big ? UInt32(bigEndian: v) : UInt32(littleEndian: v))
            case .float32:
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Double(Float(bitPattern: big ? UInt32(bigEndian: v) : UInt32(littleEndian: v)))
            case .float64:
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                return Double(bitPattern: big ? UInt64(bigEndian: v) : UInt64(littleEndian: v))
            }
        }

        func colorScale(_ t: ScalarType) -> Double {
            switch t {
            case .uint8, .int8: 1
            case .uint16, .int16: 255.0 / 65535.0
            case .float32, .float64: 255
            default: 1
            }
        }

        var offset = s.position
        for element in elements {
            let isVertex = element.name == "vertex"
            let isFace = element.name == "face"
            let props = element.properties
            func index(_ names: [String]) -> Int? { props.firstIndex { names.contains($0.name) } }
            let ix = index(["x"]), iy = index(["y"]), iz = index(["z"])
            let inx = index(["nx"]), iny = index(["ny"]), inz = index(["nz"])
            let ir = index(["red", "r", "diffuse_red"]), ig = index(["green", "g", "diffuse_green"]), ib = index(["blue", "b", "diffuse_blue"])
            let ia = index(["alpha", "a"])
            let ifaces = props.firstIndex { $0.listCountType != nil && ($0.name == "vertex_indices" || $0.name == "vertex_index") }
                ?? props.firstIndex { $0.listCountType != nil }
            let hasNormals = isVertex && inx != nil && iny != nil && inz != nil
            let hasColors = isVertex && ir != nil && ig != nil && ib != nil
            // 3D Gaussian splatting: colour is the SH DC term, opacity a logit, scales are log-sigmas.
            let idc = [index(["f_dc_0"]), index(["f_dc_1"]), index(["f_dc_2"])]
            let isSplat = isVertex && !hasColors && idc.allSatisfy { $0 != nil }
            let iop = isSplat && !hasFaces ? index(["opacity"]) : nil
            let iscale = [index(["scale_0"]), index(["scale_1"]), index(["scale_2"])]
            let hasScale = isSplat && iscale.allSatisfy { $0 != nil }
            let irot = [index(["rot_0"]), index(["rot_1"]), index(["rot_2"]), index(["rot_3"])]
            let hasShape = hasScale && irot.allSatisfy { $0 != nil }
            if isVertex {
                positions.reserveCapacity(element.count)
                if hasNormals { normals.reserveCapacity(element.count) }
                if hasColors { colors.reserveCapacity(element.count) }
            }
            var values = [Double](repeating: 0, count: props.count)
            var list: [Int] = []

            for _ in 0..<element.count {
                list.removeAll(keepingCapacity: true)
                switch encoding {
                case .ascii:
                    for (p, prop) in props.enumerated() {
                        if prop.listCountType != nil {
                            guard let n = s.int() else { throw ImportError.malformed("truncated list in \(element.name)") }
                            for _ in 0..<max(0, n) {
                                guard let v = s.double() else { throw ImportError.malformed("truncated list in \(element.name)") }
                                if p == ifaces { list.append(Int(v)) }
                            }
                        } else {
                            guard let v = s.double() else { throw ImportError.malformed("truncated \(element.name) data") }
                            values[p] = v
                        }
                    }
                case .binaryLE, .binaryBE:
                    let big = encoding == .binaryBE
                    try data.withUnsafeBytes { raw in
                        for (p, prop) in props.enumerated() {
                            if let ct = prop.listCountType {
                                guard offset + ct.size <= raw.count else { throw ImportError.malformed("truncated binary list") }
                                let n = Int(readBinary(raw, offset, ct, big))
                                offset += ct.size
                                guard n >= 0, offset + n * prop.type.size <= raw.count else { throw ImportError.malformed("truncated binary list") }
                                if p == ifaces {
                                    for k in 0..<n { list.append(Int(readBinary(raw, offset + k * prop.type.size, prop.type, big))) }
                                }
                                offset += n * prop.type.size
                            } else {
                                guard offset + prop.type.size <= raw.count else { throw ImportError.malformed("truncated binary data") }
                                values[p] = readBinary(raw, offset, prop.type, big)
                                offset += prop.type.size
                            }
                        }
                    }
                }

                if isVertex, let ix, let iy, let iz {
                    let opacity = iop.map { 1 / (1 + exp(-values[$0])) } ?? 1
                    if opacity < PLYImporter.splatOpacityCutoff { continue }
                    positions.append(SIMD3(Float(values[ix]), Float(values[iy]), Float(values[iz])))
                    if isSplat {
                        let c0 = 0.28209479177387814
                        colors.append(RGBA8(unit: 0.5 + c0 * values[idc[0]!], 0.5 + c0 * values[idc[1]!], 0.5 + c0 * values[idc[2]!], opacity))
                    }
                    if hasScale {
                        let sigma = SIMD3(Float(exp(values[iscale[0]!])), Float(exp(values[iscale[1]!])), Float(exp(values[iscale[2]!])))
                        let sg = [sigma.x, sigma.y, sigma.z].sorted()
                        // Disc radius covering ~1.5σ of the splat's two largest axes (point-style fallback).
                        radii.append(1.5 * (sg[1] * sg[2]).squareRoot())
                        if hasShape {
                            // rot_0…3 = (w, x, y, z)
                            let q = simd_quatf(ix: Float(values[irot[1]!]), iy: Float(values[irot[2]!]), iz: Float(values[irot[3]!]),
                                               r: Float(values[irot[0]!]))
                            let n = simd_length(q.vector)
                            splats.append(SplatShape(sigma: sigma, rotation: n > 0 ? simd_quatf(vector: q.vector / n) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)))
                        }
                    }
                    if hasNormals { normals.append(SIMD3(Float(values[inx!]), Float(values[iny!]), Float(values[inz!]))) }
                    if hasColors {
                        let r = values[ir!] * colorScale(props[ir!].type)
                        let g = values[ig!] * colorScale(props[ig!].type)
                        let b = values[ib!] * colorScale(props[ib!].type)
                        let a = ia.map { values[$0] * colorScale(props[$0].type) } ?? 255
                        colors.append(RGBA8(UInt8(clamping: Int(r.rounded())), UInt8(clamping: Int(g.rounded())),
                                            UInt8(clamping: Int(b.rounded())), UInt8(clamping: Int(a.rounded()))))
                    }
                } else if isFace, list.count >= 3 {
                    // Fan triangulation of polygons.
                    for k in 1..<(list.count - 1) {
                        indices.append(UInt32(truncatingIfNeeded: list[0]))
                        indices.append(UInt32(truncatingIfNeeded: list[k]))
                        indices.append(UInt32(truncatingIfNeeded: list[k + 1]))
                    }
                }
            }
        }
        guard !positions.isEmpty else { throw ImportError.empty }
        var mesh = Mesh(positions: positions, normals: normals, colors: colors, indices: indices, pointRadii: indices.isEmpty ? radii : [])
        if indices.isEmpty && splats.count == positions.count { mesh.splats = splats }
        mesh.sanitize()
        // Scanner output often carries zero normals; treat them as absent.
        if mesh.hasNormals && !mesh.isPointCloud && mesh.normals.allSatisfy({ $0 == .zero }) { mesh.normals = [] }
        return mesh
    }
}

// MARK: - OBJ

nonisolated enum OBJImporter {
    static func load(_ data: Data) throws -> Mesh {
        let s = TextScanner(data: data)
        var v: [SIMD3<Float>] = []
        var vc: [RGBA8] = []
        var vn: [SIMD3<Float>] = []
        // Output corners when normals are referenced; keyed by (v, vn).
        var cornerMap: [UInt64: UInt32] = [:]
        var outPositions: [SIMD3<Float>] = []
        var outNormals: [SIMD3<Float>] = []
        var outColors: [RGBA8] = []
        var faceCorners: [(Int, Int)] = [] // (v index, vn index or -1)
        var triangles: [(Int, Int)] = []
        var usesNormals = false
        var anyColor = false

        func resolve(_ i: Int, _ count: Int) -> Int { i < 0 ? count + i : i - 1 }

        while !s.isAtEnd {
            s.skipWhitespace()
            let c0 = s.peek(), c1 = s.byte(at: s.position + 1)
            if c0 == UInt8(ascii: "v") && (c1 == 32 || c1 == 9) {
                s.position += 1
                let x = s.inlineDouble() ?? 0, y = s.inlineDouble() ?? 0, z = s.inlineDouble() ?? 0
                v.append(SIMD3(Float(x), Float(y), Float(z)))
                if let r = s.inlineDouble(), let g = s.inlineDouble(), let b = s.inlineDouble() {
                    let scale = (r > 1 || g > 1 || b > 1) ? 1.0 : 255.0
                    vc.append(RGBA8(UInt8(clamping: Int((r * scale).rounded())), UInt8(clamping: Int((g * scale).rounded())),
                                    UInt8(clamping: Int((b * scale).rounded()))))
                    anyColor = true
                } else {
                    vc.append(.neutral)
                }
                s.skipLine()
            } else if c0 == UInt8(ascii: "v") && c1 == UInt8(ascii: "n") {
                s.position += 2
                let x = s.inlineDouble() ?? 0, y = s.inlineDouble() ?? 0, z = s.inlineDouble() ?? 0
                vn.append(SIMD3(Float(x), Float(y), Float(z)))
                s.skipLine()
            } else if c0 == UInt8(ascii: "f") && (c1 == 32 || c1 == 9) {
                s.position += 1
                faceCorners.removeAll(keepingCapacity: true)
                while let tok = s.inlineToken() {
                    let parts = tok.split(separator: "/", omittingEmptySubsequences: false)
                    guard let vi = Int(parts[0]) else { continue }
                    var ni = -1
                    if parts.count >= 3, let n = Int(parts[2]) { ni = resolve(n, vn.count); usesNormals = true }
                    faceCorners.append((resolve(vi, v.count), ni))
                }
                if faceCorners.count >= 3 {
                    for k in 1..<(faceCorners.count - 1) {
                        triangles.append(faceCorners[0]); triangles.append(faceCorners[k]); triangles.append(faceCorners[k + 1])
                    }
                }
                s.skipLine()
            } else {
                s.skipLine()
            }
        }
        guard !v.isEmpty else { throw ImportError.empty }

        if triangles.isEmpty {
            return Mesh(positions: v, colors: anyColor ? vc : [])
        }
        if !usesNormals {
            let idx = triangles.map { UInt32(truncatingIfNeeded: $0.0) }
            var mesh = Mesh(positions: v, colors: anyColor ? vc : [], indices: idx)
            mesh.sanitize()
            return mesh
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(triangles.count)
        for (vi, ni) in triangles {
            guard vi >= 0 && vi < v.count else { indices.append(UInt32.max); continue }
            let key = UInt64(UInt32(vi)) << 32 | UInt64(UInt32(bitPattern: Int32(ni)))
            if let existing = cornerMap[key] {
                indices.append(existing)
            } else {
                let id = UInt32(outPositions.count)
                cornerMap[key] = id
                outPositions.append(v[vi])
                outNormals.append(ni >= 0 && ni < vn.count ? vn[ni] : .zero)
                outColors.append(vc[vi])
                indices.append(id)
            }
        }
        var mesh = Mesh(positions: outPositions, normals: outNormals, colors: anyColor ? outColors : [], indices: indices)
        mesh.sanitize()
        return mesh
    }
}

// MARK: - OFF

nonisolated enum OFFImporter {
    static func load(_ data: Data) throws -> Mesh {
        // Strip comments first so the token stream is clean.
        var bytes = [UInt8](data)
        var inComment = false
        for i in bytes.indices {
            if bytes[i] == UInt8(ascii: "#") { inComment = true }
            if bytes[i] == 10 { inComment = false }
            if inComment { bytes[i] = 32 }
        }
        let s = TextScanner(bytes: bytes)
        guard let header = s.token(), header.uppercased().hasSuffix("OFF") else { throw ImportError.malformed("missing OFF header") }
        let upper = header.uppercased()
        let hasColor = upper.contains("C")
        let hasNormal = upper.contains("N")
        let hasTex = upper.hasPrefix("ST")
        guard let nv = s.int(), let nf = s.int(), s.int() != nil else { throw ImportError.malformed("bad OFF counts") }
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colors: [RGBA8] = []
        positions.reserveCapacity(nv)
        s.skipLine()
        for _ in 0..<nv {
            guard let x = s.double(), let y = s.double(), let z = s.double() else { throw ImportError.malformed("truncated vertices") }
            positions.append(SIMD3(Float(x), Float(y), Float(z)))
            if hasNormal, let a = s.inlineDouble(), let b = s.inlineDouble(), let c = s.inlineDouble() {
                normals.append(SIMD3(Float(a), Float(b), Float(c)))
            }
            if hasColor {
                var comps: [Double] = []
                while let value = s.inlineDouble() { comps.append(value) }
                if comps.count >= 3 {
                    let scale = comps.prefix(3).contains(where: { $0 > 1 }) ? 1.0 : 255.0
                    colors.append(RGBA8(UInt8(clamping: Int(comps[0] * scale)), UInt8(clamping: Int(comps[1] * scale)),
                                        UInt8(clamping: Int(comps[2] * scale))))
                } else {
                    colors.append(.neutral)
                }
            }
            if hasTex { _ = s.inlineDouble(); _ = s.inlineDouble() }
            s.skipLine()
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(nf * 3)
        for _ in 0..<nf {
            guard let n = s.int() else { break }
            var poly: [UInt32] = []
            for _ in 0..<max(0, n) { if let i = s.int() { poly.append(UInt32(truncatingIfNeeded: i)) } }
            if poly.count >= 3 {
                for k in 1..<(poly.count - 1) { indices += [poly[0], poly[k], poly[k + 1]] }
            }
            s.skipLine()
        }
        guard !positions.isEmpty else { throw ImportError.empty }
        var mesh = Mesh(positions: positions, normals: normals, colors: colors, indices: indices)
        mesh.sanitize()
        return mesh
    }
}
