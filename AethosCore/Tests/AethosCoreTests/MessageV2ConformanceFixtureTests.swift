import Foundation
import Testing
@testable import AethosCore

@Test
func messageV2Fixture_validCanonicalMessage() throws {
    let fixture = try loadMessageFixture("valid")
    let canonical = try fixture.canonicalBytes()
    let decoded = try CanonicalEncoderV1.decodeMessage(canonical: canonical)

    #expect(Hex.encode(decoded.authorWayfarerId) == fixture.expectedAuthorWayfarerId)
}

@Test
func messageV2Fixture_relayPeerDiffersFromCanonicalAuthor() throws {
    let fixture = try loadMessageFixture("relay_peer_not_author")
    let canonical = try fixture.canonicalBytes()
    let decoded = try CanonicalEncoderV1.decodeMessage(canonical: canonical)
    #expect(Hex.encode(decoded.authorWayfarerId) == fixture.expectedAuthorWayfarerId)

    let payloadB64 = WireBase64.encode(canonical)
    let received = ReceivedMessage(
        msgId: "fixture-relay-peer",
        fromHex: fixture.transportPeerHex,
        payloadB64: payloadB64,
        receivedAt: Date(timeIntervalSince1970: 0),
        wireBytes: Data()
    )

    #expect(received != nil)
    #expect(received?.transportPeer.rawValue == fixture.transportPeerHex)
    #expect(received?.canonicalAuthor.rawValue == fixture.expectedAuthorWayfarerId)
}

@Test
func messageV2Fixture_missingAuthorFailsClosed() throws {
    let fixture = try loadMessageFixture("missing_author")
    let canonical = try fixture.canonicalBytes()

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.missingRequiredField(
        CanonicalEncoderV1.MessageField.authorWayfarerId.rawValue
    )) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonical)
    }
}

@Test
func messageV2Fixture_allowedUnknownExtensionMetadataAccepted() throws {
    let fixture = try loadMessageFixture("allowed_extension_unknown")
    let canonical = try fixture.canonicalBytes()
    let decoded = try CanonicalEncoderV1.decodeMessage(canonical: canonical)

    #expect(Hex.encode(decoded.authorWayfarerId) == fixture.expectedAuthorWayfarerId)
    #expect(decoded.extensionMetadata != nil)
}

@Test
func messageV2Fixture_disallowedStructuralUnknownRejected() throws {
    let fixture = try loadMessageFixture("disallowed_structural_unknown")
    let canonical = try fixture.canonicalBytes()

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.unknownField(0x7f)) {
        _ = try CanonicalEncoderV1.decodeMessage(canonical: canonical)
    }
}

private struct MessageFixture: Codable {
    let canonicalHex: String
    let transportPeerHex: String
    let expectedAuthorWayfarerId: String

    func canonicalBytes() throws -> Data {
        guard let bytes = Hex.decode(canonicalHex) else {
            struct InvalidHex: Swift.Error {}
            throw InvalidHex()
        }
        return bytes
    }
}

private func loadMessageFixture(_ name: String) throws -> MessageFixture {
    let resourcePath = "Fixtures/Protocol/message-v2/\(name).json"
    guard let url = Bundle.module.url(forResource: resourcePath, withExtension: nil) else {
        struct MissingFixture: Swift.Error {}
        throw MissingFixture()
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(MessageFixture.self, from: data)
}
