//
//  ExportSheet.swift
//  ThreeDee
//
//  Convert one or many library items to another format, then share or save.
//

import SwiftUI
import UIKit

struct ExportSheet: View {
    let items: [LibraryItem]
    /// The already-loaded model when exporting from the viewer (skips re-reading the file).
    var loaded: ImportedModel? = nil

    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case choosing
        case working(done: Int, total: Int)
        case finished(urls: [URL], failures: [String])
    }

    @State private var format: ExportFormat = .stlBinary
    @State private var phase: Phase = .choosing
    @State private var savingToFiles = false

    private var hasPointCloud: Bool {
        if let loaded, items.count == 1 { return loaded.mesh.isPointCloud }
        return items.contains { $0.metadata?.isPointCloud == true }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    switch phase {
                    case .choosing: chooser
                    case .working(let done, let total): working(done, total)
                    case .finished(let urls, let failures): finished(urls, failures)
                    }
                }
                .padding(20)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { footer }
        }
        .onAppear {
            format = settings.lastExportFormat
            if hasPointCloud && !format.supportsPointClouds { format = .plyBinary }
        }
        .sheet(isPresented: $savingToFiles) {
            if case .finished(let urls, _) = phase {
                DocumentExporter(urls: urls).ignoresSafeArea()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                CapsLabel(items.count == 1 ? "Convert & export" : "Batch convert")
                Text(items.count == 1 ? items[0].displayName : "\(items.count) models")
                    .font(Typography.display(26))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                if items.count > 1 {
                    Text(items.map(\.displayName).joined(separator: " · "))
                        .font(Typography.body(13)).foregroundStyle(Palette.inkSecondary).lineLimit(2)
                }
            }
            Spacer()
            IconButton(systemName: "xmark", size: 36) { dismiss() }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            CapsLabel("Target format")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ExportFormat.allCases) { f in
                    let disabled = hasPointCloud && !f.supportsPointClouds
                    Button {
                        format = f
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(f.title).font(Typography.title(17))
                                Spacer()
                                Text(".\(f.fileExtension)").font(Typography.mono(11))
                            }
                            Text(f.detail).font(Typography.body(12)).multilineTextAlignment(.leading)
                                .foregroundStyle(format == f ? Palette.onInk.opacity(0.8) : Palette.inkSecondary)
                        }
                        .foregroundStyle(format == f ? Palette.onInk : Palette.ink)
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(format == f ? Palette.ink : Palette.paper))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline))
                        .opacity(disabled ? 0.35 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                }
            }
            .sensoryFeedback(.selection, trigger: format)
            conventionNote
        }
    }

    private var conventionNote: some View {
        let unit = format.unit(unitless: settings.unitlessUnit)
        var notes = ["Written in \(unit.name.lowercased()), \(format.upAxis.rawValue) up."]
        if !format.preservesColors { notes.append("Colours are not stored.") }
        if format == .step { notes.append("Meshes become a faceted B-rep (one planar face per triangle).") }
        if hasPointCloud { notes.append("Point clouds can only be written to PLY, OBJ, OFF or GLB.") }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "ruler").foregroundStyle(Palette.ink)
            Text(notes.joined(separator: " ")).font(Typography.body(13)).foregroundStyle(Palette.inkSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.wash))
    }

    private func working(_ done: Int, _ total: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(Palette.ink)
            Text("Converting \(min(done + 1, total)) of \(total) to \(format.title)…")
                .font(Typography.body(14)).foregroundStyle(Palette.inkSecondary)
        }
        .padding(.top, 30)
    }

    private func finished(_ urls: [URL], _ failures: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CapsLabel(failures.isEmpty ? "Done" : "Finished with issues")
            ForEach(urls, id: \.self) { url in
                HStack(spacing: 12) {
                    Image(systemName: "doc").foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent).font(Typography.label(14)).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(fileSize(url)).font(Typography.mono(11)).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").foregroundStyle(Palette.ink) }
                }
                .padding(14)
                .card()
            }
            ForEach(failures, id: \.self) { f in
                Text(f).font(Typography.body(13)).foregroundStyle(Palette.inkSecondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
            }
            if !urls.isEmpty {
                Text("Also saved in Files › On My iPhone › ThreeDee › Exports.")
                    .font(Typography.body(12)).foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch phase {
        case .choosing:
            Button {
                Task { await run() }
            } label: {
                Text("Convert to \(format.title)").frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .background(Palette.paper)
        case .finished(let urls, _) where !urls.isEmpty:
            HStack(spacing: 10) {
                ShareLink(items: urls) { Text("Share").frame(maxWidth: .infinity) }
                    .buttonStyle(OutlineButtonStyle())
                Button { savingToFiles = true } label: { Text("Save to Files").frame(maxWidth: .infinity) }
                    .buttonStyle(InkButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .background(Palette.paper)
        default:
            EmptyView()
        }
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func run() async {
        settings.lastExportFormat = format
        var urls: [URL] = []
        var failures: [String] = []
        phase = .working(done: 0, total: items.count)
        for (i, item) in items.enumerated() {
            do {
                if let loaded, items.count == 1 {
                    let destination = store.exportURL(baseName: item.displayName, format: format)
                    let mesh = loaded.mesh, unitless = settings.unitlessUnit, f = format, name = item.displayName
                    try await Task.detached(priority: .userInitiated) {
                        try ModelExporter.export(mesh, format: f, to: destination, unitless: unitless, name: name)
                    }.value
                    urls.append(destination)
                } else {
                    urls.append(try await store.convert(item, to: format, settings: settings))
                }
            } catch {
                failures.append("\(item.displayName): \(error.localizedDescription)")
            }
            phase = .working(done: i + 1, total: items.count)
        }
        withAnimation { phase = .finished(urls: urls, failures: failures) }
    }
}

/// Presents the system "Save to Files" picker for a set of files (copies them).
struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
