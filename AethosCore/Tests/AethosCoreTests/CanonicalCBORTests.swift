import Foundation
import Testing
@testable import AethosCore

@Test
func canonicalCBORMapKeyOrderingIsLexicographicOnDeterministicEncodedKeyBytes() throws {
    // Key encodings:
    // - .bool(false) encodes to 0xF4 (length 1)
    // - .unsigned(24) encodes to 0x18 0x18 (length 2)
    // Lexicographically, 0x18 < 0xF4, so 24 must come before false.
    let v: CanonicalCBORValue = .map([
        .init(key: .bool(false), value: .null),
        .init(key: .unsigned(24), value: .null),
    ])

    let bytes = try CanonicalCBOREncoder().encode(v)
    let decoded = try CanonicalCBORDecoder().decode(bytes)

    // The encoder must canonicalize insertion order.
    guard case .map(let entries) = decoded else { Issue.record("expected map"); return }
    guard entries.count == 2 else { Issue.record("expected 2 entries"); return }
    #expect(entries[0].key == .unsigned(24))
    #expect(entries[1].key == .bool(false))

    // And a non-canonically ordered encoding must be rejected.
    // Non-canonical: key false (0xF4) appears before key 24 (0x18 0x18).
    let nonCanonical: Data = Data([0xA2, 0xF4, 0xF6, 0x18, 0x18, 0xF6])
    #expect(throws: CanonicalCBORDecoder.Error.nonCanonicalMapKeyOrder) {
        _ = try CanonicalCBORDecoder().decode(nonCanonical)
    }
}

@Test
func canonicalCBOREncoderRejectsDuplicateMapKeys() throws {
    let v: CanonicalCBORValue = .map([
        .init(key: .text("x"), value: .unsigned(1)),
        .init(key: .text("x"), value: .unsigned(2)),
    ])

    #expect(throws: CanonicalCBOR.Error.duplicateMapKey) {
        _ = try CanonicalCBOREncoder().encode(v)
    }
}

@Test
func canonicalCBORDecoderLengthTooLargeDoesNotCrash() throws {
    // Byte string, additional info = 27 (uint64 length), length = UInt64.max.
    // No body bytes provided.
    let bytes = Data([0x5B] + Array(repeating: 0xFF, count: 8))
    #expect(throws: CanonicalCBORDecoder.Error.lengthTooLarge) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsDeepNesting() throws {
    // Build 65 nested arrays: [[[[...]]]]
    var bytes = Data()
    for _ in 0..<65 { bytes.append(0x81) } // array(1)
    bytes.append(0xF6) // null at leaf

    var decoder = CanonicalCBORDecoder()
    decoder.maxDepth = 64
    #expect(throws: CanonicalCBORDecoder.Error.nestingTooDeep) {
        _ = try decoder.decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsInvalidAdditionalInfo() throws {
    // Major 0, additional info 28 is invalid.
    let bytes = Data([0x1C])
    #expect(throws: CanonicalCBORDecoder.Error.invalidAdditionalInfo(28)) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORSimple24ReportsActualSimpleValueRead() throws {
    // 0xF8 0x2A encodes a simple value 42.
    let bytes = Data([0xF8, 0x2A])
    #expect(throws: CanonicalCBORDecoder.Error.unsupportedSimpleValue(0x2A)) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsNonCanonicalUnsignedIntegerEncoding() throws {
    // Integer 1 must be encoded as single byte 0x01, not 0x18 0x01.
    let bytes = Data([0x18, 0x01])
    #expect(throws: CanonicalCBORDecoder.Error.nonCanonicalIntegerEncoding) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsNonCanonicalLengthEncoding() throws {
    // Byte string length 1 must be encoded as 0x41, not 0x58 0x01.
    let bytes = Data([0x58, 0x01, 0x00])
    #expect(throws: CanonicalCBORDecoder.Error.nonCanonicalLengthEncoding) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsFloats() throws {
    // Half-precision float 0.0
    let bytes = Data([0xF9, 0x00, 0x00])
    #expect(throws: CanonicalCBORDecoder.Error.floatsNotSupported) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsIndefiniteLengthArray() throws {
    let bytes = Data([0x9F])
    #expect(throws: CanonicalCBORDecoder.Error.indefiniteLengthNotSupported) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsIndefiniteLengthMap() throws {
    let bytes = Data([0xBF])
    #expect(throws: CanonicalCBORDecoder.Error.indefiniteLengthNotSupported) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsIndefiniteLengthTextString() throws {
    let bytes = Data([0x7F])
    #expect(throws: CanonicalCBORDecoder.Error.indefiniteLengthNotSupported) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsIndefiniteLengthByteString() throws {
    let bytes = Data([0x5F])
    #expect(throws: CanonicalCBORDecoder.Error.indefiniteLengthNotSupported) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderRejectsDuplicateMapKeys() throws {
    // map(2) {"x": null, "x": null}
    let bytes = Data([0xA2, 0x61, 0x78, 0xF6, 0x61, 0x78, 0xF6])
    #expect(throws: CanonicalCBORDecoder.Error.duplicateMapKey) {
        _ = try CanonicalCBORDecoder().decode(bytes)
    }
}

@Test
func canonicalCBORDecoderMapKeyOrderingIsLexicographicWhenSameLength() throws {
    // Both keys are one-byte encodings; ordering must be lexicographic.
    // Non-canonical: key 2 (0x02) appears before key 1 (0x01).
    let nonCanonical = Data([0xA2, 0x02, 0xF6, 0x01, 0xF6])
    #expect(throws: CanonicalCBORDecoder.Error.nonCanonicalMapKeyOrder) {
        _ = try CanonicalCBORDecoder().decode(nonCanonical)
    }

    let canonical = Data([0xA2, 0x01, 0xF6, 0x02, 0xF6])
    let decoded = try CanonicalCBORDecoder().decode(canonical)
    guard case .map(let entries) = decoded else { Issue.record("expected map"); return }
    #expect(entries.map(\.key) == [.unsigned(1), .unsigned(2)])
}
