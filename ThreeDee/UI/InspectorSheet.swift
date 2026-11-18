//
//  InspectorSheet.swift
//  ThreeDee
//
//  Measurements, geometry statistics and source-unit / axis overrides.
//

import SwiftUI

struct InspectorSheet: View {
    let item: LibraryItem
    let model: ViewerModel
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let prepared = model.prepared { measurements(prepared) }
                    sourceSection
                    if let details = model.imported?.details, !details.isEmpty { detailSection(details) }
                }
                .padding(20)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsLabel("Inspector")
            Text(item.displayName).font(Typography.display(26)).foregroundStyle(Palette.ink).lineLimit(2)
            HStack(spacing: 8) {
                FormatChip(text: item.format.title)
                Text(item.format.subtitle).font(Typography.body(13)).foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    private func measurements(_ p: PreparedMesh) -> some View {
        let unit = settings.gridUnit
        let size = p.bounds.size
        let areaUnit = unit.millimeters * unit.millimeters
        let volumeUnit = areaUnit * unit.millimeters
        return VStack(alignment: .leading, spacing: 10) {
            CapsLabel("Measurements · \(unit.rawValue)")
            HStack(spacing: 10) {
                dimension("X", size.x, unit)
                dimension("Y", size.y, unit)
                dimension("Z", size.z, unit)
            }
            VStack(spacing: 0) {
                if p.mesh.isPointCloud {
                    row("Points", p.mesh.vertexCount.formatted())
                } else {
                    row("Triangles", p.mesh.triangleCount.formatted())
                    row("Vertices", p.mesh.vertexCount.formatted())
                    row("Surface area", String(format: "%.2f %@²", p.statistics.surfaceArea / areaUnit, unit.rawValue))
                    if p.statistics.isClosed {
                        row("Volume", String(format: "%.2f %@³", p.statistics.volume / volumeUnit, unit.rawValue))
                        row("Watertight", "Yes")
                    } else {
                        row("Watertight", "No · \(p.statistics.boundaryEdges.formatted()) open edges")
                    }
                }
                row("Bounds min", vector(p.bounds.min, unit))
                row("Bounds max", vector(p.bounds.max, unit), last: true)
            }
            .card()
        }
    }

    private var sourceSection: some View {
        let meta = item.metadata
        let isStep = item.format == .step
        return VStack(alignment: .leading, spacing: 10) {
            CapsLabel("Source")
            VStack(spacing: 0) {
                row("File size", ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                if let imported = model.imported {
                    row("Interpreted unit", "\(imported.sourceUnit.name)\(imported.unitIsDeclared ? " (declared)" : "")")
                    row("Up axis", imported.upAxis.rawValue, last: isStep)
                }
                if !isStep {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Unit override").font(Typography.label(14)).foregroundStyle(Palette.ink)
                        PillPicker(options: [(Optional<LengthUnit>.none, "Auto")] + LengthUnit.allCases.map { (Optional($0), $0.symbol) },
                                   selection: Binding(get: { meta?.unitOverride }, set: {
                                       store.setOverrides(for: item.fileName, unit: $0, upAxis: meta?.upAxisOverride)
                                   }), compact: true)
                        Text("Unitless formats default to \(settings.unitlessUnit.name.lowercased()) (Settings). Use an override when a file was authored in another unit, e.g. scans in metres.")
                            .font(Typography.body(12)).foregroundStyle(Palette.inkSecondary)
                        Text("Up axis").font(Typography.label(14)).foregroundStyle(Palette.ink).padding(.top, 6)
                        PillPicker(options: [(Optional<UpAxis>.none, "Auto"), (Optional(UpAxis.z), "Z up"), (Optional(UpAxis.y), "Y up")],
                                   selection: Binding(get: { meta?.upAxisOverride }, set: {
                                       store.setOverrides(for: item.fileName, unit: meta?.unitOverride, upAxis: $0)
                                   }), compact: true)
                    }
                    .padding(14)
                }
            }
            .card()
        }
    }

    private func detailSection(_ details: [ImportedModel.Detail]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel("\(item.format.title) header")
            VStack(spacing: 0) {
                ForEach(Array(details.enumerated()), id: \.offset) { i, d in
                    row(d.label, d.value, last: i == details.count - 1)
                }
            }
            .card()
        }
    }

    // MARK: Pieces

    private func dimension(_ axis: String, _ mm: Float, _ unit: GridUnit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(axis).font(Typography.mono(11, weight: .bold)).foregroundStyle(Palette.inkSecondary)
            Text(unit.formatValue(Double(mm))).font(Typography.mono(18, weight: .semibold)).foregroundStyle(Palette.ink)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(unit.rawValue).font(Typography.mono(10)).foregroundStyle(Palette.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card()
    }

    private func vector(_ v: SIMD3<Float>, _ unit: GridUnit) -> String {
        "\(unit.formatValue(Double(v.x), digits: 2)), \(unit.formatValue(Double(v.y), digits: 2)), \(unit.formatValue(Double(v.z), digits: 2))"
    }

    private func row(_ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Typography.body(14)).foregroundStyle(Palette.inkSecondary)
                Spacer(minLength: 12)
                Text(value).font(Typography.mono(13)).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if !last { Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.leading, 14) }
        }
    }
}

extension View {
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.paper))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}
