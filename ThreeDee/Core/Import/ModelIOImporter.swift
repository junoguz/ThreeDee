//
//  ModelIOImporter.swift
//  ThreeDee
//
//  USD / USDZ / USDA / USDC through Model I/O, including UsdPreviewSurface
//  base colours, emission and their textures (LiDAR-scan exports are textured).
//

import CoreGraphics
import Foundation
import ModelIO
import simd

nonisolated enum ModelIOImporter {
    /// Largest texture edge kept in memory; the viewer may downsample further.
    static let maxTextureSize = 4096

    static func load(_ url: URL) throws -> Mesh {
        guard MDLAsset.canImportFileExtension(url.pathExtension.lowercased()) else {
            throw ImportError.unsupportedFormat(url.pathExtension)
        }
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: MDLMeshBufferDataAllocator())
        asset.loadTextures()
        var library = MaterialLibrary()
        var result = Mesh()
        var points = Mesh()
        var triangleMaterials: [UInt16] = []

        func visit(_ object: MDLObject, depth: Int) {
            guard depth < 64 else { return }
            if let mesh = object as? MDLMesh {
                let world = MDLTransform.globalTransform(with: object, atTime: 0)
                if let (part, materialIDs) = extract(mesh, library: &library) {
                    let transformed = part.applying(world)
                    if transformed.isPointCloud {
                        points.append(transformed)
                    } else {
                        result.append(transformed)
                        triangleMaterials += materialIDs
                    }
                }
            }
            for child in object.children.objects { visit(child, depth: depth + 1) }
        }
        for i in 0..<asset.count {
            visit(asset.object(at: i), depth: 0)
        }
        if result.isEmpty { result = points }
        guard !result.isEmpty else { throw ImportError.empty }
        if !result.isPointCloud, triangleMaterials.count == result.triangleCount,
           library.materials.contains(where: { !$0.isPlain }) {
            result.materials = library.materials
            result.textures = library.textures
            result.triangleMaterials = triangleMaterials
        }
        if !result.hasTextures { result.texCoords = [] }
        result.sanitize()
        return result
    }

    /// Materials and textures shared across all meshes of an asset (parts reference them by index).
    private struct MaterialLibrary {
        var materials: [MeshMaterial] = []
        var textures: [MeshTexture] = []
        var materialIndex: [ObjectIdentifier: UInt16] = [:]
        var textureIndex: [ObjectIdentifier: Int] = [:]
        var plain: UInt16?

        mutating func index(for material: MDLMaterial?) -> UInt16 {
            guard let material else {
                if let plain { return plain }
                materials.append(MeshMaterial())
                plain = UInt16(materials.count - 1)
                return plain!
            }
            if let i = materialIndex[ObjectIdentifier(material)] { return i }
            var out = MeshMaterial(name: material.name)
            if let p = material.property(with: .baseColor) {
                if let c = ModelIOImporter.color(of: p) { out.baseColor = c }
                out.baseColorTexture = texture(for: p)
            }
            if let p = material.property(with: .emission) {
                if let c = ModelIOImporter.color(of: p) { out.emissive = SIMD3(c.x, c.y, c.z) }
                if let t = texture(for: p) {
                    out.emissiveTexture = t
                    if out.emissive == .zero { out.emissive = SIMD3(1, 1, 1) }
                }
            }
            if let p = material.property(with: .opacity), p.type == .float, p.floatValue < 1 {
                out.alphaCutoff = 0.05
            }
            materials.append(out)
            let i = UInt16(materials.count - 1)
            materialIndex[ObjectIdentifier(material)] = i
            return i
        }

        mutating func texture(for property: MDLMaterialProperty) -> Int? {
            var source: MDLTexture?
            switch property.type {
            case .texture: source = property.textureSamplerValue?.texture
            case .URL: source = property.urlValue.flatMap { MDLURLTexture(url: $0, name: $0.lastPathComponent) }
            case .string: source = property.stringValue.flatMap { MDLURLTexture(url: URL(fileURLWithPath: $0), name: $0) }
            default: break
            }
            guard let source else { return nil }
            if let i = textureIndex[ObjectIdentifier(source)] { return i }
            guard let image = source.imageFromTexture()?.takeUnretainedValue(),
                  let pixels = ModelIOImporter.rgba8(image, maxSize: ModelIOImporter.maxTextureSize) else { return nil }
            textures.append(MeshTexture(name: source.name, source: .rgba8(width: pixels.width, height: pixels.height, pixels: pixels.data)))
            textureIndex[ObjectIdentifier(source)] = textures.count - 1
            return textures.count - 1
        }
    }

    /// One mesh in its local space, plus a library material index per triangle.
    private static func extract(_ mesh: MDLMesh, library: inout MaterialLibrary) -> (Mesh, [UInt16])? {
        guard let posData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { return nil }
        let count = mesh.vertexCount
        var out = Mesh()
        out.positions = readVec3(posData, count: count)
        if let n = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) {
            out.normals = readVec3(n, count: count)
        }
        if let c = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeColor, as: .float4) {
            let raw = c.map.bytes
            out.colors = (0..<count).map { i in
                let p = raw.advanced(by: i * c.stride).assumingMemoryBound(to: Float.self)
                return RGBA8(unit: Double(p[0]), Double(p[1]), Double(p[2]), Double(p[3]))
            }
        }
        if let t = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2) {
            let raw = t.map.bytes
            // USD's st origin is bottom-left; the app keeps top-left like glTF and Metal.
            out.texCoords = (0..<count).map { i in
                let p = raw.advanced(by: i * t.stride).assumingMemoryBound(to: Float.self)
                return SIMD2(p[0], 1 - p[1])
            }
        }
        var materialIDs: [UInt16] = []
        for case let sub as MDLSubmesh in mesh.submeshes ?? [] {
            guard sub.geometryType == .triangles else { continue }
            let buffer = sub.indexBuffer(asIndexType: .uInt32)
            let map = buffer.map()
            let ptr = map.bytes.assumingMemoryBound(to: UInt32.self)
            out.indices.append(contentsOf: UnsafeBufferPointer(start: ptr, count: sub.indexCount))
            materialIDs += [UInt16](repeating: library.index(for: sub.material), count: sub.indexCount / 3)
        }
        return (out, materialIDs)
    }

    private static func readVec3(_ data: MDLVertexAttributeData, count: Int) -> [SIMD3<Float>] {
        let raw = data.map.bytes
        return (0..<count).map { i in
            let p = raw.advanced(by: i * data.stride).assumingMemoryBound(to: Float.self)
            return SIMD3(p[0], p[1], p[2])
        }
    }

    /// Constant colour of a material property, sRGB-encoded (USD colours are linear).
    private static func color(of p: MDLMaterialProperty) -> SIMD4<Float>? {
        switch p.type {
        case .float3:
            let v = p.float3Value
            return SIMD4(GLTFImporter.srgb(v.x), GLTFImporter.srgb(v.y), GLTFImporter.srgb(v.z), 1)
        case .float4:
            let v = p.float4Value
            return SIMD4(GLTFImporter.srgb(v.x), GLTFImporter.srgb(v.y), GLTFImporter.srgb(v.z), v.w)
        case .color:
            guard let c = p.color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = c.converted(to: srgb, intent: .defaultIntent, options: nil),
                  let comps = converted.components, comps.count >= 3 else { return nil }
            return SIMD4(Float(comps[0]), Float(comps[1]), Float(comps[2]), comps.count > 3 ? Float(comps[3]) : 1)
        default:
            return nil
        }
    }

    /// Redraws an image as tightly packed sRGB RGBA8 (top row first), at most `maxSize` on its long edge.
    static func rgba8(_ image: CGImage, maxSize: Int) -> (width: Int, height: Int, data: Data)? {
        let scale = min(1, Double(maxSize) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, data) : nil
    }
}
