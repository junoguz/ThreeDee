//
//  TextureLoader.swift
//  ThreeDee
//
//  Turns a mesh's material images into mipmapped Metal textures off the main
//  thread. Images are downsampled to fit a memory budget (a Sketchfab scene
//  can carry dozens of 4K maps), decoded once with ImageIO and kept as raw
//  sRGB bytes, matching how vertex colours are shaded.
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd

/// Hands a GPU object created off the main thread to the renderer (Metal objects are thread-safe).
nonisolated struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

nonisolated enum TextureLoader {
    /// Decodes and uploads textures one by one in the background, yielding (index, texture) as each
    /// becomes ready. Stopping iteration cancels the remaining work.
    static func uploads(_ textures: [MeshTexture], device: MTLDevice) -> AsyncStream<(Int, UncheckedBox<MTLTexture>)> {
        let gpu = UncheckedBox(device)
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let device = gpu.value
                guard let queue = device.makeCommandQueue() else { continuation.finish(); return }
                let cap = sizeCap(for: textures)
                for (i, texture) in textures.enumerated() {
                    if Task.isCancelled { break }
                    let made: MTLTexture? = autoreleasepool {
                        guard let pixels = pixels(texture, maxSize: cap) else { return nil }
                        return makeTexture(width: pixels.width, height: pixels.height, data: pixels.data, device: device, queue: queue)
                    }
                    if let made { continuation.yield((i, UncheckedBox(made))) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// GPU bytes all textures of one model may use, scaled to the device's memory.
    static var budget: Int {
        let memory = Int(ProcessInfo.processInfo.physicalMemory)
        return min(max(memory / 12, 192 << 20), 768 << 20)
    }

    /// Largest edge length that keeps every texture (with mipmaps) inside the budget.
    static func sizeCap(for textures: [MeshTexture]) -> Int {
        let dims = textures.map(dimensions)
        for cap in [4096, 2048, 1024, 512] {
            var bytes = 0
            for (w, h) in dims {
                let s = min(1, Double(cap) / Double(max(w, h, 1)))
                bytes += Int(Double(w) * s) * Int(Double(h) * s) * 4 * 4 / 3
            }
            if bytes <= budget { return cap }
        }
        return 256
    }

    static func dimensions(_ texture: MeshTexture) -> (Int, Int) {
        switch texture.source {
        case .rgba8(let w, let h, _):
            return (w, h)
        case .encoded(let data):
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return (1024, 1024) }
            return (w, h)
        }
    }

    /// Decodes (and downsamples) one texture into tightly packed sRGB RGBA8.
    static func pixels(_ texture: MeshTexture, maxSize: Int) -> (width: Int, height: Int, data: Data)? {
        switch texture.source {
        case .rgba8(let w, let h, let data):
            if max(w, h) <= maxSize { return (w, h, data) }
            guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            return ModelIOImporter.rgba8(image, maxSize: maxSize)
        case .encoded(let data):
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let (w, h) = dimensions(texture)
            let image: CGImage?
            if max(w, h) > maxSize {
                // Decode straight to the target size instead of materialising the full image.
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                                                kCGImageSourceCreateThumbnailWithTransform: false,
                                                kCGImageSourceShouldCacheImmediately: true]
                image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            } else {
                image = CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            return image.flatMap { ModelIOImporter.rgba8($0, maxSize: maxSize) }
        }
    }

    /// Uploads RGBA8 pixels into a private, fully mipmapped texture.
    static func makeTexture(width: Int, height: Int, data: Data, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        let levels = Int(log2(Double(max(width, height)))) + 1
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: levels > 1)
        desc.usage = .shaderRead
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc),
              let staging = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: width * 4, sourceBytesPerImage: width * height * 4,
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin())
        if levels > 1 { blit.generateMipmaps(for: texture) }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed ? texture : nil
    }
}

/// Far-to-near draw order for Gaussian splats (they blend, so order matters).
nonisolated enum SplatSorter {
    /// 16-bit counting sort on view depth. Depth is quantised over the bulk of the scene (`focus`),
    /// so a few far-away splats don't wash out the precision where it matters.
    static func order(_ positions: [SIMD3<Float>], eye: SIMD3<Float>, forward: SIMD3<Float>, focus: BoundingBox,
                      device: MTLDevice) -> MTLBuffer? {
        let n = positions.count
        guard n > 0, let buffer = device.makeBuffer(length: n * 4, options: .storageModeShared) else { return nil }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for i in 0..<8 {
            let corner = SIMD3(i & 1 == 0 ? focus.min.x : focus.max.x, i & 2 == 0 ? focus.min.y : focus.max.y,
                               i & 4 == 0 ? focus.min.z : focus.max.z)
            let d = simd_dot(corner - eye, forward)
            lo = min(lo, d); hi = max(hi, d)
        }
        let bins = 65536
        let scale = Float(bins - 1) / max(hi - lo, 1e-9)
        var keys = [UInt16](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: bins + 1)
        positions.withUnsafeBufferPointer { p in
            keys.withUnsafeMutableBufferPointer { k in
                for i in 0..<n {
                    // Farthest first: key 0 is the far end.
                    let d = simd_dot(p[i] - eye, forward)
                    let key = UInt16(clamping: Int(((hi - d) * scale).rounded(.down)))
                    k[i] = key
                    counts[Int(key) + 1] += 1
                }
            }
        }
        for b in 0..<bins { counts[b + 1] += counts[b] }
        let out = buffer.contents().bindMemory(to: UInt32.self, capacity: n)
        for i in 0..<n {
            let k = Int(keys[i])
            out[counts[k]] = UInt32(i)
            counts[k] += 1
        }
        return buffer
    }
}
