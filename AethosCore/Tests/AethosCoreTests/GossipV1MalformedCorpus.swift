import Foundation
@testable import AethosCore

/// Reusable corpus of malformed inputs for GossipV1 tests.
///
/// Corpus helpers are test-only and intentionally explicit (no randomness).
enum GossipV1MalformedCorpus {
    static func unknownFrameType() throws -> Data {
        try GossipV1FixtureVectorBuilder.encodeEnvelopeBytes(
            .map([
                .init(key: .text("type"), value: .text("NOPE")),
                .init(key: .text("payload"), value: .map([])),
            ])
        )
    }

    static func missingPayload(type: GossipV1FrameType) throws -> Data {
        try GossipV1FixtureVectorBuilder.encodeEnvelopeBytes(
            .map([
                .init(key: .text("type"), value: .text(type.rawValue)),
            ])
        )
    }

    static func payloadNotMap(type: GossipV1FrameType) throws -> Data {
        try GossipV1FixtureVectorBuilder.encodeEnvelopeBytes(
            .map([
                .init(key: .text("type"), value: .text(type.rawValue)),
                .init(key: .text("payload"), value: .unsigned(1)),
            ])
        )
    }

    static func requestWantWrongScalarType() throws -> Data {
        // want must be an array.
        let payload: CanonicalCBORValue = .map([
            .init(key: .text("want"), value: .text("not-an-array")),
        ])
        return try GossipV1FixtureVectorBuilder.encodeFrameBytes(type: .REQUEST, payload: payload)
    }

    static func requestWantUnsorted(a: GossipV1ItemID, b: GossipV1ItemID) throws -> Data {
        let payload: CanonicalCBORValue = .map([
            .init(key: .text("want"), value: .array([.text(b.hex), .text(a.hex)])),
        ])
        return try GossipV1FixtureVectorBuilder.encodeFrameBytes(type: .REQUEST, payload: payload)
    }

    static func requestWantWithDuplicates(id: GossipV1ItemID) throws -> Data {
        // Duplicate IDs in want MUST be rejected at decode/init boundary.
        let payload: CanonicalCBORValue = .map([
            .init(key: .text("want"), value: .array([.text(id.hex), .text(id.hex)])),
        ])
        return try GossipV1FixtureVectorBuilder.encodeFrameBytes(type: .REQUEST, payload: payload)
    }

    static func transferObjectInvalidBase64URLAlphabet() throws -> Data {
        let idHex = String(repeating: "0", count: 64)
        let payload: CanonicalCBORValue = .map([
            .init(key: .text("objects"), value: .array([
                .map([
                    .init(key: .text("item_id"), value: .text(idHex)),
                    .init(key: .text("envelope_b64"), value: .text("**")),
                    .init(key: .text("expiry_unix_ms"), value: .unsigned(0)),
                    .init(key: .text("hop_count"), value: .unsigned(0)),
                ]),
            ])),
        ])
        return try GossipV1FixtureVectorBuilder.encodeFrameBytes(type: .TRANSFER, payload: payload)
    }

    static func transferObjectInvalidItemIDHex() throws -> Data {
        let payload: CanonicalCBORValue = .map([
            .init(key: .text("objects"), value: .array([
                .map([
                    .init(key: .text("item_id"), value: .text("not-hex")),
                    .init(key: .text("envelope_b64"), value: .text("AA")),
                    .init(key: .text("expiry_unix_ms"), value: .unsigned(0)),
                    .init(key: .text("hop_count"), value: .unsigned(0)),
                ]),
            ])),
        ])
        return try GossipV1FixtureVectorBuilder.encodeFrameBytes(type: .TRANSFER, payload: payload)
    }

    static func helloNodeIDMismatch() throws -> Data {
        let pubKey = Data(repeating: 0x01, count: 32)
        let wrongNodeID = try GossipV1NodeID(bytes: Data(repeating: 0xFF, count: 32))
        let payload: CanonicalCBORValue = .map([
            .init(key: .text("version"), value: .unsigned(GossipV1.GOSSIP_VERSION)),
            .init(key: .text("node_id"), value: .text(wrongNodeID.hex)),
            .init(key: .text("node_pubkey"), value: .text(GossipV1Base64URL.encode(pubKey))),
            .init(key: .text("capabilities"), value: .array([.text("store")])),
            .init(key: .text("propagation_class"), value: .text("direct")),
            .init(key: .text("max_want"), value: .unsigned(128)),
            .init(key: .text("max_transfer"), value: .unsigned(16)),
        ])
        return try GossipV1FixtureVectorBuilder.encodeFrameBytes(type: .HELLO, payload: payload)
    }

    static func cborIndefiniteLengthMap() -> Data {
        // 0xBF is "start indefinite-length map".
        Data([0xBF])
    }

    static func cborDuplicateTopLevelKey_type() -> Data {
        // Map(2): "type"="HELLO", "type"="SUMMARY"
        // a2 64 74 79 70 65 65 48 45 4c 4c 4f 64 74 79 70 65 67 53 55 4d 4d 41 52 59
        Data([
            0xA2,
            0x64, 0x74, 0x79, 0x70, 0x65,
            0x65, 0x48, 0x45, 0x4C, 0x4C, 0x4F,
            0x64, 0x74, 0x79, 0x70, 0x65,
            0x67, 0x53, 0x55, 0x4D, 0x4D, 0x41, 0x52, 0x59,
        ])
    }
}
