//
//  AppSettings.swift
//  ThreeDee
//

import Foundation
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case paper, blueprint, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .paper: "Paper"
        case .blueprint: "Blueprint"
        case .system: "System"
        }
    }
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .paper: .light
        case .blueprint: .dark
        case .system: .unspecified
        }
    }
}

enum RenderStyle: String, CaseIterable, Identifiable {
    case solid, edges, wireframe, points
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: "Solid"
        case .edges: "Edges"
        case .wireframe: "Wire"
        case .points: "Points"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var gridUnit: GridUnit { didSet { defaults.set(gridUnit.rawValue, forKey: "gridUnit") } }
    var unitlessUnit: LengthUnit { didSet { defaults.set(unitlessUnit.rawValue, forKey: "unitlessUnit") } }
    var parallaxEnabled: Bool { didSet { defaults.set(parallaxEnabled, forKey: "parallaxEnabled") } }
    var parallaxStrength: Double { didSet { defaults.set(parallaxStrength, forKey: "parallaxStrength") } }
    var showGrid: Bool { didSet { defaults.set(showGrid, forKey: "showGrid") } }
    var showAxes: Bool { didSet { defaults.set(showAxes, forKey: "showAxes") } }
    var renderStyle: RenderStyle { didSet { defaults.set(renderStyle.rawValue, forKey: "renderStyle") } }
    var quality: TessellationQuality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var lastExportFormat: ExportFormat { didSet { defaults.set(lastExportFormat.rawValue, forKey: "lastExportFormat") } }
    /// Distance between the VR headset's lens centres (mm); also the virtual eye separation.
    var vrLensSpacing: Double { didSet { defaults.set(vrLensSpacing, forKey: "vrLensSpacing") } }
    /// Pre-distort the split-screen image for the headset's magnifying lenses.
    var vrDistortion: Bool { didSet { defaults.set(vrDistortion, forKey: "vrDistortion") } }

    var headsetProfile: HeadsetProfile {
        var p = HeadsetProfile()
        p.lensSpacing = Float(vrLensSpacing)
        p.correctsDistortion = vrDistortion
        return p
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        gridUnit = GridUnit(rawValue: defaults.string(forKey: "gridUnit") ?? "") ?? .millimeter
        unitlessUnit = LengthUnit(rawValue: defaults.string(forKey: "unitlessUnit") ?? "") ?? .millimeter
        parallaxEnabled = defaults.object(forKey: "parallaxEnabled") as? Bool ?? true
        parallaxStrength = defaults.object(forKey: "parallaxStrength") as? Double ?? 0.6
        showGrid = defaults.object(forKey: "showGrid") as? Bool ?? true
        showAxes = defaults.object(forKey: "showAxes") as? Bool ?? true
        renderStyle = RenderStyle(rawValue: defaults.string(forKey: "renderStyle") ?? "") ?? .edges
        quality = TessellationQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .standard
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .paper
        lastExportFormat = ExportFormat(rawValue: defaults.string(forKey: "lastExportFormat") ?? "") ?? .stlBinary
        vrLensSpacing = defaults.object(forKey: "vrLensSpacing") as? Double ?? 63.5
        vrDistortion = defaults.object(forKey: "vrDistortion") as? Bool ?? true
    }
}
