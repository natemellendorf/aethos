import Foundation
import Testing
@testable import AethosCore

@Test
func canonicalCBORMapKeyOrderingIsLengthFirstThenLexicographic() throws {
    // Key encodings:
    // - .unsigned(1) encodes to 0x01 (length 1)
    // - .unsigned(24) encodes to 0x18 0x18 (length 2)
    // Lexicographically, 0x18 < 0x01 would put 24 before 1 if you sort only by bytes.
    // Deterministic ordering requires length-first, so 1 must come before 24.
    let v: CanonicalCBORValue = .map([
        .init(key: .unsigned(24), value: .null),
        .init(key: .unsigned(1), value: .null),
    ])

    let bytes = try CanonicalCBOREncoder().encode(v)
    let decoded = try CanonicalCBORDecoder().decode(bytes)

    // The encoder must canonicalize insertion order.
    guard case .map(let entries) = decoded else { Issue.record("expected map"); return }
    guard entries.count == 2 else { Issue.record("expected 2 entries"); return }
    #expect(entries[0].key == .unsigned(1))
    #expect(entries[1].key == .unsigned(24))

    // And a non-canonically ordered encoding must be rejected.
    let nonCanonical: Data = Data([0xA2, 0x18, 0x18, 0xF6, 0x01, 0xF6])
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
