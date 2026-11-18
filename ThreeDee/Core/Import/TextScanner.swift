//
//  TextScanner.swift
//  ThreeDee
//
//  A small, fast cursor over ASCII bytes used by the text-based parsers.
//

import Foundation

nonisolated final class TextScanner {
    private let base: UnsafeMutablePointer<UInt8>
    let count: Int
    var position: Int

    init(data: Data, from offset: Int = 0) {
        count = data.count
        base = .allocate(capacity: count + 1)
        data.copyBytes(to: base, count: count)
        base[count] = 0 // strtod sentinel
        position = min(offset, count)
    }

    init(bytes: [UInt8]) {
        let n = bytes.count
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: n + 1)
        bytes.withUnsafeBufferPointer { src in
            if let s = src.baseAddress { buffer.update(from: s, count: n) }
        }
        buffer[n] = 0
        count = n
        base = buffer
        position = 0
    }

    deinit { base.deallocate() }

    var isAtEnd: Bool { position >= count }

    @inline(__always) func peek() -> UInt8 { position < count ? base[position] : 0 }
    @inline(__always) func byte(at i: Int) -> UInt8 { i < count ? base[i] : 0 }

    @inline(__always) static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12 }

    @inline(__always) func skipWhitespace() {
        while position < count && TextScanner.isSpace(base[position]) { position += 1 }
    }

    /// Skips spaces and tabs but stops at line breaks.
    @inline(__always) func skipInlineSpace() {
        while position < count && (base[position] == 32 || base[position] == 9 || base[position] == 13) { position += 1 }
    }

    func skipLine() {
        while position < count && base[position] != 10 { position += 1 }
        if position < count { position += 1 }
    }

    var atLineEnd: Bool {
        let c = peek()
        return c == 10 || c == 0 || position >= count
    }

    /// Reads a whitespace-delimited token.
    func token() -> String? {
        skipWhitespace()
        guard position < count else { return nil }
        let start = position
        while position < count && !TextScanner.isSpace(base[position]) { position += 1 }
        return String(decoding: UnsafeBufferPointer(start: base + start, count: position - start), as: UTF8.self)
    }

    /// Reads a token without crossing a line break.
    func inlineToken() -> String? {
        skipInlineSpace()
        guard position < count, base[position] != 10 else { return nil }
        let start = position
        while position < count && !TextScanner.isSpace(base[position]) { position += 1 }
        return String(decoding: UnsafeBufferPointer(start: base + start, count: position - start), as: UTF8.self)
    }

    /// Returns the rest of the current line (without the terminator) and advances past it.
    func line() -> String? {
        guard position < count else { return nil }
        let start = position
        while position < count && base[position] != 10 { position += 1 }
        var end = position
        if end > start && base[end - 1] == 13 { end -= 1 }
        if position < count { position += 1 }
        return String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self)
    }

    /// Parses a floating point number after optional whitespace.
    @inline(__always) func double() -> Double? {
        skipWhitespace()
        return parseDoubleHere()
    }

    /// Parses a number without crossing a line break.
    @inline(__always) func inlineDouble() -> Double? {
        skipInlineSpace()
        // strtod would happily skip the newline and read the next line.
        guard position < count, base[position] != 10 else { return nil }
        return parseDoubleHere()
    }

    @inline(__always) private func parseDoubleHere() -> Double? {
        guard position < count else { return nil }
        let start = UnsafeMutablePointer<CChar>(OpaquePointer(base + position))
        var end: UnsafeMutablePointer<CChar>? = nil
        let value = strtod(start, &end)
        guard let end, end != start else { return nil }
        position += start.distance(to: end)
        return value
    }

    @inline(__always) func int() -> Int? {
        skipWhitespace()
        guard position < count else { return nil }
        let start = UnsafeMutablePointer<CChar>(OpaquePointer(base + position))
        var end: UnsafeMutablePointer<CChar>? = nil
        let value = strtoll(start, &end, 10)
        guard let end, end != start else { return nil }
        position += start.distance(to: end)
        return Int(value)
    }

    /// Case-insensitive check for an ASCII keyword at the current position.
    func matches(_ keyword: String) -> Bool {
        var i = position
        for c in keyword.utf8 {
            guard i < count else { return false }
            var b = base[i]
            if b >= 65 && b <= 90 { b += 32 }
            var k = c
            if k >= 65 && k <= 90 { k += 32 }
            if b != k { return false }
            i += 1
        }
        return true
    }

    /// Advances to just after the next occurrence of `keyword` (case-sensitive). Returns false at EOF.
    func advance(past keyword: [UInt8]) -> Bool {
        guard let first = keyword.first else { return true }
        while position < count {
            if base[position] == first && position + keyword.count <= count {
                var ok = true
                for (k, c) in keyword.enumerated() where base[position + k] != c { ok = false; break }
                if ok { position += keyword.count; return true }
            }
            position += 1
        }
        return false
    }
}

nonisolated enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case malformed(String)
    case empty
    case unsupportedFeature(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): "Files of type “\(ext)” are not supported."
        case .malformed(let detail): "The file could not be read: \(detail)"
        case .empty: "The file contains no renderable geometry."
        case .unsupportedFeature(let detail): detail
        }
    }
}
