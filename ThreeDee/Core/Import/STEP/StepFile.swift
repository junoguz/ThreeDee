//
//  StepFile.swift
//  ThreeDee
//
//  Lazy ISO 10303-21 ("STEP physical file") reader. One pass indexes every
//  entity instance; parameters are parsed on demand so large assemblies do
//  not need a full object graph in memory.
//

import Foundation
import simd

nonisolated enum StepValue: Sendable {
    case int(Int)
    case real(Double)
    case string(String)
    case enumeration(String)
    case ref(Int)
    case list([StepValue])
    case typed(String, [StepValue])
    case null
    case derived

    var number: Double? {
        switch self {
        case .int(let i): Double(i)
        case .real(let d): d
        case .typed(_, let a): a.first?.number
        default: nil
        }
    }

    var ref: Int? {
        switch self {
        case .ref(let r): r
        case .typed(_, let a): a.first?.ref
        default: nil
        }
    }

    var list: [StepValue]? { if case .list(let l) = self { l } else { nil } }
    var refs: [Int] { list?.compactMap(\.ref) ?? [] }
    var numbers: [Double] { list?.compactMap(\.number) ?? [] }

    var enumValue: String? { if case .enumeration(let e) = self { e } else { nil } }
    var bool: Bool? {
        switch enumValue {
        case "T": true
        case "F": false
        default: nil
        }
    }
    var string: String? { if case .string(let s) = self { s } else { nil } }
}

nonisolated struct StepEntity: Sendable {
    let id: Int
    let parts: [(name: String, args: [StepValue])]

    var name: String { parts.first?.name ?? "" }
    var args: [StepValue] { parts.first?.args ?? [] }
    var isComplex: Bool { parts.count > 1 }

    func part(_ name: String) -> [StepValue]? { parts.first { $0.name == name }?.args }
    func has(_ name: String) -> Bool { parts.contains { $0.name == name } }

    subscript(_ i: Int) -> StepValue {
        let a = args
        return i < a.count ? a[i] : .null
    }
}

nonisolated final class StepFile {
    struct Record {
        var names: [String]
        var start: Int32 // first byte of the right-hand side
        var end: Int32   // index of the terminating ';'
    }

    private let base: UnsafeMutablePointer<UInt8>
    private let count: Int
    private(set) var records: [Int: Record] = [:]
    private(set) var orderedIDs: [Int] = []
    private(set) var schema: String = ""

    init(data: Data) throws {
        // Line breaks carry no meaning in Part 21 and may even split tokens; drop them.
        let n = data.count
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: n + 1)
        var w = 0
        data.withUnsafeBytes { raw in
            for b in raw where b != 10 && b != 13 {
                buffer[w] = b == 9 ? 32 : b
                w += 1
            }
        }
        buffer[w] = 0
        base = buffer
        count = w
        // Once all stored properties are set, `deinit` releases the buffer on a throw.
        guard w > 13, String(decoding: UnsafeBufferPointer(start: base, count: min(w, 64)), as: UTF8.self).contains("ISO-10303-21") else {
            throw ImportError.malformed("not an ISO 10303-21 file")
        }
        index()
        if records.isEmpty { throw ImportError.empty }
    }

    deinit { base.deallocate() }

    // MARK: Indexing

    @inline(__always) private func isSpace(_ c: UInt8) -> Bool { c == 32 }
    @inline(__always) private func isIdent(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45
    }

    private func skipSpaceAndComments(_ i: inout Int) {
        while i < count {
            let c = base[i]
            if c == 32 { i += 1; continue }
            if c == 47 && i + 1 < count && base[i + 1] == 42 { // /*
                i += 2
                while i + 1 < count && !(base[i] == 42 && base[i + 1] == 47) { i += 1 }
                i += 2
                continue
            }
            break
        }
    }

    /// Advances to the ';' that terminates the current statement.
    private func skipStatement(_ i: inout Int) {
        while i < count {
            let c = base[i]
            if c == 39 { // string
                i += 1
                while i < count {
                    if base[i] == 39 {
                        if i + 1 < count && base[i + 1] == 39 { i += 2; continue }
                        break
                    }
                    i += 1
                }
            } else if c == 47 && i + 1 < count && base[i + 1] == 42 {
                i += 2
                while i + 1 < count && !(base[i] == 42 && base[i + 1] == 47) { i += 1 }
                i += 1
            } else if c == 59 {
                return
            }
            i += 1
        }
    }

    private func readIdent(_ i: inout Int) -> String {
        let start = i
        while i < count && isIdent(base[i]) { i += 1 }
        return String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self).uppercased()
    }

    /// Skips a balanced parenthesised group starting at '('.
    private func skipGroup(_ i: inout Int) {
        var depth = 0
        while i < count {
            let c = base[i]
            if c == 39 {
                i += 1
                while i < count {
                    if base[i] == 39 {
                        if i + 1 < count && base[i + 1] == 39 { i += 2; continue }
                        break
                    }
                    i += 1
                }
            } else if c == 40 {
                depth += 1
            } else if c == 41 {
                depth -= 1
                if depth == 0 { i += 1; return }
            }
            i += 1
        }
    }

    private func index() {
        var i = 0
        // Header: pull out the schema for display.
        if let headerEnd = find("DATA;", from: 0) {
            let header = String(decoding: UnsafeBufferPointer(start: base, count: headerEnd), as: UTF8.self)
            if let r = header.range(of: "FILE_SCHEMA") {
                let tail = header[r.upperBound...]
                if let q1 = tail.firstIndex(of: "'"), let q2 = tail[tail.index(after: q1)...].firstIndex(of: "'") {
                    schema = String(tail[tail.index(after: q1)..<q2])
                }
            }
            i = headerEnd + 5
        }
        records.reserveCapacity(count / 60)
        orderedIDs.reserveCapacity(count / 60)
        while i < count {
            skipSpaceAndComments(&i)
            guard i < count else { break }
            if base[i] == 35 { // '#'
                i += 1
                var id = 0
                while i < count, base[i] >= 48, base[i] <= 57 { id = id * 10 + Int(base[i] - 48); i += 1 }
                skipSpaceAndComments(&i)
                guard i < count, base[i] == 61 else { skipStatement(&i); i += 1; continue } // '='
                i += 1
                skipSpaceAndComments(&i)
                let start = i
                var names: [String] = []
                if i < count && base[i] == 40 { // complex instance
                    var j = i + 1
                    while j < count {
                        skipSpaceAndComments(&j)
                        guard j < count, base[j] != 41 else { break }
                        let name = readIdent(&j)
                        if name.isEmpty { break }
                        names.append(name)
                        skipSpaceAndComments(&j)
                        if j < count && base[j] == 40 { skipGroup(&j) }
                    }
                } else {
                    var j = i
                    names.append(readIdent(&j))
                }
                skipStatement(&i)
                records[id] = Record(names: names, start: Int32(start), end: Int32(i))
                orderedIDs.append(id)
                i += 1
            } else {
                // Keyword statement (ENDSEC; END-ISO-10303-21; …)
                skipStatement(&i)
                i += 1
            }
        }
    }

    private func find(_ needle: String, from: Int) -> Int? {
        let bytes = Array(needle.utf8)
        var i = from
        while i + bytes.count <= count {
            if base[i] == bytes[0] {
                var ok = true
                for k in 1..<bytes.count where base[i + k] != bytes[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: Queries

    func names(of id: Int) -> [String] { records[id]?.names ?? [] }
    func name(of id: Int) -> String { records[id]?.names.first ?? "" }
    func isType(_ id: Int, _ name: String) -> Bool { records[id]?.names.contains(name) ?? false }

    func entity(_ id: Int) -> StepEntity? {
        guard let rec = records[id] else { return nil }
        var i = Int(rec.start)
        var parts: [(String, [StepValue])] = []
        if base[i] == 40 {
            i += 1
            while i < Int(rec.end) {
                skipSpaceAndComments(&i)
                guard i < Int(rec.end), base[i] != 41 else { break }
                let name = readIdent(&i)
                if name.isEmpty { break }
                skipSpaceAndComments(&i)
                var args: [StepValue] = []
                if base[i] == 40 { args = parseList(&i) }
                parts.append((name, args))
            }
        } else {
            let name = readIdent(&i)
            skipSpaceAndComments(&i)
            let args = (i < count && base[i] == 40) ? parseList(&i) : []
            parts.append((name, args))
        }
        return StepEntity(id: id, parts: parts)
    }

    /// Fast path for CARTESIAN_POINT / DIRECTION: the first numeric list of the instance.
    func coordinates(_ id: Int) -> SIMD3<Double>? {
        guard let rec = records[id] else { return nil }
        var i = Int(rec.start)
        let end = Int(rec.end)
        // Skip the name and opening '(' and the label string.
        while i < end && base[i] != 40 { i += 1 }
        i += 1
        skipSpaceAndComments(&i)
        if i < end && base[i] == 39 {
            i += 1
            while i < end {
                if base[i] == 39 {
                    if i + 1 < end && base[i + 1] == 39 { i += 2; continue }
                    break
                }
                i += 1
            }
            i += 1
        }
        while i < end && base[i] != 40 { i += 1 }
        guard i < end else { return nil }
        i += 1
        var v = SIMD3<Double>(0, 0, 0)
        var k = 0
        while k < 3 && i < end {
            skipSpaceAndComments(&i)
            if base[i] == 41 { break }
            if base[i] == 44 { i += 1; continue }
            let p = UnsafeMutablePointer<CChar>(OpaquePointer(base + i))
            var e: UnsafeMutablePointer<CChar>? = nil
            let d = strtod(p, &e)
            guard let e, e != p else { return nil }
            v[k] = d
            k += 1
            i += p.distance(to: e)
        }
        return k >= 2 ? v : nil
    }

    // MARK: Parameter parsing

    private func parseList(_ i: inout Int) -> [StepValue] {
        // assumes base[i] == '('
        i += 1
        var values: [StepValue] = []
        while i < count {
            skipSpaceAndComments(&i)
            guard i < count else { break }
            let c = base[i]
            if c == 41 { i += 1; break }
            if c == 44 { i += 1; continue }
            values.append(parseValue(&i))
        }
        return values
    }

    private func parseValue(_ i: inout Int) -> StepValue {
        let c = base[i]
        switch c {
        case 36: i += 1; return .null       // $
        case 42: i += 1; return .derived    // *
        case 35:                            // #
            i += 1
            var id = 0
            while i < count, base[i] >= 48, base[i] <= 57 { id = id * 10 + Int(base[i] - 48); i += 1 }
            return .ref(id)
        case 39:                            // 'string'
            i += 1
            var bytes: [UInt8] = []
            while i < count {
                if base[i] == 39 {
                    if i + 1 < count && base[i + 1] == 39 { bytes.append(39); i += 2; continue }
                    i += 1
                    break
                }
                bytes.append(base[i])
                i += 1
            }
            return .string(StepFile.decodeString(bytes))
        case 34:                            // "binary"
            i += 1
            let start = i
            while i < count && base[i] != 34 { i += 1 }
            let s = String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self)
            i += 1
            return .string(s)
        case 46:                            // .ENUM.
            i += 1
            let start = i
            while i < count && base[i] != 46 { i += 1 }
            let s = String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self)
            i += 1
            return .enumeration(s.uppercased())
        case 40:
            return .list(parseList(&i))
        default:
            if (c >= 48 && c <= 57) || c == 43 || c == 45 {
                let start = i
                var isReal = false
                while i < count {
                    let d = base[i]
                    if d == 46 || d == 69 || d == 101 { isReal = true }
                    if !((d >= 48 && d <= 57) || d == 43 || d == 45 || d == 46 || d == 69 || d == 101) { break }
                    i += 1
                }
                let p = UnsafeMutablePointer<CChar>(OpaquePointer(base + start))
                if isReal { return .real(strtod(p, nil)) }
                return .int(Int(strtoll(p, nil, 10)))
            }
            if isIdent(c) {
                let name = readIdent(&i)
                skipSpaceAndComments(&i)
                if i < count && base[i] == 40 { return .typed(name, parseList(&i)) }
                return .enumeration(name)
            }
            i += 1
            return .null
        }
    }

    /// Decodes the Part 21 control directives used for non-ASCII text (\X\hh, \X2\…\X0\).
    static func decodeString(_ bytes: [UInt8]) -> String {
        guard bytes.contains(92) else { return String(decoding: bytes, as: UTF8.self) }
        let s = String(decoding: bytes, as: UTF8.self)
        var out = ""
        var it = s.startIndex
        func hex(_ str: Substring) -> UInt32? { UInt32(str, radix: 16) }
        while it < s.endIndex {
            if s[it...].hasPrefix("\\X2\\"), let end = s[it...].range(of: "\\X0\\") {
                let body = s[s.index(it, offsetBy: 4)..<end.lowerBound]
                var j = body.startIndex
                while body.distance(from: j, to: body.endIndex) >= 4 {
                    let k = body.index(j, offsetBy: 4)
                    if let v = hex(body[j..<k]), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                    j = k
                }
                it = end.upperBound
            } else if s[it...].hasPrefix("\\X\\"), s.distance(from: it, to: s.endIndex) >= 5 {
                let h = s[s.index(it, offsetBy: 3)..<s.index(it, offsetBy: 5)]
                if let v = hex(h), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                it = s.index(it, offsetBy: 5)
            } else if s[it...].hasPrefix("\\\\") {
                out.append("\\")
                it = s.index(it, offsetBy: 2)
            } else {
                out.append(s[it])
                it = s.index(after: it)
            }
        }
        return out
    }
}
