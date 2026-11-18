//
//  LibraryScreen.swift
//  ThreeDee
//

import simd
import SwiftUI
import UniformTypeIdentifiers

struct LibraryScreen: View {
    @Binding var path: [String]
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var importing = false
    @State private var showSettings = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var filter: ModelFormat?
    @State private var convertItems: [LibraryItem] = []
    @State private var renaming: LibraryItem?
    @State private var renameText = ""
    @State private var pendingDelete: [LibraryItem] = []

    private var visibleItems: [LibraryItem] {
        guard let filter else { return store.items }
        return store.items.filter { $0.format == filter }
    }

    private var presentFormats: [ModelFormat] {
        ModelFormat.allCases.filter { f in store.items.contains { $0.format == f } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if store.items.isEmpty {
                    EmptyLibraryView { importing = true }
                        .padding(.top, 24)
                } else {
                    if presentFormats.count > 1 { filterBar }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 158, maximum: 260), spacing: 14)], spacing: 18) {
                        ForEach(visibleItems) { item in
                            card(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, selecting ? 100 : 30)
        }
        .scrollIndicators(.hidden)
        .background(Palette.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
        .fileImporter(isPresented: $importing, allowedContentTypes: ModelFormat.contentTypes + [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await store.importFiles(urls, settings: settings) }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsScreen() }
        .sheet(isPresented: Binding(get: { !convertItems.isEmpty }, set: { if !$0 { convertItems = [] } })) {
            ExportSheet(items: convertItems)
        }
        .alert("Rename model", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let item = renaming { _ = store.rename(item, to: renameText) }
            }
        }
        .confirmationDialog(pendingDelete.count == 1 ? "Delete “\(pendingDelete.first?.displayName ?? "")”?" : "Delete \(pendingDelete.count) models?",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                pendingDelete.forEach(store.delete)
                selection.subtract(pendingDelete.map(\.fileName))
                pendingDelete = []
                if store.items.isEmpty { selecting = false }
            }
        } message: {
            Text("The original file is removed from ThreeDee’s Models folder.")
        }
        .alert("Import", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .task {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-present"), i + 1 < args.count {
                if args[i + 1] == "settings" { showSettings = true }
                if args[i + 1] == "convert" { convertItems = Array(store.items.prefix(3)) }
                if args[i + 1] == "select" { selecting = true; selection = Set(store.items.prefix(2).map(\.fileName)) }
            }
            #endif
            await store.reanalyzeStale(settings: settings)
        }
        .onChange(of: settings.unitlessUnit) { Task { await store.reanalyzeStale(settings: settings) } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "cube.transparent").font(.system(size: 13, weight: .semibold))
                    CapsLabel("ThreeDee · Library", color: Palette.ink)
                        .lineLimit(1)
                }
                .foregroundStyle(Palette.ink)
                Spacer()
                if !store.items.isEmpty {
                    Button(selecting ? "Done" : "Select") {
                        withAnimation(.snappy) {
                            selecting.toggle()
                            selection.removeAll()
                        }
                    }
                    .font(Typography.label(15))
                    .foregroundStyle(Palette.ink)
                    .padding(.trailing, 4)
                }
                IconButton(systemName: "gearshape", size: 40) { showSettings = true }
                IconButton(systemName: "plus", filled: true, size: 40) { importing = true }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Models")
                    .font(Typography.display(40))
                    .foregroundStyle(Palette.ink)
                Text(summary)
                    .font(Typography.mono(12))
                    .foregroundStyle(Palette.inkSecondary)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.top, 8)
    }

    private var summary: String {
        let n = store.items.count
        let formats = Set(store.items.map(\.format)).count
        let bytes = store.items.reduce(Int64(0)) { $0 + $1.byteSize }
        if n == 0 { return "No files yet" }
        return "\(n) file\(n == 1 ? "" : "s") · \(formats) format\(formats == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · grid in \(settings.gridUnit.rawValue)"
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", selected: filter == nil) { filter = nil }
                ForEach(presentFormats) { f in
                    chip(f.title, selected: filter == f) { filter = filter == f ? nil : f }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy) { action() } }) {
            Text(text)
                .font(Typography.mono(12, weight: .semibold))
                .foregroundStyle(selected ? Palette.onInk : Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected ? Palette.ink : Palette.paper))
                .overlay(Capsule().strokeBorder(Palette.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: Cards

    private func card(_ item: LibraryItem) -> some View {
        let selected = selection.contains(item.fileName)
        return Button {
            if selecting {
                if selected { selection.remove(item.fileName) } else { selection.insert(item.fileName) }
            } else {
                path.append(item.fileName)
            }
        } label: {
            ModelCard(item: item, analyzing: store.analyzing.contains(item.fileName), gridUnit: settings.gridUnit,
                      selecting: selecting, selected: selected)
        }
        .buttonStyle(CardPressStyle())
        .contextMenu {
            Button { path.append(item.fileName) } label: { Label("Open", systemImage: "cube") }
            Button { convertItems = [item] } label: { Label("Convert…", systemImage: "arrow.triangle.2.circlepath") }
            ShareLink(item: item.url) { Label("Share original", systemImage: "square.and.arrow.up") }
            Button {
                renameText = item.displayName
                renaming = item
            } label: { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { pendingDelete = [item] } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var selectionBar: some View {
        let chosen = store.items.filter { selection.contains($0.fileName) }
        return HStack(spacing: 10) {
            Text("\(chosen.count) selected")
                .font(Typography.mono(12))
                .foregroundStyle(Palette.inkSecondary)
            Spacer()
            Button { pendingDelete = chosen } label: { Image(systemName: "trash") }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(chosen.isEmpty)
            Button { convertItems = chosen } label: { Label("Convert", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(InkButtonStyle(compact: true))
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Palette.paper.shadow(.drop(color: .black.opacity(0.06), radius: 12, y: -2)))
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct ModelCard: View {
    let item: LibraryItem
    let analyzing: Bool
    let gridUnit: GridUnit
    var selecting = false
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.wash)
                    if let thumb = item.metadata?.thumbnail, !thumb.points.isEmpty {
                        StippleView(thumbnail: thumb).padding(18)
                    } else if item.metadata?.error != nil {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 24, weight: .light)).foregroundStyle(Palette.inkSecondary)
                    } else {
                        ProgressView().tint(Palette.ink)
                    }
                    CropMarks(length: 9).stroke(Palette.ink.opacity(0.45), lineWidth: 1).padding(10)
                    if analyzing && item.metadata?.thumbnail != nil {
                        ProgressView().tint(Palette.ink).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(14)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? Palette.ink : Palette.hairline, lineWidth: selected ? 2 : 1))
                FormatChip(text: item.format.title)
                    .background(Capsule().fill(Palette.paper))
                    .padding(12)
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.ink)
                        .background(Circle().fill(Palette.paper))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(Typography.label(15))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(dimensions)
                    .font(Typography.mono(11))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                Text(stats)
                    .font(Typography.mono(10))
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
    }

    private var dimensions: String {
        if let error = item.metadata?.error { return error }
        guard let s = item.metadata?.size, s.count == 3 else { return analyzing ? "Analysing…" : "—" }
        let parts = s.map { gridUnit.formatValue(Double($0), digits: GridUnit.suggestedDigits(Double($0) / gridUnit.millimeters) > 1 ? 1 : 0) }
        return "\(parts.joined(separator: " × ")) \(gridUnit.rawValue)"
    }

    private var stats: String {
        let size = ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)
        guard let m = item.metadata, m.error == nil, m.vertices > 0 else { return size }
        let count = m.isPointCloud ? "\(compact(m.vertices)) pts" : "\(compact(m.triangles)) tris"
        return "\(size) · \(count)\(m.unitIsDeclared || m.unitOverride != nil ? "" : " · \(m.sourceUnit.symbol)?")"
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}

/// Draws a stippled thumbnail: near points darker and larger.
struct StippleView: View {
    let thumbnail: StippleThumbnail

    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let ox = (size.width - side) / 2, oy = (size.height - side) / 2
            let pts = thumbnail.points
            var i = 0
            while i + 2 < pts.count {
                let x = ox + CGFloat(pts[i]) * side, y = oy + CGFloat(pts[i + 1]) * side
                let depth = CGFloat(pts[i + 2])
                let r = 0.55 + depth * 0.75
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(Palette.ink.opacity(0.25 + 0.75 * Double(depth))))
                i += 3
            }
        }
        .drawingGroup()
    }
}

struct EmptyLibraryView: View {
    let importAction: () -> Void
    @State private var spin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.wash)
                CropMarks(length: 12).stroke(Palette.ink.opacity(0.45), lineWidth: 1).padding(14)
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    StippleView(thumbnail: EmptyLibraryView.cube(angle: Float(t * 0.35)))
                        .padding(60)
                }
            }
            .aspectRatio(1.3, contentMode: .fit)
            VStack(alignment: .leading, spacing: 8) {
                Text("Bring in a model")
                    .font(Typography.display(28))
                    .foregroundStyle(Palette.ink)
                Text("Import CAD parts, scans and meshes from Files, AirDrop or any app’s share sheet. View them at true scale and convert between formats.")
                    .font(Typography.body(15))
                    .foregroundStyle(Palette.inkSecondary)
            }
            FlowChips(items: ModelFormat.allCases.flatMap { $0.fileExtensions.prefix(2) }.map { "." + $0 })
            Button(action: importAction) {
                Label("Import files", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle())
        }
    }

    /// A rotating stippled cube built from the thumbnail sampler.
    static func cube(angle: Float) -> StippleThumbnail {
        var mesh = Mesh()
        let c: [SIMD3<Float>] = [[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1], [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]]
        let rot = simd_float3x3(SIMD3(cos(angle), sin(angle), 0), SIMD3(-sin(angle), cos(angle), 0), SIMD3(0, 0, 1))
        mesh.positions = c.map { rot * $0 }
        mesh.indices = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7]
        return StippleThumbnail.make(from: mesh, count: 900)
    }
}

struct FlowChips: View {
    let items: [String]
    var body: some View {
        // Simple wrapping layout.
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { FormatChip(text: $0) }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            maxX = max(maxX, x)
            row = max(row, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
