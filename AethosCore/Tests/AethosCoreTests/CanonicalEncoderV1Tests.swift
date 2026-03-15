import Foundation
import Testing
@testable import AethosCore

@Test
func canonicalManifestV1Vector() {
    let chunk1 = Data(repeating: 0x11, count: 32)
    let chunk2 = Data(repeating: 0x22, count: 32)
    let manifest = ManifestV1(totalSize: 100, chunkIds: [chunk1, chunk2])

    let canonical = CanonicalEncoderV1.encode(manifest)
    let canonicalHex = Hex.encode(canonical)
    #expect(canonicalHex == "010201000000080000000000000064020000004c00000002000000201111111111111111111111111111111111111111111111111111111111111111000000202222222222222222222222222222222222222222222222222222222222222222")

    let idHex = Hex.encode(AethosIDs.manifestId(from: manifest))
    #expect(idHex == "840c7dd4578fe07e6445959a8e9791fca2de0774a8600e358c7758a0fde3d1b1")
}

@Test
func canonicalEnvelopeV1Vector() {
    let chunk1 = Data(repeating: 0x11, count: 32)
    let chunk2 = Data(repeating: 0x22, count: 32)
    let manifest = ManifestV1(totalSize: 100, chunkIds: [chunk1, chunk2])
    let manifestId = AethosIDs.manifestId(from: manifest)

    let envelope = EnvelopeV1(
        toWayfarerId: Data(repeating: 0xaa, count: 32),
        manifestId: manifestId,
        body: Data("hi".utf8)
    )

    let canonical = CanonicalEncoderV1.encode(envelope)
    let canonicalHex = Hex.encode(canonical)
    #expect(canonicalHex == "01010100000020aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0200000020840c7dd4578fe07e6445959a8e9791fca2de0774a8600e358c7758a0fde3d1b103000000026869")

    let idHex = Hex.encode(AethosIDs.envelopeId(from: envelope))
    #expect(idHex == "81b5b5086d1a4d3abd6276f6f6c0d8c91fcf85e97b7d148050cd08d4f4ec5c69")
}

@Test
func canonicalReceiptV1Vector() {
    let chunk1 = Data(repeating: 0x11, count: 32)
    let chunk2 = Data(repeating: 0x22, count: 32)
    let manifest = ManifestV1(totalSize: 100, chunkIds: [chunk1, chunk2])
    let manifestId = AethosIDs.manifestId(from: manifest)

    let envelope = EnvelopeV1(
        toWayfarerId: Data(repeating: 0xaa, count: 32),
        manifestId: manifestId,
        body: Data("hi".utf8)
    )
    let envelopeId = AethosIDs.envelopeId(from: envelope)

    let receipt = ReceiptV1(
        envelopeId: envelopeId,
        manifestId: manifestId,
        receivedAtUnixMs: 123_456_789,
        signature: Data(repeating: 0x55, count: 64)
    )

    let canonical = CanonicalEncoderV1.encode(receipt)
    let canonicalHex = Hex.encode(canonical)
    #expect(canonicalHex == "0104010000002081b5b5086d1a4d3abd6276f6f6c0d8c91fcf85e97b7d148050cd08d4f4ec5c690200000020840c7dd4578fe07e6445959a8e9791fca2de0774a8600e358c7758a0fde3d1b1030000000800000000075bcd15040000004055555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555")

    let idHex = Hex.encode(AethosIDs.receiptId(from: receipt))
    #expect(idHex == "04277ea9b89b277a8bddaa03e3400a38bd15676894d3f0f22e86a121d9c0f788")
}

@Test
func canonicalMessageV1Vector() {
    let m = MessageV1(
        createdAtUnixMs: 123_456_789,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("hi".utf8)
    )
    let canonical = CanonicalEncoderV1.encode(m)
    let canonicalHex = Hex.encode(canonical)
    #expect(canonicalHex == "0203010000000800000000075bcd150200000020aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa03000000026869")

    let idHex = Hex.encode(AethosIDs.messageId(from: m))
    #expect(idHex == "0cf6c4cc0b2feb6b3c8b4eaa124b6833846d42a0e444aa5a49a414b1dd04e64b")
}

@Test
func canonicalMessageV2RequiresAuthorField() {
    let canonical = makeMessageCanonical(
        version: 2,
        createdAtUnixMs: 123,
        authorWayfarerId: nil,
        body: Data("hello".utf8),
        extensionMetadata: nil,
        includeUnknownStructuralField: false
    )

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.missingRequiredField(
        CanonicalEncoderV1.MessageField.authorWayfarerId.rawValue
    )) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonical)
    }
}

@Test
func canonicalMessageV2RejectsMalformedAuthorLength() {
    let canonical = makeMessageCanonical(
        version: 2,
        createdAtUnixMs: 123,
        authorWayfarerId: Data(repeating: 0xaa, count: 31),
        body: Data("hello".utf8),
        extensionMetadata: nil,
        includeUnknownStructuralField: false
    )

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.invalidFieldLength(
        fieldId: CanonicalEncoderV1.MessageField.authorWayfarerId.rawValue,
        expected: 32,
        actual: 31
    )) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonical)
    }
}

@Test
func canonicalMessageAuthenticatedBytesIncludeAuthor() {
    let sharedTimestamp: Int64 = 44
    let sharedBody = Data("same-body".utf8)

    let authorA = MessageV1(
        createdAtUnixMs: sharedTimestamp,
        authorWayfarerId: Data(repeating: 0x11, count: 32),
        body: sharedBody
    )
    let authorB = MessageV1(
        createdAtUnixMs: sharedTimestamp,
        authorWayfarerId: Data(repeating: 0x22, count: 32),
        body: sharedBody
    )

    let canonicalA = CanonicalEncoderV1.encode(authorA)
    let canonicalB = CanonicalEncoderV1.encode(authorB)
    #expect(canonicalA != canonicalB)

    let idA = AethosIDs.messageId(canonicalBytes: canonicalA)
    let idB = AethosIDs.messageId(canonicalBytes: canonicalB)
    #expect(idA != idB)
}

@Test
func canonicalMessageV2AllowsUnknownExtensionMetadataKeys() throws {
    let extensionMetadata = try CanonicalCBOREncoder().encode(
        .map([
            .init(key: .text("vendor.example.trace"), value: .text("abc")),
            .init(key: .text("x-extra"), value: .unsigned(7)),
        ])
    )

    let message = MessageV1(
        createdAtUnixMs: 1,
        authorWayfarerId: Data(repeating: 0x55, count: 32),
        body: Data("ok".utf8),
        extensionMetadata: extensionMetadata
    )

    let decoded = try CanonicalEncoderV1.decodeMessage(canonical: CanonicalEncoderV1.encode(message))
    #expect(decoded.extensionMetadata == extensionMetadata)
}

@Test
func canonicalMessageV2RejectsUnknownStructuralField() {
    let canonical = makeMessageCanonical(
        version: 2,
        createdAtUnixMs: 123,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("hello".utf8),
        extensionMetadata: nil,
        includeUnknownStructuralField: true
    )

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.unknownField(0x7f)) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonical)
    }
}

@Test
func canonicalMessageV2RejectsReservedExtensionNamespaces() throws {
    let extensionMetadata = try CanonicalCBOREncoder().encode(
        .map([
            .init(key: .text("aethos.future"), value: .text("x")),
        ])
    )

    let message = MessageV1(
        createdAtUnixMs: 1,
        authorWayfarerId: Data(repeating: 0x44, count: 32),
        body: Data("ok".utf8),
        extensionMetadata: extensionMetadata
    )

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.reservedExtensionMetadataKey("aethos.future")) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: CanonicalEncoderV1.encode(message))
    }
}

@Test
func canonicalMessageV2RejectsSystemReservedExtensionNamespace() throws {
    let extensionMetadata = try CanonicalCBOREncoder().encode(
        .map([
            .init(key: .text("sys.trace"), value: .text("x")),
        ])
    )

    let message = MessageV1(
        createdAtUnixMs: 1,
        authorWayfarerId: Data(repeating: 0x33, count: 32),
        body: Data("ok".utf8),
        extensionMetadata: extensionMetadata
    )

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.reservedExtensionMetadataKey("sys.trace")) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: CanonicalEncoderV1.encode(message))
    }
}

@Test
func canonicalMessageV2RejectsNonMapExtensionMetadata() throws {
    let extensionMetadata = try CanonicalCBOREncoder().encode(.text("not-a-map"))
    let canonical = makeMessageCanonical(
        version: 2,
        createdAtUnixMs: 12,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("hi".utf8),
        extensionMetadata: extensionMetadata,
        includeUnknownStructuralField: false
    )

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.invalidExtensionMetadata) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonical)
    }
}

@Test
func canonicalMessageV2RejectsNonTextExtensionMetadataKey() throws {
    let extensionMetadata = try CanonicalCBOREncoder().encode(
        .map([
            .init(key: .unsigned(1), value: .text("x")),
        ])
    )
    let canonical = makeMessageCanonical(
        version: 2,
        createdAtUnixMs: 12,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("hi".utf8),
        extensionMetadata: extensionMetadata,
        includeUnknownStructuralField: false
    )

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.invalidExtensionMetadata) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonical)
    }
}

@Test
func canonicalMessageV2RejectsDuplicateField() {
    var canonical = makeMessageCanonical(
        version: 2,
        createdAtUnixMs: 123,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("hello".utf8),
        extensionMetadata: nil,
        includeUnknownStructuralField: false
    )
    canonical.appendCanonicalField(id: CanonicalEncoderV1.MessageField.body.rawValue, raw: Data("duplicate".utf8))

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.duplicateField(
        CanonicalEncoderV1.MessageField.body.rawValue
    )) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonical)
    }
}

@Test
func canonicalMessageV2RejectsUnsupportedVersionDeterministically() {
    let canonicalV1 = makeMessageCanonical(
        version: 1,
        createdAtUnixMs: 123,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("hello".utf8),
        extensionMetadata: nil,
        includeUnknownStructuralField: false
    )
    let canonicalFuture = makeMessageCanonical(
        version: 3,
        createdAtUnixMs: 123,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("hello".utf8),
        extensionMetadata: nil,
        includeUnknownStructuralField: false
    )

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.invalidType) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonicalV1)
    }
    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.invalidType) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonicalFuture)
    }
}

@Test
func canonicalObjectTypeAssignmentsAvoidReservedRange() {
    let assigned: [UInt8] = [
        CanonicalEncoderV1.TypeDiscriminator.envelope.rawValue,
        CanonicalEncoderV1.TypeDiscriminator.manifest.rawValue,
        CanonicalEncoderV1.TypeDiscriminator.message.rawValue,
        CanonicalEncoderV1.TypeDiscriminator.receipt.rawValue,
        CanonicalEncoderV1.TypeDiscriminator.inventory.rawValue,
        CanonicalEncoderV1.TypeDiscriminator.inventoryRequest.rawValue,
        CanonicalEncoderV1.TypeDiscriminator.sealedEnvelope.rawValue,
    ]

    #expect(Set(assigned).count == assigned.count)
    for typeID in assigned {
        #expect(CanonicalEncoderV1.TypeDiscriminatorSpace.coreRange.contains(typeID))
        #expect(!CanonicalEncoderV1.TypeDiscriminatorSpace.reservedFutureRange.contains(typeID))
    }
}

private func makeMessageCanonical(
    version: UInt8,
    createdAtUnixMs: Int64,
    authorWayfarerId: Data?,
    body: Data,
    extensionMetadata: Data?,
    includeUnknownStructuralField: Bool
) -> Data {
    var out = Data()
    out.append(version)
    out.append(CanonicalEncoderV1.TypeDiscriminator.message.rawValue)

    var tsRaw = Data()
    var ts = createdAtUnixMs.bigEndian
    Swift.withUnsafeBytes(of: &ts) { tsRaw.append(contentsOf: $0) }
    out.appendCanonicalField(id: CanonicalEncoderV1.MessageField.createdAtUnixMs.rawValue, raw: tsRaw)

    if let authorWayfarerId {
        out.appendCanonicalField(id: CanonicalEncoderV1.MessageField.authorWayfarerId.rawValue, raw: authorWayfarerId)
    }

    out.appendCanonicalField(id: CanonicalEncoderV1.MessageField.body.rawValue, raw: body)

    if let extensionMetadata {
        out.appendCanonicalField(id: CanonicalEncoderV1.MessageField.extensionMetadata.rawValue, raw: extensionMetadata)
    }

    if includeUnknownStructuralField {
        out.appendCanonicalField(id: 0x7f, raw: Data([0x01]))
    }

    return out
}

private extension Data {
    mutating func appendCanonicalField(id: UInt8, raw: Data) {
        append(id)
        var len = UInt32(raw.count).bigEndian
        Swift.withUnsafeBytes(of: &len) { append(contentsOf: $0) }
        append(raw)
    }
}
