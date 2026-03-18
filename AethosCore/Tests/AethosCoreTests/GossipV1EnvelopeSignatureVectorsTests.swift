import Foundation
import XCTest
@testable import AethosCore

final class GossipV1EnvelopeSignatureVectorsTests: XCTestCase {
    func testSignedEnvelopeVectors_coverAuthAndDeterministicSenderDerivation() throws {
        let vectors = try loadVectors()

        let valid = try XCTUnwrap(vectors["valid_signature"] as? [String: Any])
        let validEnvelopeB64 = try XCTUnwrap(valid["envelope_b64"] as? String)
        let validEnvelopeBytes = try GossipV1Base64URL.decode(validEnvelopeB64)
        let validItemIDHex = try XCTUnwrap(valid["item_id"] as? String)
        let validItemID = try GossipV1ItemID(hex: validItemIDHex)

        _ = try GossipV1TransferFrame.Object(
            itemID: validItemID,
            envelopeBytes: validEnvelopeBytes,
            expiryUnixMs: 4_102_444_800_000,
            hopCount: 0
        )

        let invalidSig = try XCTUnwrap(vectors["invalid_signature_rejection"] as? [String: Any])
        let invalidSigHex = try XCTUnwrap(invalidSig["author_sig_hex"] as? String)
        let invalidSigBytes = try XCTUnwrap(Hex.decode(invalidSigHex))
        let invalidSignatureEnvelope = try mutateEnvelope(validEnvelopeBytes, key: "author_sig", value: .bytes(invalidSigBytes))
        let invalidSignatureItemID = GossipV1ItemID.derive(fromEnvelopeBytes: invalidSignatureEnvelope)
        XCTAssertThrowsError(
            try GossipV1TransferFrame.Object(
                itemID: invalidSignatureItemID,
                envelopeBytes: invalidSignatureEnvelope,
                expiryUnixMs: 4_102_444_800_000,
                hopCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? GossipV1FrameError, .transferEnvelopeSignatureInvalid)
        }

        let mismatched = try XCTUnwrap(vectors["mismatched_pubkey_signature_rejection"] as? [String: Any])
        let mismatchedPubHex = try XCTUnwrap(mismatched["author_pubkey_hex"] as? String)
        let mismatchedPub = try XCTUnwrap(Hex.decode(mismatchedPubHex))
        let mismatchedEnvelope = try mutateEnvelope(validEnvelopeBytes, key: "author_pubkey", value: .bytes(mismatchedPub))
        let mismatchedItemID = GossipV1ItemID.derive(fromEnvelopeBytes: mismatchedEnvelope)
        XCTAssertThrowsError(
            try GossipV1TransferFrame.Object(
                itemID: mismatchedItemID,
                envelopeBytes: mismatchedEnvelope,
                expiryUnixMs: 4_102_444_800_000,
                hopCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? GossipV1FrameError, .transferEnvelopeSignatureInvalid)
        }

        let deterministic = try XCTUnwrap(vectors["deterministic_wayfarer_derivation"] as? [String: Any])
        let deterministicPubHex = try XCTUnwrap(deterministic["author_pubkey_hex"] as? String)
        let deterministicPub = try XCTUnwrap(Hex.decode(deterministicPubHex))
        let expectedWayfarerID = try XCTUnwrap(deterministic["wayfarer_id"] as? String)
        XCTAssertEqual(Hex.encode(AethosIDs.sha256(deterministicPub)), expectedWayfarerID)

        let relay = try XCTUnwrap(vectors["relay_forwarded_object_verification"] as? [String: Any])
        let relayItemID = try GossipV1ItemID(hex: try XCTUnwrap(relay["item_id"] as? String))
        let relayEnvelope = try GossipV1Base64URL.decode(try XCTUnwrap(relay["envelope_b64"] as? String))
        _ = try GossipV1TransferFrame.Object(itemID: relayItemID, envelopeBytes: relayEnvelope, expiryUnixMs: 4_102_444_800_000, hopCount: 0)
        _ = try GossipV1TransferFrame.Object(itemID: relayItemID, envelopeBytes: relayEnvelope, expiryUnixMs: 4_102_444_800_000, hopCount: 1)
    }

    private func loadVectors() throws -> [String: Any] {
        let data = try GossipV1TestSupport.fixtureData("item_id_derivation.json")
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let vectors = decoded as? [String: Any] else {
            XCTFail("Expected top-level object")
            return [:]
        }
        return vectors
    }

    private func mutateEnvelope(_ envelopeBytes: Data, key: String, value: CanonicalCBORValue) throws -> Data {
        let decoded = try CanonicalCBORDecoder().decode(envelopeBytes)
        guard case .map(let entries) = decoded else {
            throw GossipV1FrameError.transferEnvelopeNotMap
        }
        let mutated = entries.map { entry -> CanonicalCBORValue.MapEntry in
            guard case .text(let currentKey) = entry.key, currentKey == key else {
                return entry
            }
            return .init(key: .text(currentKey), value: value)
        }
        return try CanonicalCBOREncoder().encode(.map(mutated))
    }
}
