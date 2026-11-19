//
//  SettingsScreen.swift
//  ThreeDee
//

import AVFoundation
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var s = settings
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            CapsLabel("Preferences")
                            Text("Settings").font(Typography.display(32)).foregroundStyle(Palette.ink)
                        }
                        Spacer()
                        IconButton(systemName: "xmark", size: 36) { dismiss() }
                    }

                    section("Measurement") {
                        item("Grid & read-outs", "Viewer grid cells and every dimension use this unit.") {
                            PillPicker(options: GridUnit.allCases.map { ($0, $0.name) }, selection: $s.gridUnit)
                        }
                        divider
                        item("Unitless files", "STL, PLY, OBJ and OFF carry no unit. Their numbers are read as:") {
                            PillPicker(options: LengthUnit.allCases.map { ($0, $0.symbol) }, selection: $s.unitlessUnit, compact: true)
                        }
                    }

                    section("Viewer") {
                        toggle("Metric grid", "Ground grid under the model, scaled to its size.", $s.showGrid)
                        divider
                        toggle("World axes", "X / Y axes through the origin and a Z marker.", $s.showAxes)
                        divider
                        item("Default display", nil) {
                            PillPicker(options: RenderStyle.allCases.map { ($0, $0.title) }, selection: $s.renderStyle, compact: true)
                        }
                        divider
                        item("STEP tessellation", "Finer settings follow curved CAD surfaces more closely but produce heavier meshes.") {
                            PillPicker(options: TessellationQuality.allCases.map { ($0, $0.title) }, selection: $s.quality, compact: true)
                        }
                    }

                    section("Head-tracked parallax") {
                        toggle("Dynamic view", "The front camera follows your face so the model shifts subtly as you move, and leaning in zooms closer — like the Home Screen parallax.", $s.parallaxEnabled)
                        divider
                        item("Intensity", nil) {
                            HStack(spacing: 12) {
                                Image(systemName: "circle.dotted").foregroundStyle(Palette.inkSecondary)
                                Slider(value: $s.parallaxStrength, in: 0.15...1).tint(Palette.ink)
                                Image(systemName: "circle.circle").foregroundStyle(Palette.ink)
                            }
                            .disabled(!settings.parallaxEnabled)
                            .opacity(settings.parallaxEnabled ? 1 : 0.4)
                        }
                        divider
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lock").foregroundStyle(Palette.ink)
                            Text(cameraNote).font(Typography.body(13)).foregroundStyle(Palette.inkSecondary)
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                            Button("Open Settings to allow camera") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                            .padding([.horizontal, .bottom], 16)
                        }
                    }

                    section("Immersion & VR headset") {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "visionpro").foregroundStyle(Palette.ink)
                            Text("Immersion puts you inside a model at true human scale. VR splits the screen for phone headsets (Cardboard-style) and follows your head with the motion sensors.")
                                .font(Typography.body(13)).foregroundStyle(Palette.inkSecondary)
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        divider
                        item("Lens spacing", "Distance between your headset's lens centres. Match it to your eyes if the image looks doubled.") {
                            HStack(spacing: 12) {
                                Slider(value: $s.vrLensSpacing, in: 55...75, step: 0.5).tint(Palette.ink)
                                Text(String(format: "%.1f mm", settings.vrLensSpacing))
                                    .font(Typography.mono(12)).foregroundStyle(Palette.ink)
                                    .frame(width: 64, alignment: .trailing)
                            }
                        }
                        divider
                        toggle("Lens correction", "Pre-distorts each eye's image so straight lines stay straight through the lenses. Turn off for viewers without lenses.", $s.vrDistortion)
                    }

                    section("Appearance") {
                        item("Theme", "Paper is cobalt on white; Blueprint inverts it.") {
                            PillPicker(options: AppearanceMode.allCases.map { ($0, $0.title) }, selection: $s.appearance)
                        }
                    }

                    section("Formats") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(ModelFormat.allCases) { f in
                                HStack {
                                    FormatChip(text: f.title)
                                    Text(f.subtitle).font(Typography.body(13)).foregroundStyle(Palette.inkSecondary)
                                    Spacer()
                                    Text(f.fileExtensions.map { "." + $0 }.joined(separator: " "))
                                        .font(Typography.mono(10)).foregroundStyle(Palette.inkTertiary)
                                }
                            }
                            Text("Export: " + ExportFormat.allCases.map(\.title).joined(separator: " · "))
                                .font(Typography.mono(11)).foregroundStyle(Palette.inkSecondary).padding(.top, 4)
                        }
                        .padding(16)
                    }

                    Text("ThreeDee \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Files live in Files › On My iPhone › ThreeDee")
                        .font(Typography.mono(10))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .padding(20)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var cameraNote: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: "Camera access is off, so the view stays static. Allow it in Settings to use head tracking."
        default: "Frames are analysed on-device to find your face and discarded immediately. Nothing is recorded or stored."
        }
    }

    // MARK: Building blocks

    private var divider: some View {
        Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.leading, 16)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(title)
            VStack(alignment: .leading, spacing: 0) { content() }.card()
        }
    }

    private func item<Control: View>(_ title: String, _ detail: String?, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Typography.label(15)).foregroundStyle(Palette.ink)
            if let detail { Text(detail).font(Typography.body(13)).foregroundStyle(Palette.inkSecondary) }
            control()
        }
        .padding(16)
    }

    private func toggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Typography.label(15)).foregroundStyle(Palette.ink)
                Text(detail).font(Typography.body(13)).foregroundStyle(Palette.inkSecondary)
            }
        }
        .tint(Palette.ink)
        .padding(16)
    }
}
