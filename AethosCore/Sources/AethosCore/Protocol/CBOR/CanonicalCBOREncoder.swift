import Foundation

/// RFC 8949 deterministic CBOR encoder for Aethos' supported subset.
struct CanonicalCBOREncoder {
    func encode(_ value: CanonicalCBORValue) throws -> Data {
        var out = Data()
        try append(value, into: &out)
        return out
    }

    /// Convenience for call sites that structurally cannot produce duplicate keys.
    ///
    /// Prefer `encode(_:)` in any context where the input is not fully controlled.
    func encodeAssumingNoDuplicateMapKeys(_ value: CanonicalCBORValue) -> Data {
        // We intentionally crash here rather than silently producing bad bytes.
        // Duplicate key rejection is exercised through the throwing API.
        try! encode(value)
    }

    private func append(_ value: CanonicalCBORValue, into out: inout Data) throws {
        switch value {
        case .unsigned(let v):
            appendUnsigned(v, majorType: 0, into: &out)

        case .bytes(let b):
            appendUnsigned(UInt64(b.count), majorType: 2, into: &out)
            out.append(b)

        case .text(let s):
            let utf8 = Data(s.utf8)
            appendUnsigned(UInt64(utf8.count), majorType: 3, into: &out)
            out.append(utf8)

        case .array(let items):
            appendUnsigned(UInt64(items.count), majorType: 4, into: &out)
            for item in items {
                try append(item, into: &out)
            }

        case .map(let pairs):
            // Ensure deterministic output regardless of caller insertion order.
            // Deterministic ordering (RFC 8949): sort by encoded key byte length,
            // then bytewise lexicographic.
            var keyed: [(keyBytes: Data, key: CanonicalCBORValue, value: CanonicalCBORValue)] = []
            keyed.reserveCapacity(pairs.count)
            for entry in pairs {
                // We intentionally encode with the same encoder to ensure
                // key ordering is based on canonical encoding.
                keyed.append((keyBytes: try encode(entry.key), key: entry.key, value: entry.value))
            }

            keyed.sort {
                DataLexicographic.compareLengthFirstThenLexicographic($0.keyBytes, $1.keyBytes) == .orderedAscending
            }

            // Duplicate keys are illegal in canonical CBOR; fail loud.
            // Guard against Swift's runtime trap on invalid empty ranges (e.g. 1..<0).
            if keyed.count >= 2 {
                for i in 1..<keyed.count {
                    if keyed[i - 1].keyBytes == keyed[i].keyBytes {
                        throw CanonicalCBOR.Error.duplicateMapKey
                    }
                }
            }

            appendUnsigned(UInt64(keyed.count), majorType: 5, into: &out)
            for entry in keyed {
                out.append(entry.keyBytes)
                try append(entry.value, into: &out)
            }

        case .bool(false):
            out.append(0xF4)
        case .bool(true):
            out.append(0xF5)
        case .null:
            out.append(0xF6)
        }
    }

    /// Appends an unsigned integer `value` with the provided major type.
    ///
    /// For major type 0 this is the unsigned integer encoding.
    /// For major types 2-5 this is the canonical definite-length encoding.
    private func appendUnsigned(_ value: UInt64, majorType: UInt8, into out: inout Data) {
        precondition(majorType <= 7, "Invalid CBOR major type")
        let major = majorType << 5

        if value <= 23 {
            out.append(major | UInt8(value))
            return
        }
        if value <= UInt64(UInt8.max) {
            out.append(major | 24)
            out.append(UInt8(value))
            return
        }
        if value <= UInt64(UInt16.max) {
            out.append(major | 25)
            out.appendUInt16BE(UInt16(value))
            return
        }
        if value <= UInt64(UInt32.max) {
            out.append(major | 26)
            out.appendUInt32BE(UInt32(value))
            return
        }
        out.append(major | 27)
        out.appendUInt64BE(value)
    }
}

private extension Data {
    mutating func appendUInt16BE(_ v: UInt16) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendUInt32BE(_ v: UInt32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendUInt64BE(_ v: UInt64) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}
