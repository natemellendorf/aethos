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
