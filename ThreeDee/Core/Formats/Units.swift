//
//  Units.swift
//  ThreeDee
//

import Foundation
import simd

/// Physical length units a file can be authored in.
nonisolated enum LengthUnit: String, CaseIterable, Codable, Sendable, Identifiable {
    case millimeter = "mm"
    case centimeter = "cm"
    case meter = "m"
    case inch = "in"

    var id: String { rawValue }
    var symbol: String { rawValue }

    var millimeters: Double {
        switch self {
        case .millimeter: 1
        case .centimeter: 10
        case .meter: 1000
        case .inch: 25.4
        }
    }

    var name: String {
        switch self {
        case .millimeter: "Millimetres"
        case .centimeter: "Centimetres"
        case .meter: "Metres"
        case .inch: "Inches"
        }
    }
}

/// The metric the viewer grid and all read-outs use (changeable in Settings).
nonisolated enum GridUnit: String, CaseIterable, Codable, Sendable, Identifiable {
    case millimeter = "mm"
    case centimeter = "cm"

    var id: String { rawValue }
    var millimeters: Double { self == .millimeter ? 1 : 10 }
    var name: String { self == .millimeter ? "Millimetres" : "Centimetres" }

    /// Formats a length given in millimetres in this unit.
    func format(_ mm: Double, digits: Int? = nil) -> String {
        let value = mm / millimeters
        let d = digits ?? GridUnit.suggestedDigits(value)
        return String(format: "%.\(d)f %@", value, rawValue)
    }

    func formatValue(_ mm: Double, digits: Int? = nil) -> String {
        let value = mm / millimeters
        let d = digits ?? GridUnit.suggestedDigits(value)
        return String(format: "%.\(d)f", value)
    }

    static func suggestedDigits(_ value: Double) -> Int {
        let a = abs(value)
        if a == 0 { return 0 }
        if a >= 1000 { return 0 }
        if a >= 100 { return 1 }
        if a >= 1 { return 2 }
        return 3
    }
}

/// Which axis points up in a file's coordinate system.
nonisolated enum UpAxis: String, CaseIterable, Codable, Sendable, Identifiable {
    case z = "Z"
    case y = "Y"

    var id: String { rawValue }

    /// Rotation taking this convention to the app's canonical Z-up world.
    var toZUp: simd_float4x4 {
        switch self {
        case .z: return matrix_identity_float4x4
        case .y:
            // +Y -> +Z, +Z -> -Y (rotate +90° about X)
            return simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 0, 1))
        }
    }

    /// Rotation taking the canonical Z-up world back to this convention.
    var fromZUp: simd_float4x4 { toZUp.inverse }
}

nonisolated enum TessellationQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case draft, standard, fine

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Chord tolerance relative to the model's bounding-box diagonal.
    var relativeChordTolerance: Double {
        switch self {
        case .draft: 0.003
        case .standard: 0.0008
        case .fine: 0.0002
        }
    }

    /// Maximum angle (radians) spanned by one segment of a curved edge.
    var maxSegmentAngle: Double {
        switch self {
        case .draft: 22 * .pi / 180
        case .standard: 12 * .pi / 180
        case .fine: 6 * .pi / 180
        }
    }
}
