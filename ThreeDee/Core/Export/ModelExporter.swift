//
//  ModelExporter.swift
//  ThreeDee
//
//  Writers for every export target. Input meshes are canonical (millimetres,
//  Z up); each writer converts to its format's unit and axis conventions.
//

import Foundation
import ModelIO
import simd

nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case stlBinary, stlASCII, plyBinary, plyASCII, obj, off, glb, usdz, step

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stlBinary: "STL"
        case .stlASCII: "STL ASCII"
        case .plyBinary: "PLY"
        case .plyASCII: "PLY ASCII"
        case .obj: "OBJ"
        case .off: "OFF"
        case .glb: "GLB"
        case .usdz: "USDZ"
        case .step: "STEP"
        }
    }

    var detail: String {
        switch self {
        case .stlBinary: "Binary · 3D printing"
        case .stlASCII: "Text · universal"
        case .plyBinary: "Binary · colours, points"
        case .plyASCII: "Text · colours, points"
        case .obj: "Wavefront · normals, colours"
        case .off: "Object file format"
        case .glb: "glTF 2.0 · web & realtime"
        case .usdz: "Apple AR Quick Look"
        case .step: "AP214 faceted B-rep · CAD"
        }
    }

    var fileExtension: String {
        switch self {
        case .stlBinary, .stlASCII: "stl"
        case .plyBinary, .plyASCII: "ply"
        case .obj: "obj"
        case .off: "off"
        case .glb: "glb"
        case .usdz: "usdz"
        case .step: "stp"
        }
    }

    var supportsPointClouds: Bool {
        switch self {
        case .plyBinary, .plyASCII, .obj, .off, .glb: true
        case .stlBinary, .stlASCII, .usdz, .step: false
        }
    }

    var preservesColors: Bool {
        switch self {
        case .plyBinary, .plyASCII, .obj, .off, .glb: true
        default: false
        }
    }

    /// Unit written to the file, given the user's choice for unitless formats.
    func unit(unitless: LengthUnit) -> LengthUnit {
        switch self {
        case .glb: .meter
        case .usdz: .centimeter
        case .step: .millimeter
        default: unitless
        }
    }

    var upAxis: UpAxis {
        switch self {
        case .obj, .glb, .usdz: .y
        default: .z
        }
    }
}

nonisolated enum ExportError: LocalizedError {
    case pointCloudUnsupported(String)
    case empty
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .pointCloudUnsupported(let f): "\(f) cannot store point clouds. Choose PLY, OBJ, OFF or GLB."
        case .empty: "There is no geometry to export."
        case .writeFailed(let d): "Export failed: \(d)"
        }
    }
}

nonisolated enum ModelExporter {
    /// Writes `mesh` (millimetres, Z up) to `url` in `format`.
    static func export(_ mesh: Mesh, format: ExportFormat, to url: URL, unitless: LengthUnit, name: String) throws {
        guard !mesh.isEmpty else { throw ExportError.empty }
        if mesh.isPointCloud && !format.supportsPointClouds { throw ExportError.pointCloudUnsupported(format.title) }
        let unit = format.unit(unitless: unitless)
        let s = Float(1 / unit.millimeters)
        var m = mesh
        m.sanitize()
        m.apply(format.upAxis.fromZUp * simd_float4x4(diagonal: SIMD4(s, s, s, 1)))

        let data: Data
        switch format {
        case .stlBinary: data = stlBinary(m, name: name)
        case .stlASCII: data = stlASCII(m, name: name)
        case .plyBinary: data = ply(m, binary: true, unit: unit)
        case .plyASCII: data = ply(m, binary: false, unit: unit)
        case .obj: data = obj(m, name: name, unit: unit)
        case .off: data = off(m)
        case .glb: data = try glb(m, name: name)
        case .usdz: data = try usdz(m, name: name)
        case .step: data = step(m, name: name)
        }
        do { try data.write(to: url, options: .atomic) } catch { throw ExportError.writeFailed(error.localizedDescription) }
    }

    // MARK: Helpers

    private static func faceNormal(_ m: Mesh, _ t: Int) -> SIMD3<Float> {
        let a = m.positions[Int(m.indices[t * 3])], b = m.positions[Int(m.indices[t * 3 + 1])], c = m.positions[Int(m.indices[t * 3 + 2])]
        let n = simd_cross(b - a, c - a)
        let l = simd_length(n)
        return l > 0 ? n / l : .zero
    }

    @inline(__always) private static func append<T>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private static func fmt(_ v: Float) -> String {
        if v == 0 { return "0" }
        return String(format: "%.7g", v)
    }

    // MARK: STL

    private static func stlBinary(_ m: Mesh, name: String) -> Data {
        var data = Data(capacity: 84 + m.triangleCount * 50)
        var header = Array("ThreeDee export · \(name)".utf8.prefix(80))
        header += [UInt8](repeating: 32, count: 80 - header.count)
        data.append(contentsOf: header)
        append(UInt32(m.triangleCount).littleEndian, to: &data)
        for t in 0..<m.triangleCount {
            let n = faceNormal(m, t)
            for f in [n.x, n.y, n.z] { append(f.bitPattern.littleEndian, to: &data) }
            for k in 0..<3 {
                let p = m.positions[Int(m.indices[t * 3 + k])]
                for f in [p.x, p.y, p.z] { append(f.bitPattern.littleEndian, to: &data) }
            }
            append(UInt16(0), to: &data)
        }
        return data
    }

    private static func stlASCII(_ m: Mesh, name: String) -> Data {
        let solid = name.replacingOccurrences(of: " ", with: "_")
        var out = "solid \(solid)\n"
        out.reserveCapacity(m.triangleCount * 260)
        for t in 0..<m.triangleCount {
            let n = faceNormal(m, t)
            out += "  facet normal \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))\n    outer loop\n"
            for k in 0..<3 {
                let p = m.positions[Int(m.indices[t * 3 + k])]
                out += "      vertex \(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))\n"
            }
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid \(solid)\n"
        return Data(out.utf8)
    }

    // MARK: PLY

    private static func ply(_ m: Mesh, binary: Bool, unit: LengthUnit) -> Data {
        var header = "ply\nformat \(binary ? "binary_little_endian" : "ascii") 1.0\n"
        header += "comment ThreeDee export, units: \(unit.symbol)\n"
        header += "element vertex \(m.vertexCount)\nproperty float x\nproperty float y\nproperty float z\n"
        if m.hasNormals { header += "property float nx\nproperty float ny\nproperty float nz\n" }
        if m.hasColors { header += "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\n" }
        if !m.isPointCloud { header += "element face \(m.triangleCount)\nproperty list uchar int vertex_indices\n" }
        header += "end_header\n"
        var data = Data(header.utf8)
        if binary {
            data.reserveCapacity(data.count + m.vertexCount * 28 + m.triangleCount * 13)
            for i in 0..<m.vertexCount {
                let p = m.positions[i]
                for f in [p.x, p.y, p.z] { append(f.bitPattern.littleEndian, to: &data) }
                if m.hasNormals { let n = m.normals[i]; for f in [n.x, n.y, n.z] { append(f.bitPattern.littleEndian, to: &data) } }
                if m.hasColors { let c = m.colors[i]; data.append(contentsOf: [c.r, c.g, c.b, c.a]) }
            }
            for t in 0..<m.triangleCount {
                data.append(3)
                for k in 0..<3 { append(Int32(m.indices[t * 3 + k]).littleEndian, to: &data) }
            }
        } else {
            var out = ""
            out.reserveCapacity(m.vertexCount * 40 + m.triangleCount * 20)
            for i in 0..<m.vertexCount {
                let p = m.positions[i]
                out += "\(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))"
                if m.hasNormals { let n = m.normals[i]; out += " \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))" }
                if m.hasColors { let c = m.colors[i]; out += " \(c.r) \(c.g) \(c.b) \(c.a)" }
                out += "\n"
            }
            for t in 0..<m.triangleCount {
                out += "3 \(m.indices[t * 3]) \(m.indices[t * 3 + 1]) \(m.indices[t * 3 + 2])\n"
            }
            data.append(contentsOf: out.utf8)
        }
        return data
    }

    // MARK: OBJ / OFF

    private static func obj(_ m: Mesh, name: String, unit: LengthUnit) -> Data {
        var out = "# ThreeDee export · units: \(unit.symbol) · Y up\no \(name.replacingOccurrences(of: " ", with: "_"))\n"
        out.reserveCapacity(m.vertexCount * 60 + m.triangleCount * 30)
        for i in 0..<m.vertexCount {
            let p = m.positions[i]
            out += "v \(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))"
            if m.hasColors {
                let c = m.colors[i]
                out += String(format: " %.4f %.4f %.4f", Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255)
            }
            out += "\n"
        }
        if m.hasNormals && !m.isPointCloud {
            for n in m.normals { out += "vn \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))\n" }
        }
        for t in 0..<m.triangleCount {
            let a = m.indices[t * 3] + 1, b = m.indices[t * 3 + 1] + 1, c = m.indices[t * 3 + 2] + 1
            out += m.hasNormals ? "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n" : "f \(a) \(b) \(c)\n"
        }
        return Data(out.utf8)
    }

    private static func off(_ m: Mesh) -> Data {
        var out = m.hasColors ? "COFF\n" : "OFF\n"
        out += "\(m.vertexCount) \(m.triangleCount) 0\n"
        for i in 0..<m.vertexCount {
            let p = m.positions[i]
            out += "\(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))"
            if m.hasColors { let c = m.colors[i]; out += " \(c.r) \(c.g) \(c.b) \(c.a)" }
            out += "\n"
        }
        for t in 0..<m.triangleCount {
            out += "3 \(m.indices[t * 3]) \(m.indices[t * 3 + 1]) \(m.indices[t * 3 + 2])\n"
        }
        return Data(out.utf8)
    }

    // MARK: GLB

    private static func glb(_ m: Mesh, name: String) throws -> Data {
        var bin = Data()
        var views: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var attributes: [String: Int] = [:]

        func addView(_ bytes: Data, target: Int?) -> Int {
            while bin.count % 4 != 0 { bin.append(0) }
            var view: [String: Any] = ["buffer": 0, "byteOffset": bin.count, "byteLength": bytes.count]
            if let target { view["target"] = target }
            bin.append(bytes)
            views.append(view)
            return views.count - 1
        }

        var pos = Data(capacity: m.vertexCount * 12)
        let box = m.bounds()
        for p in m.positions { for f in [p.x, p.y, p.z] { append(f.bitPattern.littleEndian, to: &pos) } }
        accessors.append(["bufferView": addView(pos, target: 34962), "componentType": 5126, "count": m.vertexCount, "type": "VEC3",
                          "min": [box.min.x, box.min.y, box.min.z], "max": [box.max.x, box.max.y, box.max.z]])
        attributes["POSITION"] = accessors.count - 1

        if m.hasNormals && !m.isPointCloud {
            var nrm = Data(capacity: m.vertexCount * 12)
            for n in m.normals {
                let l = simd_length(n)
                let u = l > 0 ? n / l : SIMD3<Float>(0, 0, 1)
                for f in [u.x, u.y, u.z] { append(f.bitPattern.littleEndian, to: &nrm) }
            }
            accessors.append(["bufferView": addView(nrm, target: 34962), "componentType": 5126, "count": m.vertexCount, "type": "VEC3"])
            attributes["NORMAL"] = accessors.count - 1
        }
        if m.hasColors {
            var col = Data(capacity: m.vertexCount * 4)
            for c in m.colors { col.append(contentsOf: [c.r, c.g, c.b, c.a]) }
            accessors.append(["bufferView": addView(col, target: 34962), "componentType": 5121, "normalized": true,
                              "count": m.vertexCount, "type": "VEC4"])
            attributes["COLOR_0"] = accessors.count - 1
        }
        var primitive: [String: Any] = ["attributes": attributes, "mode": m.isPointCloud ? 0 : 4, "material": 0]
        if !m.isPointCloud {
            var idx = Data(capacity: m.indices.count * 4)
            for i in m.indices { append(i.littleEndian, to: &idx) }
            accessors.append(["bufferView": addView(idx, target: 34963), "componentType": 5125, "count": m.indices.count, "type": "SCALAR"])
            primitive["indices"] = accessors.count - 1
        }
        while bin.count % 4 != 0 { bin.append(0) }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "ThreeDee"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": name]],
            "meshes": [["primitives": [primitive], "name": name]],
            "materials": [["pbrMetallicRoughness": ["baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 0.6],
                           "name": "ThreeDee"]],
            "accessors": accessors,
            "bufferViews": views,
            "buffers": [["byteLength": bin.count]],
        ]
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var out = Data()
        append(UInt32(0x4654_6C67).littleEndian, to: &out) // "glTF"
        append(UInt32(2).littleEndian, to: &out)
        append(UInt32(12 + 8 + jsonData.count + 8 + bin.count).littleEndian, to: &out)
        append(UInt32(jsonData.count).littleEndian, to: &out)
        append(UInt32(0x4E4F_534A).littleEndian, to: &out) // JSON
        out.append(jsonData)
        append(UInt32(bin.count).littleEndian, to: &out)
        append(UInt32(0x004E_4942).littleEndian, to: &out) // BIN
        out.append(bin)
        return out
    }

    // MARK: USDZ

    private static func usdz(_ m: Mesh, name: String) throws -> Data {
        let allocator = MDLMeshBufferDataAllocator()
        let source = m.hasNormals ? m : MeshProcessing.withCreaseNormals(m)
        var positionBytes = Data(capacity: source.vertexCount * 12)
        var normalBytes = Data(capacity: source.vertexCount * 12)
        for i in 0..<source.vertexCount {
            let p = source.positions[i], n = source.normals[i]
            for f in [p.x, p.y, p.z] { append(f, to: &positionBytes) }
            for f in [n.x, n.y, n.z] { append(f, to: &normalBytes) }
        }
        var indexBytes = Data(capacity: source.indices.count * 4)
        for i in source.indices { append(i, to: &indexBytes) }

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 0, bufferIndex: 1)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
        descriptor.layouts[1] = MDLVertexBufferLayout(stride: 12)
        let vb0 = allocator.newBuffer(with: positionBytes, type: .vertex)
        let vb1 = allocator.newBuffer(with: normalBytes, type: .vertex)
        let ib = allocator.newBuffer(with: indexBytes, type: .index)
        let material = MDLMaterial(name: "ThreeDee", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: SIMD3(0.92, 0.93, 0.96)))
        material.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, float: 0.55))
        let submesh = MDLSubmesh(indexBuffer: ib, indexCount: source.indices.count, indexType: .uInt32,
                                 geometryType: .triangles, material: material)
        let safeName = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let mdlMesh = MDLMesh(vertexBuffers: [vb0, vb1], vertexCount: source.vertexCount, descriptor: descriptor, submeshes: [submesh])
        mdlMesh.name = String(safeName.isEmpty ? Array("model") : safeName)
        let asset = MDLAsset(bufferAllocator: allocator)
        asset.add(mdlMesh)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let usdc = dir.appendingPathComponent("model.usdc")
        do { try asset.export(to: usdc) } catch { throw ExportError.writeFailed(error.localizedDescription) }
        let layer = try Data(contentsOf: usdc)
        return StoredZip.archive([("model.usdc", layer)], alignment: 64)
    }

    // MARK: STEP

    private static func stepReal(_ v: Double) -> String {
        if v == 0 { return "0." }
        var s = String(format: "%.10G", v)
        if let e = s.firstIndex(of: "E") {
            if !s[..<e].contains(".") { s.insert(".", at: e) }
        } else if !s.contains(".") {
            s += "."
        }
        return s
    }

    private static func stepString(_ s: String) -> String {
        s.unicodeScalars.map { $0.isASCII && $0 != "'" && $0 != "\\" ? String($0) : "_" }.joined()
    }

    private static func step(_ m: Mesh, name: String) -> Data {
        let label = stepString(name)
        let date = ISO8601DateFormatter().string(from: Date())
        var out = """
        ISO-10303-21;
        HEADER;
        FILE_DESCRIPTION(('ThreeDee faceted export'),'2;1');
        FILE_NAME('\(label).stp','\(date)',(''),(''),'ThreeDee','ThreeDee','');
        FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));
        ENDSEC;
        DATA;
        #1=APPLICATION_CONTEXT('automotive design');
        #2=APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,#1);
        #3=PRODUCT_CONTEXT('',#1,'mechanical');
        #4=PRODUCT('\(label)','\(label)','',(#3));
        #5=PRODUCT_DEFINITION_FORMATION('','',#4);
        #6=PRODUCT_DEFINITION_CONTEXT('part definition',#1,'design');
        #7=PRODUCT_DEFINITION('design','',#5,#6);
        #8=PRODUCT_DEFINITION_SHAPE('','',#7);
        #9=(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.));
        #10=(NAMED_UNIT(*)PLANE_ANGLE_UNIT()SI_UNIT($,.RADIAN.));
        #11=(NAMED_UNIT(*)SI_UNIT($,.STERADIAN.)SOLID_ANGLE_UNIT());
        #12=UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-06),#9,'distance_accuracy_value','confusion accuracy');
        #13=(GEOMETRIC_REPRESENTATION_CONTEXT(3)GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#12))GLOBAL_UNIT_ASSIGNED_CONTEXT((#9,#10,#11))REPRESENTATION_CONTEXT('3D','ThreeDee'));
        #14=CARTESIAN_POINT('',(0.,0.,0.));
        #15=DIRECTION('',(0.,0.,1.));
        #16=DIRECTION('',(1.,0.,0.));
        #17=AXIS2_PLACEMENT_3D('',#14,#15,#16);

        """
        out.reserveCapacity(m.vertexCount * 60 + m.triangleCount * 260)
        var next = 18
        // Shared vertices.
        let weld = PositionWelder.weld(m.positions)
        var pointID = [Int](repeating: 0, count: m.vertexCount)
        for i in 0..<m.vertexCount {
            let c = Int(weld.canonical[i])
            if c != i { pointID[i] = pointID[c]; continue }
            let p = m.positions[i]
            out += "#\(next)=CARTESIAN_POINT('',(\(stepReal(Double(p.x))),\(stepReal(Double(p.y))),\(stepReal(Double(p.z)))));\n"
            pointID[i] = next
            next += 1
        }
        var directionIDs: [SIMD3<Int32>: Int] = [:]
        var faceIDs: [Int] = []
        faceIDs.reserveCapacity(m.triangleCount)
        for t in 0..<m.triangleCount {
            let a = pointID[Int(m.indices[t * 3])], b = pointID[Int(m.indices[t * 3 + 1])], c = pointID[Int(m.indices[t * 3 + 2])]
            guard a != b, b != c, a != c else { continue }
            let n = faceNormal(m, t)
            guard n != .zero else { continue }
            let key = SIMD3<Int32>(Int32((n.x * 1e6).rounded()), Int32((n.y * 1e6).rounded()), Int32((n.z * 1e6).rounded()))
            let dir: Int
            if let d = directionIDs[key] { dir = d } else {
                dir = next; next += 1
                directionIDs[key] = dir
                out += "#\(dir)=DIRECTION('',(\(stepReal(Double(n.x))),\(stepReal(Double(n.y))),\(stepReal(Double(n.z)))));\n"
            }
            let axis = next, plane = next + 1, loop = next + 2, bound = next + 3, face = next + 4
            next += 5
            out += "#\(axis)=AXIS2_PLACEMENT_3D('',#\(a),#\(dir),$);\n#\(plane)=PLANE('',#\(axis));\n"
            out += "#\(loop)=POLY_LOOP('',(#\(a),#\(b),#\(c)));\n#\(bound)=FACE_OUTER_BOUND('',#\(loop),.T.);\n"
            out += "#\(face)=FACE_SURFACE('',(#\(bound)),#\(plane),.T.);\n"
            faceIDs.append(face)
        }
        let closed = MeshStatistics.compute(m).isClosed
        let shell = next, solid = next + 1, rep = next + 2, sdr = next + 3
        let faceList = faceIDs.map { "#\($0)" }.joined(separator: ",")
        if closed {
            out += "#\(shell)=CLOSED_SHELL('',(\(faceList)));\n#\(solid)=FACETED_BREP('\(label)',#\(shell));\n"
            out += "#\(rep)=FACETED_BREP_SHAPE_REPRESENTATION('\(label)',(#17,#\(solid)),#13);\n"
        } else {
            out += "#\(shell)=OPEN_SHELL('',(\(faceList)));\n#\(solid)=SHELL_BASED_SURFACE_MODEL('\(label)',(#\(shell)));\n"
            out += "#\(rep)=MANIFOLD_SURFACE_SHAPE_REPRESENTATION('\(label)',(#17,#\(solid)),#13);\n"
        }
        out += "#\(sdr)=SHAPE_DEFINITION_REPRESENTATION(#8,#\(rep));\nENDSEC;\nEND-ISO-10303-21;\n"
        return Data(out.utf8)
    }
}

/// Minimal "stored" (uncompressed) ZIP writer with data alignment, as required by USDZ.
nonisolated enum StoredZip {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for b in raw { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func archive(_ files: [(name: String, data: Data)], alignment: Int) -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: UInt16, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            let offset = out.count
            // Pad with an extra field so the file data starts on an aligned boundary.
            let afterName = offset + 30 + name.count
            let pad = (alignment - (afterName + 4) % alignment) % alignment
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(file.data.count), &out); u32(UInt32(file.data.count), &out)
            u16(UInt16(name.count), &out); u16(UInt16(4 + pad), &out)
            out.append(name)
            u16(0x1986, &out); u16(UInt16(pad), &out); out.append(Data(count: pad))
            out.append(file.data)

            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0x21, &central)
            u32(crc, &central); u32(UInt32(file.data.count), &central); u32(UInt32(file.data.count), &central)
            u16(UInt16(name.count), &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(UInt32(offset), &central)
            central.append(name)
        }
        let cdOffset = out.count
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out)
        u16(UInt16(files.count), &out); u16(UInt16(files.count), &out)
        u32(UInt32(central.count), &out); u32(UInt32(cdOffset), &out); u16(0, &out)
        return out
    }
}
