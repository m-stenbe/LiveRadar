import Foundation

/// Minimal protobuf-style primitives: base-128 varints and zigzag for signed values.
/// Kept dependency-free so the exercise builds offline; see Proto/live_feed.proto
/// for the equivalent schema a real gRPC service would use.
struct WireWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    mutating func byte(_ v: UInt8) {
        bytes.append(v)
    }

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func zigzag(_ value: Int64) {
        varint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    mutating func string(_ s: String) {
        let utf8 = s.utf8
        varint(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }
}

public enum WireError: Error, Equatable {
    case truncated
    case malformedVarint
    case unsupportedVersion(UInt8)
    case invalidString
}

struct WireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw WireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else { throw WireError.truncated }
            let b = bytes[offset]
            offset += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw WireError.malformedVarint }
        }
    }

    mutating func zigzag() throws -> Int64 {
        let v = try varint()
        return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
    }

    mutating func count() throws -> Int {
        let n = try varint()
        // A count can never exceed the remaining bytes; guards against hostile input.
        guard n <= UInt64(bytes.count - offset) else { throw WireError.truncated }
        return Int(n)
    }

    mutating func string() throws -> String {
        let n = try count()
        defer { offset += n }
        guard let s = String(bytes: bytes[offset..<offset + n], encoding: .utf8) else {
            throw WireError.invalidString
        }
        return s
    }
}
