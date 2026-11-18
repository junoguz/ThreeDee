//
//  LibraryStore.swift
//  ThreeDee
//
//  Imported originals live in Documents/Models (visible in the Files app);
//  conversions are written to Documents/Exports. Per-file metadata
//  (measurements, thumbnail, unit overrides) sits in Application Support.
//

import Foundation
import Observation

nonisolated struct ModelMetadata: Codable, Sendable, Equatable {
    var vertices: Int = 0
    var triangles: Int = 0
    var isPointCloud = false
    /// Bounding-box size in millimetres.
    var size: [Float] = [0, 0, 0]
    var sourceUnit: LengthUnit = .millimeter
    var unitIsDeclared = false
    var thumbnail: StippleThumbnail? = nil
    var error: String? = nil
    /// User overrides applied when loading.
    var unitOverride: LengthUnit? = nil
    var upAxisOverride: UpAxis? = nil
    /// Settings the metadata was computed with; recomputed when they change.
    var analyzedUnitless: LengthUnit? = nil
}

struct LibraryItem: Identifiable, Hashable {
    let fileName: String
    let url: URL
    let format: ModelFormat
    let byteSize: Int64
    let modified: Date
    var metadata: ModelMetadata?

    var id: String { fileName }
    var displayName: String { (fileName as NSString).deletingPathExtension }

    static func == (a: LibraryItem, b: LibraryItem) -> Bool { a.fileName == b.fileName && a.metadata == b.metadata && a.modified == b.modified }
    func hash(into hasher: inout Hasher) { hasher.combine(fileName) }
}

@Observable
final class LibraryStore {
    private(set) var items: [LibraryItem] = []
    /// File names currently being analysed.
    private(set) var analyzing: Set<String> = []
    var lastError: String?

    let modelsDirectory: URL
    let exportsDirectory: URL
    private let metadataDirectory: URL
    private let fm = FileManager.default

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        modelsDirectory = docs.appendingPathComponent("Models", isDirectory: true)
        exportsDirectory = docs.appendingPathComponent("Exports", isDirectory: true)
        metadataDirectory = support.appendingPathComponent("Metadata", isDirectory: true)
        for dir in [modelsDirectory, exportsDirectory, metadataDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        refresh()
    }

    // MARK: Listing

    func refresh() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? fm.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { url -> LibraryItem? in
            guard let format = ModelFormat.detect(url), let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return LibraryItem(fileName: url.lastPathComponent, url: url, format: format,
                               byteSize: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast,
                               metadata: loadMetadata(url.lastPathComponent))
        }
        .sorted { $0.modified > $1.modified }
    }

    func item(named fileName: String) -> LibraryItem? { items.first { $0.fileName == fileName } }

    // MARK: Import

    /// Copies external files into the library and analyses them. Returns the stored items.
    @discardableResult
    func importFiles(_ urls: [URL], settings: AppSettings) async -> [LibraryItem] {
        var imported: [String] = []
        var unsupported: [String] = []
        for url in urls {
            guard ModelFormat.detect(url) != nil else {
                unsupported.append(url.lastPathComponent)
                continue
            }
            // Already in the library (e.g. opened from Files › ThreeDee › Models).
            if url.standardizedFileURL.deletingLastPathComponent().path == modelsDirectory.standardizedFileURL.path {
                imported.append(url.lastPathComponent)
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let destination = uniqueDestination(for: url.lastPathComponent)
            do {
                var coordinatorError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readURL in
                    do { try self.fm.copyItem(at: readURL, to: destination) } catch { copyError = error }
                }
                if let e = coordinatorError ?? copyError as NSError? { throw e }
                // Make sure the copy is "new" for sorting.
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                imported.append(destination.lastPathComponent)
                // AirDrop / Mail hand files over through Documents/Inbox; don't leave duplicates behind.
                if url.standardizedFileURL.path.contains("/Documents/Inbox/") { try? fm.removeItem(at: url) }
            } catch {
                lastError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if !unsupported.isEmpty {
            lastError = "Unsupported file type: \(unsupported.joined(separator: ", ")). Supported: \(ModelFormat.allExtensions.joined(separator: ", "))."
        }
        refresh()
        for name in imported { await analyze(name, settings: settings) }
        return imported.compactMap(item(named:))
    }

    private func uniqueDestination(for fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = modelsDirectory.appendingPathComponent(fileName)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = modelsDirectory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Analysis

    func options(for item: LibraryItem, settings: AppSettings) -> ImportOptions {
        ImportOptions(unitlessUnit: settings.unitlessUnit, unitOverride: item.metadata?.unitOverride,
                      upAxisOverride: item.metadata?.upAxisOverride, quality: settings.quality)
    }

    /// Loads a model off the main thread to compute its measurements and thumbnail.
    func analyze(_ fileName: String, settings: AppSettings) async {
        guard let item = item(named: fileName), !analyzing.contains(fileName) else { return }
        analyzing.insert(fileName)
        defer { analyzing.remove(fileName) }
        let options = options(for: item, settings: settings)
        var meta = item.metadata ?? ModelMetadata()
        let url = item.url
        let result: Result<(ImportedModel, StippleThumbnail), Error> = await Task.detached(priority: .utility) {
            do {
                let model = try ModelLoader.load(url, options: options)
                return .success((model, StippleThumbnail.make(from: model.mesh)))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let (model, thumb)):
            update(&meta, with: model)
            meta.thumbnail = thumb
            meta.error = nil
        case .failure(let error):
            meta.error = error.localizedDescription
        }
        meta.analyzedUnitless = settings.unitlessUnit
        saveMetadata(meta, for: fileName)
        refresh()
    }

    /// Records measurements from a model loaded elsewhere (e.g. by the viewer).
    func record(_ model: ImportedModel, for fileName: String, settings: AppSettings) {
        guard let item = item(named: fileName) else { return }
        var meta = item.metadata ?? ModelMetadata()
        update(&meta, with: model)
        if meta.thumbnail == nil || meta.thumbnail?.points.isEmpty == true {
            meta.thumbnail = StippleThumbnail.make(from: model.mesh)
        }
        meta.error = nil
        meta.analyzedUnitless = settings.unitlessUnit
        saveMetadata(meta, for: fileName)
        refresh()
    }

    private func update(_ meta: inout ModelMetadata, with model: ImportedModel) {
        let size = model.mesh.bounds().size
        meta.vertices = model.mesh.vertexCount
        meta.triangles = model.mesh.triangleCount
        meta.isPointCloud = model.mesh.isPointCloud
        meta.size = [size.x, size.y, size.z]
        meta.sourceUnit = model.sourceUnit
        meta.unitIsDeclared = model.unitIsDeclared
    }

    /// Re-analyses files whose stored measurements depend on a changed default unit.
    func reanalyzeStale(settings: AppSettings) async {
        for item in items where item.metadata == nil
            || (item.metadata?.unitIsDeclared == false && item.metadata?.unitOverride == nil
                && item.metadata?.analyzedUnitless != settings.unitlessUnit) {
            await analyze(item.fileName, settings: settings)
        }
    }

    func setOverrides(for fileName: String, unit: LengthUnit?, upAxis: UpAxis?) {
        guard let item = item(named: fileName) else { return }
        var meta = item.metadata ?? ModelMetadata()
        meta.unitOverride = unit
        meta.upAxisOverride = upAxis
        saveMetadata(meta, for: fileName)
        refresh()
    }

    // MARK: Mutation

    func delete(_ item: LibraryItem) {
        try? fm.removeItem(at: item.url)
        try? fm.removeItem(at: metadataURL(item.fileName))
        refresh()
    }

    func rename(_ item: LibraryItem, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty else { return false }
        let target = modelsDirectory.appendingPathComponent(trimmed).appendingPathExtension(item.url.pathExtension)
        guard !fm.fileExists(atPath: target.path) else { return false }
        do {
            try fm.moveItem(at: item.url, to: target)
            if fm.fileExists(atPath: metadataURL(item.fileName).path) {
                try? fm.moveItem(at: metadataURL(item.fileName), to: metadataURL(target.lastPathComponent))
            }
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Metadata persistence

    private func metadataURL(_ fileName: String) -> URL {
        metadataDirectory.appendingPathComponent(fileName + ".json")
    }

    private func loadMetadata(_ fileName: String) -> ModelMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(fileName)) else { return nil }
        return try? JSONDecoder().decode(ModelMetadata.self, from: data)
    }

    private func saveMetadata(_ meta: ModelMetadata, for fileName: String) {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metadataURL(fileName), options: .atomic)
        }
    }

    // MARK: Export

    /// Converts a library item and writes it into Documents/Exports.
    func convert(_ item: LibraryItem, to format: ExportFormat, settings: AppSettings) async throws -> URL {
        let options = options(for: item, settings: settings)
        let unitless = settings.unitlessUnit
        let destination = exportURL(baseName: item.displayName, format: format)
        let url = item.url
        try await Task.detached(priority: .userInitiated) {
            let model = try ModelLoader.load(url, options: options)
            try ModelExporter.export(model.mesh, format: format, to: destination, unitless: unitless, name: (url.lastPathComponent as NSString).deletingPathExtension)
        }.value
        return destination
    }

    func exportURL(baseName: String, format: ExportFormat) -> URL {
        var candidate = exportsDirectory.appendingPathComponent(baseName).appendingPathExtension(format.fileExtension)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = exportsDirectory.appendingPathComponent("\(baseName) \(n)").appendingPathExtension(format.fileExtension)
            n += 1
        }
        return candidate
    }
}
