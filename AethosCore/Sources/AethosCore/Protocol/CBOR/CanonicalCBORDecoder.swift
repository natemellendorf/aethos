import Foundation

/// Strict RFC 8949 deterministic CBOR decoder for Aethos' supported subset.
///
/// Rejects:
/// - floats (major 7 additional info 25-27)
/// - indefinite-length items (additional info 31)
/// - non-canonical integer/length encodings (not shortest form)
/// - duplicate map keys
struct CanonicalCBORDecoder {
    enum Error: Swift.Error, Equatable {
        case truncated
        case trailingBytes
        case unsupportedMajorType(UInt8)
        case unsupportedSimpleValue(UInt8)
        case invalidAdditionalInfo(UInt8)
        case lengthTooLarge
        case collectionTooLarge
        case nestingTooDeep
        case floatsNotSupported
        case indefiniteLengthNotSupported
        case nonCanonicalIntegerEncoding
        case nonCanonicalLengthEncoding
        case invalidUTF8
        case duplicateMapKey
        case nonCanonicalMapKeyOrder
    }

    /// Maximum allowed nesting depth when decoding arrays/maps.
    ///
    /// Depth is counted per container boundary.
    var maxDepth: Int = 64

    func decode(_ data: Data) throws -> CanonicalCBORValue {
        var reader = CBORByteReader(data)
        let value = try decodeItem(from: &reader, depth: 0)
        guard reader.isAtEnd else { throw Error.trailingBytes }
        return value
    }

    private func decodeItem(from reader: inout CBORByteReader, depth: Int) throws -> CanonicalCBORValue {
        if depth >= maxDepth {
            throw Error.nestingTooDeep
        }
        let head = try reader.readHead()
        switch head.majorType {
        case 0:
            let v = try reader.readCanonicalUnsigned(additionalInfo: head.additionalInfo, kind: .integer)
            return .unsigned(v)

        case 1:
            throw Error.unsupportedMajorType(head.majorType) // negative integers unsupported in our subset

        case 2:
            let len = try reader.readCanonicalUnsigned(additionalInfo: head.additionalInfo, kind: .length)
            let byteCount = try safeByteCount(len)
            let bytes = try reader.readBytes(count: byteCount)
            return .bytes(bytes)

        case 3:
            let len = try reader.readCanonicalUnsigned(additionalInfo: head.additionalInfo, kind: .length)
            let byteCount = try safeByteCount(len)
            let bytes = try reader.readBytes(count: byteCount)
            guard let s = String(data: bytes, encoding: .utf8) else { throw Error.invalidUTF8 }
            return .text(s)

        case 4:
            let len = try reader.readCanonicalUnsigned(additionalInfo: head.additionalInfo, kind: .length)
            let itemCount = try safeCollectionCount(len)
            var items: [CanonicalCBORValue] = []
            items.reserveCapacity(itemCount)
            for _ in 0..<itemCount {
                items.append(try decodeItem(from: &reader, depth: depth + 1))
            }
            return .array(items)

        case 5:
            let len = try reader.readCanonicalUnsigned(additionalInfo: head.additionalInfo, kind: .length)
            let pairCount = try safeCollectionCount(len)
            var pairs: [CanonicalCBORValue.MapEntry] = []
            pairs.reserveCapacity(pairCount)

            var seenKeyEncodings = Set<Data>()
            var previousKeyEncoding: Data?

            let encoder = CanonicalCBOREncoder()
            for _ in 0..<pairCount {
                let key = try decodeItem(from: &reader, depth: depth + 1)
                let value = try decodeItem(from: &reader, depth: depth + 1)

                let keyEncoding = try encoder.encode(key)

                if !seenKeyEncodings.insert(keyEncoding).inserted {
                    throw Error.duplicateMapKey
                }

                if let previousKeyEncoding {
                    let cmp = DataLexicographic.compareLengthFirstThenLexicographic(previousKeyEncoding, keyEncoding)
                    if cmp != .orderedAscending {
                        // Equal keys are handled above as duplicates. Descending order is non-canonical.
                        throw Error.nonCanonicalMapKeyOrder
                    }
                }
                previousKeyEncoding = keyEncoding

                pairs.append(.init(key: key, value: value))
            }
            return .map(pairs)

        case 6:
            throw Error.unsupportedMajorType(head.majorType) // tags unsupported

        case 7:
            return try decodeSimple(additionalInfo: head.additionalInfo, from: &reader)

        default:
            throw Error.unsupportedMajorType(head.majorType)
        }
    }

    private func decodeSimple(additionalInfo: UInt8, from reader: inout CBORByteReader) throws -> CanonicalCBORValue {
        switch additionalInfo {
        case 20:
            return .bool(false)
        case 21:
            return .bool(true)
        case 22:
            return .null
        case 23:
            throw Error.unsupportedSimpleValue(additionalInfo) // undefined

        case 24:
            // Simple value in next byte; canonical encoding of bool/null must be single-byte.
            let simple = try reader.readByte()
            throw Error.unsupportedSimpleValue(simple)

        case 25:
            _ = try reader.readBytes(count: 2)
            throw Error.floatsNotSupported
        case 26:
            _ = try reader.readBytes(count: 4)
            throw Error.floatsNotSupported
        case 27:
            _ = try reader.readBytes(count: 8)
            throw Error.floatsNotSupported

        case 28, 29, 30:
            throw Error.invalidAdditionalInfo(additionalInfo)
        case 31:
            throw Error.indefiniteLengthNotSupported
        default:
            // 0..19 and any other simple values are out of subset.
            throw Error.unsupportedSimpleValue(additionalInfo)
        }
    }

    private func safeByteCount(_ length: UInt64) throws -> Int {
        guard length <= UInt64(Int.max) else { throw Error.lengthTooLarge }
        return Int(length)
    }

    private func safeCollectionCount(_ length: UInt64) throws -> Int {
        guard length <= UInt64(Int.max) else { throw Error.collectionTooLarge }
        return Int(length)
    }
}

/// Byte-level CBOR reader utilities.
private struct CBORByteReader {
    struct Head {
        let majorType: UInt8
        let additionalInfo: UInt8
    }

    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readByte() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw CanonicalCBORDecoder.Error.truncated }
        let b = data[offset]
        offset += 1
        return b
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0 else { throw CanonicalCBORDecoder.Error.truncated }
        // Prevent `offset + count` overflow and bounds violations.
        guard count <= data.count - offset else { throw CanonicalCBORDecoder.Error.truncated }
        let end = offset + count
        let slice = data[offset..<end]
        offset += count
        return Data(slice)
    }

    mutating func readHead() throws -> Head {
        let b = try readByte()
        return Head(majorType: b >> 5, additionalInfo: b & 0x1F)
    }

    enum UnsignedKind {
        case integer
        case length
    }

    /// Reads an unsigned integer or length in canonical (shortest) form.
    ///
    /// - Note: Rejects additional info 31 (indefinite-length), and non-shortest encodings.
    mutating func readCanonicalUnsigned(additionalInfo: UInt8, kind: UnsignedKind) throws -> UInt64 {
        if additionalInfo == 31 {
            throw CanonicalCBORDecoder.Error.indefiniteLengthNotSupported
        }
        switch additionalInfo {
        case 0...23:
            return UInt64(additionalInfo)
        case 24:
            let v = UInt64(try readByte())
            // Canonical requires shortest possible encoding.
            if v <= 23 { throw canonicalError(for: kind) }
            return v
        case 25:
            let v = UInt64(try readUInt16BE())
            if v <= UInt64(UInt8.max) { throw canonicalError(for: kind) }
            return v
        case 26:
            let v = UInt64(try readUInt32BE())
            if v <= UInt64(UInt16.max) { throw canonicalError(for: kind) }
            return v
        case 27:
            let v = try readUInt64BE()
            if v <= UInt64(UInt32.max) { throw canonicalError(for: kind) }
            return v
        default:
            throw CanonicalCBORDecoder.Error.invalidAdditionalInfo(additionalInfo)
        }
    }

    private func canonicalError(for kind: UnsignedKind) -> CanonicalCBORDecoder.Error {
        switch kind {
        case .integer:
            return .nonCanonicalIntegerEncoding
        case .length:
            return .nonCanonicalLengthEncoding
        }
    }

    mutating func readUInt16BE() throws -> UInt16 {
        let b = try readBytes(count: 2)
        return (UInt16(b[b.startIndex]) << 8) | UInt16(b[b.startIndex + 1])
    }

    mutating func readUInt32BE() throws -> UInt32 {
        let b = try readBytes(count: 4)
        var v: UInt32 = 0
        for byte in b { v = (v << 8) | UInt32(byte) }
        return v
    }

    mutating func readUInt64BE() throws -> UInt64 {
        let b = try readBytes(count: 8)
        var v: UInt64 = 0
        for byte in b { v = (v << 8) | UInt64(byte) }
        return v
    }
}
