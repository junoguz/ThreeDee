//
//  ViewerScreen.swift
//  ThreeDee
//

import Observation
import SwiftUI

@Observable
final class ViewerModel {
    enum Phase: Equatable {
        case loading(Double)
        case ready
        case failed(String)
    }

    let fileName: String
    var phase: Phase = .loading(0)
    var imported: ImportedModel?
    var prepared: PreparedMesh?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadedOptions: ImportOptions?

    init(fileName: String) { self.fileName = fileName }

    func load(_ item: LibraryItem, options: ImportOptions, store: LibraryStore, settings: AppSettings) {
        guard options != loadedOptions || prepared == nil else { return }
        loadedOptions = options
        task?.cancel()
        phase = .loading(0)
        let url = item.url
        let name = item.fileName
        task = Task { [weak self] in
            let result: Result<(ImportedModel, PreparedMesh), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let model = try ModelLoader.load(url, options: options) { p in
                        Task { @MainActor [weak self] in
                            if case .loading = self?.phase { self?.phase = .loading(p) }
                        }
                    }
                    return .success((model, PreparedMesh.prepare(model.mesh)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let (model, prepared)):
                self.imported = model
                self.prepared = prepared
                self.phase = .ready
                store.record(model, for: name, settings: settings)
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    deinit { task?.cancel() }
}

struct ViewerScreen: View {
    let item: LibraryItem
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var model: ViewerModel
    @State private var controller = ViewerController()
    @State private var showInfo = false
    @State private var showExport = false
    @State private var originalColors = false
    @State private var showPresets = false

    init(item: LibraryItem) {
        self.item = item
        _model = State(initialValue: ViewerModel(fileName: item.fileName))
    }

    private var current: LibraryItem { store.item(named: item.fileName) ?? item }

    /// Physical objects outside ~1 mm…20 m usually mean the file's unit was misread.
    private var scaleLooksOff: Bool {
        guard item.format != .step, model.phase == .ready, current.metadata?.unitOverride == nil,
              let size = model.prepared?.bounds.size else { return false }
        let largest = max(size.x, size.y, size.z)
        return largest > 0 && (largest < 1 || largest > 20_000)
    }

    private var style: ViewerStyle {
        ViewerStyle(renderStyle: settings.renderStyle, originalColors: originalColors, showGrid: settings.showGrid,
                    showAxes: settings.showAxes, gridUnit: settings.gridUnit, blueprint: colorScheme == .dark,
                    parallaxEnabled: settings.parallaxEnabled, parallaxStrength: Float(settings.parallaxStrength))
    }

    var body: some View {
        ZStack {
            backdrop
            ViewerCanvas(prepared: model.prepared, style: style, controller: controller)
                .ignoresSafeArea()
                .opacity(model.phase == .ready ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: model.phase == .ready)
            chrome
            switch model.phase {
            case .loading(let progress): LoadingOverlay(name: item.displayName, format: item.format, progress: progress)
            case .failed(let message): FailureView(message: message) { dismiss() }
            case .ready: EmptyView()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(false)
        .onAppear {
            model.load(current, options: store.options(for: current, settings: settings), store: store, settings: settings)
            controller.setHeadTracking(settings.parallaxEnabled)
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-present"), i + 1 < args.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if args[i + 1] == "info" { showInfo = true }
                    if args[i + 1] == "export" { showExport = true }
                }
            }
            if args.contains("-presets") { showPresets = true }
            #endif
        }
        .onDisappear { controller.setHeadTracking(false) }
        .onChange(of: settings.parallaxEnabled) { _, on in controller.setHeadTracking(on) }
        .onChange(of: store.options(for: current, settings: settings)) { _, options in
            model.load(current, options: options, store: store, settings: settings)
        }
        .sheet(isPresented: $showInfo) {
            InspectorSheet(item: current, model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(items: [current], loaded: model.imported)
                .presentationDetents([.large])
        }
    }

    private var backdrop: some View {
        ZStack {
            Palette.paper
            RadialGradient(colors: [Palette.wash, .clear], center: .bottom, startRadius: 40, endRadius: 700)
        }
        .ignoresSafeArea()
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if model.phase == .ready { bottomBar }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconButton(systemName: "chevron.left") { dismiss() }
                Spacer(minLength: 8)
                if model.phase == .ready {
                    HeadTrackingPill(status: controller.headStatus, enabled: settings.parallaxEnabled) {
                        settings.parallaxEnabled.toggle()
                    }
                    IconButton(systemName: "info") { showInfo = true }
                    IconButton(systemName: "square.and.arrow.up", filled: true) { showExport = true }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayName)
                    .font(Typography.title(22))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    FormatChip(text: item.format.title)
                    if let m = model.imported {
                        Text("\(m.sourceUnit.symbol) · \(m.unitIsDeclared ? "declared" : "assumed") · \(m.upAxis.rawValue) up")
                            .font(Typography.mono(10))
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(1)
                    }
                }
                if scaleLooksOff {
                    Button { showInfo = true } label: {
                        Label("Scale looks off? Set the source unit", systemImage: "ruler")
                            .font(Typography.label(12))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Palette.wash))
                            .overlay(Capsule().strokeBorder(Palette.hairline))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .padding(.leading, 4)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom) {
                MeasureReadout(prepared: model.prepared, grid: settings.gridUnit, showGrid: settings.showGrid)
                Spacer()
                VStack(spacing: 8) {
                    if showPresets {
                        ForEach(ViewPreset.allCases) { preset in
                            Button(preset.title) { controller.look(preset) }
                                .font(Typography.mono(10, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .frame(width: 52, height: 30)
                                .background(Capsule().fill(Palette.paper.opacity(0.94)))
                                .overlay(Capsule().strokeBorder(Palette.hairline))
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    IconButton(systemName: showPresets ? "xmark" : "cube.transparent", size: 40) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showPresets.toggle() }
                    }
                    IconButton(systemName: "scope", size: 40) { controller.resetView() }
                }
            }
            HStack(spacing: 8) {
                if model.prepared?.mesh.isPointCloud == true {
                    Text("POINT CLOUD")
                        .font(Typography.mono(11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Capsule().fill(Palette.wash))
                        .overlay(Capsule().strokeBorder(Palette.hairline))
                    Spacer()
                } else {
                    @Bindable var s = settings
                    PillPicker(options: RenderStyle.allCases.map { ($0, $0.title) }, selection: $s.renderStyle, compact: true)
                }
                if model.prepared?.mesh.hasColors == true {
                    Button {
                        originalColors.toggle()
                    } label: {
                        Image(systemName: originalColors ? "paintpalette.fill" : "paintpalette")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(originalColors ? Palette.onInk : Palette.ink)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(originalColors ? Palette.ink : Palette.paper))
                            .overlay(Circle().strokeBorder(Palette.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show original colours")
                }
            }
        }
    }
}

// MARK: - HUD pieces

struct HeadTrackingPill: View {
    let status: FaceTracker.Status
    let enabled: Bool
    let toggle: () -> Void

    private var label: String {
        guard enabled else { return "Parallax off" }
        switch status {
        case .tracking: return "Tracking"
        case .searching, .starting: return "Looking"
        case .denied: return "No access"
        case .unavailable: return "No camera"
        case .idle: return "Paused"
        }
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(enabled && status == .tracking ? Palette.ink : Palette.inkTertiary).frame(width: 6, height: 6)
                    if enabled && status == .tracking {
                        Circle().stroke(Palette.ink, lineWidth: 1).frame(width: 12, height: 12)
                            .phaseAnimator([0.4, 1.0]) { content, phase in content.opacity(phase).scaleEffect(phase) }
                    }
                }
                .frame(width: 12, height: 12)
                Image(systemName: enabled ? "face.dashed" : "face.dashed.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(label.uppercased())
                    .font(Typography.mono(10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(enabled ? Palette.ink : Palette.inkSecondary)
            .padding(.horizontal, 11)
            .frame(height: 44)
            .background(Capsule().fill(Palette.paper.opacity(0.94)))
            .overlay(Capsule().strokeBorder(Palette.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Head-tracked parallax, \(label)")
    }
}

struct MeasureReadout: View {
    let prepared: PreparedMesh?
    let grid: GridUnit
    let showGrid: Bool

    var body: some View {
        let size = prepared?.bounds.size ?? .zero
        let spec = prepared.map { GridSpec.make(for: $0.bounds, unit: grid) }
        VStack(alignment: .leading, spacing: 6) {
            if showGrid, let spec {
                HStack(spacing: 10) {
                    legend(cells: 1, label: spec.minorLabel)
                    legend(cells: 3, label: spec.majorLabel)
                }
            }
            HStack(spacing: 10) {
                axis("X", size.x)
                axis("Y", size.y)
                axis("Z", size.z)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.paper.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
    }

    private func axis(_ name: String, _ mm: Float) -> some View {
        HStack(spacing: 4) {
            Text(name).font(Typography.mono(10, weight: .bold)).foregroundStyle(Palette.inkSecondary)
            Text(grid.format(Double(mm))).font(Typography.mono(12)).foregroundStyle(Palette.ink)
        }
    }

    private func legend(cells: Int, label: String) -> some View {
        HStack(spacing: 5) {
            Canvas { ctx, size in
                let side = size.height
                var p = Path()
                for i in 0...cells {
                    let x = CGFloat(i) * side / CGFloat(cells)
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: side))
                    p.move(to: CGPoint(x: 0, y: x)); p.addLine(to: CGPoint(x: side, y: x))
                }
                ctx.stroke(p, with: .color(Palette.ink), lineWidth: 0.75)
            }
            .frame(width: 10, height: 10)
            Text(label).font(Typography.mono(10)).foregroundStyle(Palette.inkSecondary)
        }
    }
}

struct LoadingOverlay: View {
    let name: String
    let format: ModelFormat
    let progress: Double

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Palette.hairline, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.04, progress))
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: progress)
                Text(progress > 0 ? "\(Int(progress * 100))" : "···")
                    .font(Typography.mono(15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
            }
            .frame(width: 72, height: 72)
            VStack(spacing: 4) {
                CapsLabel(format == .step ? "Tessellating B-rep" : "Reading \(format.title)")
                Text(name).font(Typography.title(17)).foregroundStyle(Palette.ink).lineLimit(1)
            }
        }
        .padding(.horizontal, 40)
    }
}

struct FailureView: View {
    let message: String
    let close: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.ink)
            Text("Couldn’t open this model").font(Typography.title(19)).foregroundStyle(Palette.ink)
            Text(message).font(Typography.body(14)).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            Button("Back to library", action: close).buttonStyle(InkButtonStyle(compact: true)).padding(.top, 6)
        }
        .padding(32)
    }
}
