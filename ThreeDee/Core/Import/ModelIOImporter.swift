//
//  ModelIOImporter.swift
//  ThreeDee
//
//  USD / USDZ / USDA / USDC through Model I/O.
//

import Foundation
import ModelIO
import simd

nonisolated enum ModelIOImporter {
    static func load(_ url: URL) throws -> Mesh {
        guard MDLAsset.canImportFileExtension(url.pathExtension.lowercased()) else {
            throw ImportError.unsupportedFormat(url.pathExtension)
        }
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: MDLMeshBufferDataAllocator())
        var result = Mesh()
        var points = Mesh()

        func visit(_ object: MDLObject, depth: Int) {
            guard depth < 64 else { return }
            if let mesh = object as? MDLMesh {
                let world = MDLTransform.globalTransform(with: object, atTime: 0)
                if let part = extract(mesh) {
                    let transformed = part.applying(world)
                    if transformed.isPointCloud { points.append(transformed) } else { result.append(transformed) }
                }
            }
            for child in object.children.objects { visit(child, depth: depth + 1) }
        }
        for i in 0..<asset.count {
            visit(asset.object(at: i), depth: 0)
        }
        if result.isEmpty { result = points }
        guard !result.isEmpty else { throw ImportError.empty }
        result.sanitize()
        return result
    }

    private static func extract(_ mesh: MDLMesh) -> Mesh? {
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
        for case let sub as MDLSubmesh in mesh.submeshes ?? [] {
            guard sub.geometryType == .triangles else { continue }
            let buffer = sub.indexBuffer(asIndexType: .uInt32)
            let map = buffer.map()
            let ptr = map.bytes.assumingMemoryBound(to: UInt32.self)
            out.indices.append(contentsOf: UnsafeBufferPointer(start: ptr, count: sub.indexCount))
        }
        return out
    }

    private static func readVec3(_ data: MDLVertexAttributeData, count: Int) -> [SIMD3<Float>] {
        let raw = data.map.bytes
        return (0..<count).map { i in
            let p = raw.advanced(by: i * data.stride).assumingMemoryBound(to: Float.self)
            return SIMD3(p[0], p[1], p[2])
        }
    }
}
