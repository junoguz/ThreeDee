//
//  ModelFormat.swift
//  ThreeDee
//

import Foundation
import UniformTypeIdentifiers

/// File formats ThreeDee can read.
nonisolated enum ModelFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case step, ply, stl, obj, off, glb, gltf, usd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .step: "STEP"
        case .ply: "PLY"
        case .stl: "STL"
        case .obj: "OBJ"
        case .off: "OFF"
        case .glb: "GLB"
        case .gltf: "glTF"
        case .usd: "USD"
        }
    }

    var subtitle: String {
        switch self {
        case .step: "ISO 10303 CAD exchange"
        case .ply: "Polygon file / point cloud"
        case .stl: "Stereolithography"
        case .obj: "Wavefront object"
        case .off: "Object file format"
        case .glb: "glTF binary"
        case .gltf: "glTF JSON"
        case .usd: "Universal Scene Description"
        }
    }

    var fileExtensions: [String] {
        switch self {
        case .step: ["stp", "step", "p21"]
        case .ply: ["ply"]
        case .stl: ["stl"]
        case .obj: ["obj"]
        case .off: ["off"]
        case .glb: ["glb"]
        case .gltf: ["gltf"]
        case .usd: ["usdz", "usd", "usda", "usdc"]
        }
    }

    /// Unit a file of this format is defined in, when the format specifies one.
    /// `nil` means the format is unitless and the user's default applies.
    var definedUnit: LengthUnit? {
        switch self {
        case .glb, .gltf: .meter            // glTF 2.0 §3.4: units are metres
        case .usd: .centimeter              // USD default metersPerUnit = 0.01
        case .step: .millimeter             // STEP importer converts declared units to mm
        case .ply, .stl, .obj, .off: nil
        }
    }

    /// Conventional up axis.
    var upAxis: UpAxis {
        switch self {
        case .obj, .glb, .gltf, .usd: .y
        case .step, .ply, .stl, .off: .z
        }
    }

    static func detect(_ url: URL) -> ModelFormat? {
        let ext = url.pathExtension.lowercased()
        return allCases.first { $0.fileExtensions.contains(ext) }
    }

    static var allExtensions: [String] { allCases.flatMap(\.fileExtensions) }

    /// Content types accepted by the document picker.
    static var contentTypes: [UTType] {
        var types: [UTType] = []
        for ext in allExtensions {
            if let t = UTType(filenameExtension: ext), !types.contains(t) { types.append(t) }
        }
        for id in ["org.iso.step", "public.polygon-file-format", "public.standard-tesselated-geometry-format",
                   "public.geometry-definition-format", "org.khronos.gltf.binary", "org.khronos.gltf",
                   "com.princeton.off", "com.pixar.universal-scene-description-mobile"] {
            if let t = UTType(id), !types.contains(t) { types.append(t) }
        }
        return types
    }
}
