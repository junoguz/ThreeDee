//
//  GLTFImporter.swift
//  ThreeDee
//
//  glTF 2.0 (.gltf with embedded/external buffers, .glb) geometry reader.
//

import Foundation
import simd

nonisolated struct GLTFDocument: Codable, Sendable {
    struct Scene: Codable, Sendable { var nodes: [Int]? }
    struct Node: Codable, Sendable {
        var mesh: Int?
        var children: [Int]?
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
        var name: String?
    }
    struct Primitive: Codable, Sendable {
        var attributes: [String: Int]
        var indices: Int?
        var mode: Int?
        var material: Int?
    }
    struct MeshDef: Codable, Sendable { var primitives: [Primitive]; var name: String? }
    struct Accessor: Codable, Sendable {
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String
        var min: [Float]?
        var max: [Float]?
    }
    struct BufferView: Codable, Sendable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
        var target: Int?
    }
    struct Buffer: Codable, Sendable { var uri: String?; var byteLength: Int }
    struct TextureInfo: Codable, Sendable { var index: Int; var texCoord: Int? }
    struct PBR: Codable, Sendable { var baseColorFactor: [Float]?; var baseColorTexture: TextureInfo? }
    struct EmissiveStrength: Codable, Sendable { var emissiveStrength: Float? }
    struct Empty: Codable, Sendable {}
    struct MaterialExtensions: Codable, Sendable {
        var KHR_materials_emissive_strength: EmissiveStrength?
        var KHR_materials_unlit: Empty?
    }
    struct Material: Codable, Sendable {
        var pbrMetallicRoughness: PBR?
        var name: String?
        var emissiveFactor: [Float]?
        var emissiveTexture: TextureInfo?
        var alphaMode: String?
        var alphaCutoff: Float?
        var extensions: MaterialExtensions?
    }
    struct SourceRef: Codable, Sendable { var source: Int? }
    struct TextureExtensions: Codable, Sendable { var EXT_texture_webp: SourceRef? }
    struct Texture: Codable, Sendable { var source: Int?; var extensions: TextureExtensions? }
    struct Image: Codable, Sendable { var uri: String?; var bufferView: Int?; var mimeType: String?; var name: String? }
    struct Asset: Codable, Sendable { var version: String; var generator: String? }

    var asset: Asset
    var scene: Int?
    var scenes: [Scene]?
    var nodes: [Node]?
    var meshes: [MeshDef]?
    var accessors: [Accessor]?
    var bufferViews: [BufferView]?
    var buffers: [Buffer]?
    var materials: [Material]?
    var textures: [Texture]?
    var images: [Image]?
    var extensionsRequired: [String]?
}

nonisolated enum GLTFImporter {
    static func load(_ data: Data, baseURL: URL?) throws -> Mesh {
        var jsonData = data
        var binChunk: Data? = nil
        if data.count >= 12, data.prefix(4).elementsEqual("glTF".utf8) {
            var offset = 12
            jsonData = Data()
            while offset + 8 <= data.count {
                let (length, type) = data.withUnsafeBytes {
                    (Int($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian),
                     $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian)
                }
                let start = offset + 8
                guard start + length <= data.count else { throw ImportError.malformed("truncated GLB chunk") }
                let chunk = data.subdata(in: start..<(start + length))
                if type == 0x4E4F534A { jsonData = chunk } else if type == 0x004E4942 { binChunk = chunk }
                offset = start + ((length + 3) & ~3)
            }
        }
        let doc: GLTFDocument
        do { doc = try JSONDecoder().decode(GLTFDocument.self, from: jsonData) } catch {
            throw ImportError.malformed("invalid glTF JSON (\(error.localizedDescription))")
        }
        if let req = doc.extensionsRequired, let bad = req.first(where: { $0.contains("draco") || $0.contains("meshopt") }) {
            throw ImportError.unsupportedFeature("This glTF uses the compressed-geometry extension \(bad), which is not supported yet.")
        }

        // Resolve buffers.
        var buffers: [Data] = []
        for (i, b) in (doc.buffers ?? []).enumerated() {
            if let uri = b.uri {
                if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                    guard let d = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                        throw ImportError.malformed("bad data URI in buffer \(i)")
                    }
                    buffers.append(d)
                } else if let baseURL, let decoded = uri.removingPercentEncoding,
                          let d = try? Data(contentsOf: baseURL.deletingLastPathComponent().appendingPathComponent(decoded)) {
                    buffers.append(d)
                } else {
                    throw ImportError.unsupportedFeature("This glTF references an external file “\(uri)”. Import the .glb version or a self-contained .gltf instead.")
                }
            } else {
                buffers.append(binChunk ?? Data())
            }
        }

        func components(_ type: String) -> Int {
            switch type {
            case "SCALAR": 1
            case "VEC2": 2
            case "VEC3": 3
            case "VEC4", "MAT2": 4
            case "MAT3": 9
            case "MAT4": 16
            default: 1
            }
        }
        func componentSize(_ t: Int) -> Int {
            switch t {
            case 5120, 5121: 1
            case 5122, 5123: 2
            default: 4
            }
        }

        /// Reads an accessor as floats (normalised integers mapped to 0…1 / -1…1).
        func readFloats(_ index: Int) throws -> (values: [Float], components: Int) {
            guard let acc = doc.accessors?[safe: index] else { throw ImportError.malformed("missing accessor \(index)") }
            let nc = components(acc.type)
            guard let viewIndex = acc.bufferView else { return ([Float](repeating: 0, count: acc.count * nc), nc) }
            guard let view = doc.bufferViews?[safe: viewIndex], let buffer = buffers[safe: view.buffer] else {
                throw ImportError.malformed("missing buffer view")
            }
            let cs = componentSize(acc.componentType)
            let stride = view.byteStride ?? (cs * nc)
            let base = (view.byteOffset ?? 0) + (acc.byteOffset ?? 0)
            let normalized = acc.normalized ?? false
            var out = [Float](repeating: 0, count: acc.count * nc)
            guard acc.count == 0 || base + (acc.count - 1) * stride + nc * cs <= buffer.count else {
                throw ImportError.malformed("accessor \(index) exceeds its buffer")
            }
            buffer.withUnsafeBytes { raw in
                for i in 0..<acc.count {
                    for c in 0..<nc {
                        let o = base + i * stride + c * cs
                        var v: Float
                        switch acc.componentType {
                        case 5126: v = Float(bitPattern: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian)
                        case 5121: v = Float(raw[o]); if normalized { v /= 255 }
                        case 5120: v = Float(raw.loadUnaligned(fromByteOffset: o, as: Int8.self)); if normalized { v = max(v / 127, -1) }
                        case 5123: v = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian); if normalized { v /= 65535 }
                        case 5122: v = Float(raw.loadUnaligned(fromByteOffset: o, as: Int16.self).littleEndian); if normalized { v = max(v / 32767, -1) }
                        case 5125: v = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian)
                        default: v = 0
                        }
                        out[i * nc + c] = v
                    }
                }
            }
            return (out, nc)
        }

        func readIndices(_ index: Int) throws -> [UInt32] {
            guard let acc = doc.accessors?[safe: index], let viewIndex = acc.bufferView,
                  let view = doc.bufferViews?[safe: viewIndex], let buffer = buffers[safe: view.buffer] else {
                throw ImportError.malformed("missing index accessor")
            }
            let cs = componentSize(acc.componentType)
            let stride = view.byteStride ?? cs
            let base = (view.byteOffset ?? 0) + (acc.byteOffset ?? 0)
            guard acc.count == 0 || base + (acc.count - 1) * stride + cs <= buffer.count else {
                throw ImportError.malformed("index accessor exceeds its buffer")
            }
            var out = [UInt32](repeating: 0, count: acc.count)
            buffer.withUnsafeBytes { raw in
                for i in 0..<acc.count {
                    let o = base + i * stride
                    switch acc.componentType {
                    case 5121: out[i] = UInt32(raw[o])
                    case 5123: out[i] = UInt32(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian)
                    default: out[i] = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian
                    }
                }
            }
            return out
        }

        func localMatrix(_ node: GLTFDocument.Node) -> simd_float4x4 {
            if let m = node.matrix, m.count == 16 {
                return simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                     SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
            }
            var result = matrix_identity_float4x4
            if let t = node.translation, t.count == 3 { result.columns.3 = SIMD4(t[0], t[1], t[2], 1) }
            var rs = matrix_identity_float3x3
            if let r = node.rotation, r.count == 4 { rs = simd_float3x3(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])) }
            if let s = node.scale, s.count == 3 {
                rs.columns.0 *= s[0]; rs.columns.1 *= s[1]; rs.columns.2 *= s[2]
            }
            result.columns.0 = SIMD4(rs.columns.0, 0)
            result.columns.1 = SIMD4(rs.columns.1, 0)
            result.columns.2 = SIMD4(rs.columns.2, 0)
            return result
        }

        // Materials and the images they use. glTF factors are linear; the app keeps sRGB-encoded colours.
        var textures: [MeshTexture] = []
        var textureForImage: [Int: Int] = [:]
        func meshTexture(_ info: GLTFDocument.TextureInfo?) -> Int? {
            guard let info, let tex = doc.textures?[safe: info.index],
                  let imageIndex = tex.source ?? tex.extensions?.EXT_texture_webp?.source else { return nil }
            if let existing = textureForImage[imageIndex] { return existing }
            guard let image = doc.images?[safe: imageIndex] else { return nil }
            var bytes: Data?
            if let viewIndex = image.bufferView, let view = doc.bufferViews?[safe: viewIndex], let buffer = buffers[safe: view.buffer] {
                let start = view.byteOffset ?? 0
                if start + view.byteLength <= buffer.count { bytes = buffer.subdata(in: start..<(start + view.byteLength)) }
            } else if let uri = image.uri {
                if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                    bytes = Data(base64Encoded: String(uri[uri.index(after: comma)...]))
                } else if let baseURL, let decoded = uri.removingPercentEncoding {
                    bytes = try? Data(contentsOf: baseURL.deletingLastPathComponent().appendingPathComponent(decoded))
                }
            }
            guard let bytes, !bytes.isEmpty else { return nil }
            textures.append(MeshTexture(name: image.name ?? image.uri ?? "image \(imageIndex)", source: .encoded(bytes)))
            textureForImage[imageIndex] = textures.count - 1
            return textures.count - 1
        }
        let docMaterials = doc.materials ?? []
        var materials: [MeshMaterial] = docMaterials.map { m in
            var out = MeshMaterial(name: m.name ?? "")
            out.baseColorTexture = meshTexture(m.pbrMetallicRoughness?.baseColorTexture)
            let strength = m.extensions?.KHR_materials_emissive_strength?.emissiveStrength ?? 1
            if let e = m.emissiveFactor, e.count >= 3 {
                out.emissive = SIMD3(GLTFImporter.srgb(e[0] * strength), GLTFImporter.srgb(e[1] * strength), GLTFImporter.srgb(e[2] * strength))
                if out.emissive != .zero { out.emissiveTexture = meshTexture(m.emissiveTexture) }
            }
            out.unlit = m.extensions?.KHR_materials_unlit != nil
            switch m.alphaMode {
            case "MASK": out.alphaCutoff = m.alphaCutoff ?? 0.5
            // Blending isn't sorted here; only cut fully clear texels so glass stays visible.
            case "BLEND": out.alphaCutoff = 0.05
            default: break
            }
            return out
        }
        var defaultMaterial: UInt16?
        var triangleMaterials: [UInt16] = []

        var triangles = Mesh()
        var points = Mesh()
        var anyColor = !textures.isEmpty

        func emit(meshIndex: Int, transform: simd_float4x4) throws {
            guard let def = doc.meshes?[safe: meshIndex] else { return }
            for prim in def.primitives {
                let mode = prim.mode ?? 4
                guard [0, 4, 5, 6].contains(mode), let posIndex = prim.attributes["POSITION"] else { continue }
                let (pos, _) = try readFloats(posIndex)
                let count = pos.count / 3
                var part = Mesh()
                part.positions = (0..<count).map { SIMD3(pos[$0 * 3], pos[$0 * 3 + 1], pos[$0 * 3 + 2]) }
                if let ni = prim.attributes["NORMAL"], let (n, _) = try? readFloats(ni), n.count == count * 3 {
                    part.normals = (0..<count).map { SIMD3(n[$0 * 3], n[$0 * 3 + 1], n[$0 * 3 + 2]) }
                }
                let material = prim.material.flatMap { docMaterials[safe: $0] }
                let uvSet = material?.pbrMetallicRoughness?.baseColorTexture?.texCoord ?? 0
                if let ti = prim.attributes["TEXCOORD_\(uvSet)"] ?? prim.attributes["TEXCOORD_0"],
                   let (uv, nc) = try? readFloats(ti), nc == 2, uv.count == count * 2 {
                    part.texCoords = (0..<count).map { SIMD2(uv[$0 * 2], uv[$0 * 2 + 1]) }
                }
                // Vertex colour × base colour factor (both linear in glTF), stored sRGB-encoded.
                var factor = SIMD4<Float>(1, 1, 1, 1)
                if let f = material?.pbrMetallicRoughness?.baseColorFactor, f.count >= 3 {
                    factor = SIMD4(f[0], f[1], f[2], f.count >= 4 ? f[3] : 1)
                }
                if let ci = prim.attributes["COLOR_0"], let (c, nc) = try? readFloats(ci), c.count == count * nc {
                    part.colors = (0..<count).map {
                        GLTFImporter.color(SIMD4(c[$0 * nc], c[$0 * nc + 1], c[$0 * nc + 2], nc == 4 ? c[$0 * nc + 3] : 1) * factor)
                    }
                    anyColor = true
                } else {
                    // glTF's default material is white; fill explicitly so merged parts never fall back to grey.
                    let color = GLTFImporter.color(factor)
                    if color != .white { anyColor = true }
                    part.colors = [RGBA8](repeating: color, count: count)
                }
                var idx: [UInt32] = try prim.indices.map(readIndices) ?? (0..<UInt32(count)).map { $0 }
                switch mode {
                case 5: // strip
                    var t: [UInt32] = []
                    if idx.count >= 3 {
                        for i in 0..<(idx.count - 2) {
                            if i % 2 == 0 { t += [idx[i], idx[i + 1], idx[i + 2]] } else { t += [idx[i + 1], idx[i], idx[i + 2]] }
                        }
                    }
                    idx = t
                case 6: // fan
                    var t: [UInt32] = []
                    if idx.count >= 3 { for i in 1..<(idx.count - 1) { t += [idx[0], idx[i], idx[i + 1]] } }
                    idx = t
                default: break
                }
                if mode == 0 {
                    part.apply(transform)
                    points.append(part)
                } else {
                    part.indices = idx
                    part.apply(transform)
                    triangles.append(part)
                    var slot: UInt16
                    if let mi = prim.material, mi >= 0, mi < materials.count {
                        slot = UInt16(mi)
                    } else {
                        if defaultMaterial == nil {
                            materials.append(MeshMaterial())
                            defaultMaterial = UInt16(materials.count - 1)
                        }
                        slot = defaultMaterial!
                    }
                    triangleMaterials += [UInt16](repeating: slot, count: part.triangleCount)
                }
            }
        }

        let nodes = doc.nodes ?? []
        func visit(_ index: Int, _ parent: simd_float4x4, depth: Int) throws {
            guard depth < 64, let node = nodes[safe: index] else { return }
            let world = parent * localMatrix(node)
            if let m = node.mesh { try emit(meshIndex: m, transform: world) }
            for c in node.children ?? [] { try visit(c, world, depth: depth + 1) }
        }
        let sceneIndex = doc.scene ?? 0
        if let roots = doc.scenes?[safe: sceneIndex]?.nodes {
            for r in roots { try visit(r, matrix_identity_float4x4, depth: 0) }
        } else if !nodes.isEmpty {
            let children = Set(nodes.flatMap { $0.children ?? [] })
            for i in nodes.indices where !children.contains(i) { try visit(i, matrix_identity_float4x4, depth: 0) }
        } else {
            for i in (doc.meshes ?? []).indices { try emit(meshIndex: i, transform: matrix_identity_float4x4) }
        }

        var result = triangles.isEmpty ? points : triangles
        if !triangles.isEmpty && triangleMaterials.count == triangles.triangleCount && materials.contains(where: { !$0.isPlain }) {
            result.materials = materials
            result.textures = textures
            result.triangleMaterials = triangleMaterials
        }
        if !anyColor { result.colors = [] }
        if !result.hasTextures { result.texCoords = [] }
        guard !result.isEmpty else { throw ImportError.empty }
        result.sanitize()
        return result
    }

    /// Linear → sRGB transfer (glTF stores linear factors; the app works in sRGB like most files).
    static func srgb(_ x: Float) -> Float {
        let v = min(max(x, 0), 1)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    static func color(_ linear: SIMD4<Float>) -> RGBA8 {
        RGBA8(unit: Double(srgb(linear.x)), Double(srgb(linear.y)), Double(srgb(linear.z)), Double(min(max(linear.w, 0), 1)))
    }
}

nonisolated extension Array {
    subscript(safe index: Int) -> Element? { index >= 0 && index < count ? self[index] : nil }
}
