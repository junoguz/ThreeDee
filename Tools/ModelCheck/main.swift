//
//  ModelCheck — command-line regression check for ThreeDee's format core.
//
//  Imports each file, prints what was read, then exports it to every format,
//  re-imports the result and compares bounding boxes. Exits non-zero on any
//  failure. Build & run with Tools/modelcheck.sh.
//

import Foundation
import simd

var failures = 0
let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("modelcheck-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: outDir) }

let files = CommandLine.arguments.dropFirst()
if files.isEmpty {
    print("usage: modelcheck.sh <model files…>")
    exit(2)
}

for path in files {
    let url = URL(fileURLWithPath: path)
    let start = Date()
    let model: ImportedModel
    do {
        model = try ModelLoader.load(url, options: ImportOptions())
    } catch {
        print("✗ \(url.lastPathComponent): import failed — \(error.localizedDescription)")
        failures += 1
        continue
    }
    let prepared = PreparedMesh.prepare(model.mesh)
    let box = prepared.bounds
    let kind = model.mesh.isPointCloud ? "\(model.mesh.vertexCount) points" : "\(model.mesh.triangleCount) triangles"
    print(String(format: "✓ %@ [%@] %@, %.3f × %.3f × %.3f mm, %@ %@, %@, %.2fs",
                 url.lastPathComponent, model.format.title, kind, box.size.x, box.size.y, box.size.z,
                 model.sourceUnit.symbol, model.unitIsDeclared ? "declared" : "assumed",
                 model.mesh.isPointCloud ? "point cloud" : (prepared.statistics.isClosed ? "watertight" : "\(prepared.statistics.boundaryEdges) open edges"),
                 Date().timeIntervalSince(start)))
    for detail in model.details { print("    \(detail.label): \(detail.value)") }

    for format in ExportFormat.allCases {
        if model.mesh.isPointCloud && !format.supportsPointClouds { continue }
        let destination = outDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(format.rawValue).\(format.fileExtension)")
        do {
            try ModelExporter.export(model.mesh, format: format, to: destination, unitless: .millimeter, name: "check")
            let back = try ModelLoader.load(destination, options: ImportOptions())
            let b = back.mesh.bounds()
            let error = max(simd_length(b.min - box.min), simd_length(b.max - box.max)) / max(box.diagonal, 1e-9)
            let ok = error < 1e-4
            if !ok { failures += 1 }
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let title = format.title.padding(toLength: 10, withPad: " ", startingAt: 0)
            print(String(format: "    %@ %@ %8.1f KB  bbox error %.1e", ok ? "✓" : "✗", title, Double(size) / 1024, error))
        } catch {
            failures += 1
            print("    ✗ \(format.title): \(error.localizedDescription)")
        }
    }
}
exit(failures == 0 ? 0 : 1)
