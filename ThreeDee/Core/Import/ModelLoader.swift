//
//  ModelLoader.swift
//  ThreeDee
//
//  Format detection plus normalisation into the app's canonical space:
//  millimetres, Z up.
//

import Foundation
import simd

nonisolated struct ImportOptions: Sendable, Equatable {
    /// Unit assumed for formats that carry none (STL, PLY, OBJ, OFF).
    var unitlessUnit: LengthUnit = .millimeter
    /// Per-file override of the source unit (ignored for STEP, which declares its unit).
    var unitOverride: LengthUnit? = nil
    /// Per-file override of the up axis.
    var upAxisOverride: UpAxis? = nil
    var quality: TessellationQuality = .standard
}

nonisolated struct ImportedModel: Sendable {
    /// Geometry in millimetres, Z up.
    var mesh: Mesh
    var format: ModelFormat
    /// Unit the file's raw numbers were interpreted in.
    var sourceUnit: LengthUnit
    /// Whether that unit came from the file/format rather than an assumption.
    var unitIsDeclared: Bool
    var upAxis: UpAxis
    /// Human-readable facts about the source file.
    var details: [Detail]

    struct Detail: Sendable, Hashable {
        var label: String
        var value: String
    }
}

nonisolated enum ModelLoader {
    static func load(_ url: URL, options: ImportOptions, progress: ((Double) -> Void)? = nil) throws -> ImportedModel {
        guard let format = ModelFormat.detect(url) else { throw ImportError.unsupportedFormat(url.pathExtension) }
        var details: [ImportedModel.Detail] = []
        let raw: Mesh
        var declaredUnit = format.definedUnit

        switch format {
        case .step:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let (mesh, summary) = try StepImporter.load(data, quality: options.quality, progress: progress)
            raw = mesh
            if !summary.schema.isEmpty { details.append(.init(label: "Schema", value: summary.schema)) }
            details.append(.init(label: "Declared unit", value: summary.unitDescription))
            details.append(.init(label: "Solids / shells", value: "\(summary.solids)"))
            details.append(.init(label: "B-rep faces", value: "\(summary.faces)"))
            if summary.instances > 1 { details.append(.init(label: "Placed instances", value: "\(summary.instances)")) }
            if summary.skippedFaces > 0 { details.append(.init(label: "Faces not meshed", value: "\(summary.skippedFaces)")) }
            declaredUnit = .millimeter
        case .ply:
            raw = try PLYImporter.load(Data(contentsOf: url, options: .mappedIfSafe))
        case .stl:
            raw = try STLImporter.load(Data(contentsOf: url, options: .mappedIfSafe))
        case .obj:
            raw = try OBJImporter.load(Data(contentsOf: url, options: .mappedIfSafe))
        case .off:
            raw = try OFFImporter.load(Data(contentsOf: url, options: .mappedIfSafe))
        case .glb, .gltf:
            raw = try GLTFImporter.load(Data(contentsOf: url, options: .mappedIfSafe), baseURL: url)
        case .usd:
            raw = try ModelIOImporter.load(url)
        }

        // Gaussian-splat captures (LiDAR / photogrammetry apps) are written in metres.
        let isSplat = format == .ply && raw.isPointCloud && raw.hasPointRadii
        if isSplat { details.append(.init(label: "Content", value: raw.hasSplats ? "3D Gaussian splats" : "Gaussian splats, shown as discs")) }

        let unit: LengthUnit
        let isDeclared: Bool
        if format != .step, let override = options.unitOverride {
            unit = override
            isDeclared = false
        } else if let declaredUnit {
            unit = declaredUnit
            isDeclared = format == .step || format == .glb || format == .gltf
        } else if isSplat {
            unit = .meter
            isDeclared = false
        } else {
            unit = options.unitlessUnit
            isDeclared = false
        }
        let axis = options.upAxisOverride ?? format.upAxis
        let s = Float(unit.millimeters)
        var mesh = raw
        mesh.apply(axis.toZUp * simd_float4x4(diagonal: SIMD4(s, s, s, 1)))
        progress?(1)
        return ImportedModel(mesh: mesh, format: format, sourceUnit: unit, unitIsDeclared: isDeclared,
                             upAxis: axis, details: details)
    }
}
