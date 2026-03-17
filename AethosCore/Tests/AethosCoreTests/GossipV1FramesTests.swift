import Foundation
import XCTest
@testable import AethosCore

final class GossipV1FramesTests: XCTestCase {
    func testHelloRoundTripAndMatchesFixtureBytes() throws {
        let frame = try helloFixtureFrame()
        try assertRoundTripAndFixture(frame: frame, fixtureFileName: "hello.cbor")
    }

    func testSummaryRoundTripAndMatchesFixtureBytes() throws {
        let frame = try summaryFixtureFrame()
        try assertRoundTripAndFixture(frame: frame, fixtureFileName: "summary.cbor")
    }

    func testSummaryDecode_oldPayloadWithoutPreviewFields_defaultsToEmptyPreview() throws {
        let bytes = try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("type"), value: .text(GossipV1FrameType.SUMMARY.rawValue)),
                .init(key: .text("payload"), value: .map([
                    .init(key: .text("bloom_filter"), value: .bytes(Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES))),
                    .init(key: .text("item_count"), value: .unsigned(0)),
                ])),
            ])
        )

        let decoded = try GossipV1Frame.decode(bytes: bytes)
        guard case .summary(let summary) = decoded else {
            return XCTFail("Expected summary")
        }
        XCTAssertTrue(summary.previewItemIDs.isEmpty)
        XCTAssertNil(summary.previewCursor)
    }

    func testSummaryPreviewRoundTrip_usesItemIDHexText() throws {
        let a = try GossipV1ItemID(bytes: Data(repeating: 0x10, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0x20, count: 32))
        let bloom = Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES)
        let summary = try GossipV1SummaryFrame(
            bloomFilter: bloom,
            itemCount: 2,
            previewItemIDs: [a, b]
        )
        XCTAssertEqual(summary.previewCursor, b)

        let decoded = try GossipV1Frame.decode(bytes: GossipV1Frame.summary(summary).encode())
        XCTAssertEqual(decoded, .summary(summary))
    }

    func testSummaryPayloadUnknownKeyRejected() throws {
        let a = try GossipV1ItemID(bytes: Data(repeating: 0x10, count: 32))
        let bytes = try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("type"), value: .text(GossipV1FrameType.SUMMARY.rawValue)),
                .init(key: .text("payload"), value: .map([
                    .init(key: .text("bloom_filter"), value: .bytes(Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES))),
                    .init(key: .text("item_count"), value: .unsigned(1)),
                    .init(key: .text("preview_item_ids"), value: .array([.text(a.hex)])),
                    .init(key: .text("future"), value: .unsigned(1)),
                ])),
            ])
        )

        XCTAssertThrowsError(try GossipV1Frame.decode(bytes: bytes)) { error in
            guard case .payloadKeysMismatch(let expected, let actual) = error as? GossipV1FrameError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, ["bloom_filter", "item_count", "preview_cursor", "preview_item_ids"])
            XCTAssertEqual(actual, ["bloom_filter", "future", "item_count", "preview_item_ids"])
        }
    }

    func testSummaryPayloadWithPreviewKeysDecodes() throws {
        let a = try GossipV1ItemID(bytes: Data(repeating: 0x10, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0x20, count: 32))
        let bytes = try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("type"), value: .text(GossipV1FrameType.SUMMARY.rawValue)),
                .init(key: .text("payload"), value: .map([
                    .init(key: .text("bloom_filter"), value: .bytes(Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES))),
                    .init(key: .text("item_count"), value: .unsigned(2)),
                    .init(key: .text("preview_item_ids"), value: .array([.text(a.hex), .text(b.hex)])),
                    .init(key: .text("preview_cursor"), value: .text(b.hex)),
                ])),
            ])
        )

        let decoded = try GossipV1Frame.decode(bytes: bytes)
        guard case .summary(let summary) = decoded else {
            return XCTFail("Expected summary")
        }
        XCTAssertEqual(summary.previewItemIDs, [a, b])
        XCTAssertEqual(summary.previewCursor, b)
    }

    func testSummaryPreviewValidation_rejectsTooManyItemsUnsortedDuplicatesAndInvalidCursor() throws {
        let bloom = Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES)
        let a = try GossipV1ItemID(bytes: Data(repeating: 0x01, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0x02, count: 32))
        let tooManyPreviewIDs: [GossipV1ItemID] = try (0...GossipV1.MAX_SUMMARY_PREVIEW_ITEMS).map { i in
            var bytes = Data(repeating: 0, count: 32)
            bytes[0] = UInt8(i)
            return try GossipV1ItemID(bytes: bytes)
        }

        XCTAssertThrowsError(
            try GossipV1SummaryFrame(
                bloomFilter: bloom,
                itemCount: UInt64(GossipV1.MAX_SUMMARY_PREVIEW_ITEMS + 1),
                previewItemIDs: tooManyPreviewIDs,
                previewCursor: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? GossipV1FrameError,
                .summaryPreviewTooManyItems(max: GossipV1.MAX_SUMMARY_PREVIEW_ITEMS, actual: GossipV1.MAX_SUMMARY_PREVIEW_ITEMS + 1)
            )
        }

        XCTAssertThrowsError(
            try GossipV1SummaryFrame(
                bloomFilter: bloom,
                itemCount: 2,
                previewItemIDs: [b, a],
                previewCursor: nil
            )
        ) { error in
            XCTAssertEqual(error as? GossipV1FrameError, .summaryPreviewNotLexicographicallySorted)
        }

        XCTAssertThrowsError(
            try GossipV1SummaryFrame(
                bloomFilter: bloom,
                itemCount: 2,
                previewItemIDs: [a, a],
                previewCursor: nil
            )
        ) { error in
            XCTAssertEqual(error as? GossipV1FrameError, .duplicateItemID)
        }

        XCTAssertThrowsError(
            try GossipV1SummaryFrame(
                bloomFilter: bloom,
                itemCount: 0,
                previewItemIDs: [],
                previewCursor: a
            )
        ) { error in
            XCTAssertEqual(error as? GossipV1FrameError, .summaryPreviewCursorWithoutItems)
        }

        XCTAssertThrowsError(
            try GossipV1SummaryFrame(
                bloomFilter: bloom,
                itemCount: 2,
                previewItemIDs: [a, b],
                previewCursor: a
            )
        ) { error in
            XCTAssertEqual(error as? GossipV1FrameError, .summaryPreviewCursorMustEqualLastPreviewItem)
        }
    }

    func testRequestRoundTripAndMatchesFixtureBytes() throws {
        let frame = try requestFixtureFrame()
        try assertRoundTripAndFixture(frame: frame, fixtureFileName: "request.cbor")
    }

    func testTransferRoundTripAndMatchesFixtureBytes() throws {
        let frame = try transferFixtureFrame()
        try assertRoundTripAndFixture(frame: frame, fixtureFileName: "transfer.cbor")
    }

    func testTransferObjectRejectsInvalidAuthorSignature() throws {
        let envelopeBytes = try GossipV1TestSupport.makeTransferEnvelopeBytes(seed: 77)
        var tampered = envelopeBytes
        tampered[tampered.count - 1] ^= 0x01
        let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: tampered)

        XCTAssertThrowsError(
            try GossipV1TransferFrame.Object(
                itemID: itemID,
                envelopeBytes: tampered,
                expiryUnixMs: 4_102_444_800_000,
                hopCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? GossipV1FrameError, .transferEnvelopeSignatureInvalid)
        }
    }

    func testTransferObjectRejectsMismatchedAuthorPublicKeyAndSignature() throws {
        let envelopeBytes = try GossipV1TestSupport.makeTransferEnvelopeBytes(seed: 78)
        let decoded = try CanonicalCBORDecoder().decode(envelopeBytes)
        guard case .map(let entries) = decoded else {
            return XCTFail("Expected envelope map")
        }

        let mutatedEntries = entries.map { entry -> CanonicalCBORValue.MapEntry in
            guard case .text(let key) = entry.key, key == "author_pubkey" else {
                return entry
            }
            return .init(key: .text("author_pubkey"), value: .bytes(Data(repeating: 0xFF, count: 32)))
        }
        let mutatedEnvelope = try CanonicalCBOREncoder().encode(.map(mutatedEntries))
        let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: mutatedEnvelope)

        XCTAssertThrowsError(
            try GossipV1TransferFrame.Object(
                itemID: itemID,
                envelopeBytes: mutatedEnvelope,
                expiryUnixMs: 4_102_444_800_000,
                hopCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? GossipV1FrameError, .transferEnvelopeSignatureInvalid)
        }
    }

    func testTransferObjectItemIDChangesWhenAuthorChanges() throws {
        let toWayfarerId = Data(repeating: 0xAA, count: 32)
        let manifestId = Data(repeating: 0xBB, count: 32)
        let body = Data("same-body".utf8)

        let envelopeA = try GossipV1TestSupport.makeTransferEnvelopeBytes(
            toWayfarerId: toWayfarerId,
            manifestId: manifestId,
            body: body,
            authorSeed: 1
        )
        let envelopeB = try GossipV1TestSupport.makeTransferEnvelopeBytes(
            toWayfarerId: toWayfarerId,
            manifestId: manifestId,
            body: body,
            authorSeed: 2
        )

        XCTAssertNotEqual(GossipV1ItemID.derive(fromEnvelopeBytes: envelopeA), GossipV1ItemID.derive(fromEnvelopeBytes: envelopeB))
    }

    func testTransferRelayForwardedObjectPreservesVerification() throws {
        let envelopeBytes = try GossipV1TestSupport.makeTransferEnvelopeBytes(seed: 79)
        let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)
        let firstHop = try GossipV1TransferFrame.Object(itemID: itemID, envelopeBytes: envelopeBytes, expiryUnixMs: 4_102_444_800_000, hopCount: 0)
        let forwardedHop = try GossipV1TransferFrame.Object(itemID: itemID, envelopeBytes: envelopeBytes, expiryUnixMs: 4_102_444_800_000, hopCount: 1)

        XCTAssertEqual(firstHop.itemID, forwardedHop.itemID)
        XCTAssertEqual(firstHop.envelopeBytes, forwardedHop.envelopeBytes)
    }

    func testTransferSenderDerivationIsDeterministicFromAuthorPublicKey() throws {
        let envelopeBytes = try GossipV1TestSupport.makeTransferEnvelopeBytes(seed: 80)
        let decoded = try CanonicalCBORDecoder().decode(envelopeBytes)
        guard case .map(let entries) = decoded else {
            return XCTFail("Expected envelope map")
        }

        let authorPubKey = try XCTUnwrap(entries.first(where: {
            guard case .text(let key) = $0.key else { return false }
            return key == "author_pubkey"
        }))
        guard case .bytes(let pubKeyBytes) = authorPubKey.value else {
            return XCTFail("Expected author_pubkey bytes")
        }

        let senderA = AethosIDs.sha256(pubKeyBytes)
        let senderB = AethosIDs.sha256(pubKeyBytes)
        XCTAssertEqual(senderA, senderB)
        XCTAssertEqual(senderA.count, 32)
    }

    func testReceiptRoundTripAndMatchesFixtureBytes() throws {
        let frame = try receiptFixtureFrame()
        try assertRoundTripAndFixture(frame: frame, fixtureFileName: "receipt.cbor")
    }

    func testRelayIngestRoundTripAndMatchesFixtureBytes() throws {
        let frame = try relayIngestFixtureFrame()
        try assertRoundTripAndFixture(frame: frame, fixtureFileName: "relay_ingest.cbor")
    }

    func testUnknownFrameTypeRejected() throws {
        let payload: CanonicalCBORValue = .map([])
        let bytes = try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("type"), value: .text("NOPE")),
                .init(key: .text("payload"), value: payload),
            ])
        )

        XCTAssertThrowsError(try GossipV1Frame.decode(bytes: bytes)) { err in
            XCTAssertEqual(err as? GossipV1FrameError, .unknownFrameType("NOPE"))
        }
    }

    func testPayloadExtraKeyRejected() throws {
        let bytes = try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("type"), value: .text(GossipV1FrameType.REQUEST.rawValue)),
                .init(key: .text("payload"), value: .map([
                    .init(key: .text("want"), value: .array([])),
                    .init(key: .text("extra"), value: .unsigned(1)),
                ])),
            ])
        )

        XCTAssertThrowsError(try GossipV1Frame.decode(bytes: bytes)) { err in
            guard case .payloadKeysMismatch(let expected, let actual) = err as? GossipV1FrameError else {
                return XCTFail("Unexpected error: \(err)")
            }
            XCTAssertEqual(expected, ["want"])
            XCTAssertEqual(actual, ["extra", "want"])
        }
    }

    func testPayloadMissingKeyRejected() throws {
        let bytes = try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("type"), value: .text(GossipV1FrameType.SUMMARY.rawValue)),
                .init(key: .text("payload"), value: .map([
                    .init(key: .text("item_count"), value: .unsigned(0)),
                ])),
            ])
        )

        XCTAssertThrowsError(try GossipV1Frame.decode(bytes: bytes)) { err in
            guard case .payloadKeysMismatch(let expected, let actual) = err as? GossipV1FrameError else {
                return XCTFail("Unexpected error: \(err)")
            }
            XCTAssertEqual(expected, ["bloom_filter", "item_count"])
            XCTAssertEqual(actual, ["item_count"])
        }
    }

    func testUnknownTopLevelKeyIgnored() throws {
        let frame = try requestFixtureFrame()
        let canonical = frame.encode()
        let decodedValue = try CanonicalCBORDecoder().decode(canonical)
        guard case .map(let entries) = decodedValue else { return XCTFail("Expected map") }
        var mutated = entries
        mutated.append(.init(key: .text("future"), value: .text("ok")))
        let bytes = try CanonicalCBOREncoder().encode(.map(mutated))

        let decoded = try GossipV1Frame.decode(bytes: bytes)
        XCTAssertEqual(decoded, frame)
    }

    func testRequestWantMustBeLexicographicallySorted_decodeRejectsUnsorted() throws {
        let a = try GossipV1ItemID(bytes: Data(repeating: 0x00, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0x11, count: 32))

        // Build non-canonical REQUEST bytes with out-of-order want.
        let payload: CanonicalCBORValue = .map([
            .init(key: .text("want"), value: .array([.text(b.hex), .text(a.hex)])),
        ])
        let bytes = try CanonicalCBOREncoder().encode(
            .map([
                .init(key: .text("type"), value: .text(GossipV1FrameType.REQUEST.rawValue)),
                .init(key: .text("payload"), value: payload),
            ])
        )

        XCTAssertThrowsError(try GossipV1Frame.decode(bytes: bytes)) { err in
            XCTAssertEqual(err as? GossipV1FrameError, .wantNotLexicographicallySorted)
        }
    }

    func testHelloEncodingIsDeterministicAcrossRepeatedEncodes() throws {
        let frame = try helloFixtureFrame()
        let a = frame.encode()
        let b = frame.encode()
        let c = frame.encode()
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }

    func testHelloPayloadMapOrderingIsCanonical_notInsertionOrder() throws {
        // Build an envelope with a HELLO payload whose keys are intentionally out-of-order.
        // The canonical encoder must reorder deterministically.
        let pubKey = Data(repeating: 0, count: 32)
        let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKey)

        let payloadOutOfOrder: CanonicalCBORValue = .map([
            .init(key: .text("node_pubkey"), value: .text(GossipV1Base64URL.encode(pubKey))),
            .init(key: .text("node_id"), value: .text(nodeID.hex)),
            .init(key: .text("version"), value: .unsigned(GossipV1.GOSSIP_VERSION)),
            .init(key: .text("capabilities"), value: .array([.text("store")])),
            .init(key: .text("propagation_class"), value: .text("direct")),
            .init(key: .text("max_transfer"), value: .unsigned(16)),
            .init(key: .text("max_want"), value: .unsigned(128)),
        ])
        let envOutOfOrder: CanonicalCBORValue = .map([
            .init(key: .text("type"), value: .text(GossipV1FrameType.HELLO.rawValue)),
            .init(key: .text("payload"), value: payloadOutOfOrder),
        ])
        let bytesOutOfOrder = try CanonicalCBOREncoder().encode(envOutOfOrder)

        let decoded = try GossipV1Frame.decode(bytes: bytesOutOfOrder)
        let expected = try helloFixtureFrame()
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.encode(), expected.encode())
    }
}

// MARK: - Fixtures

private extension GossipV1FramesTests {
    func loadFixtureBytes(_ name: String) throws -> Data {
        try GossipV1TestSupport.fixtureData(name)
    }

    func assertRoundTripAndFixture(frame: GossipV1Frame, fixtureFileName: String) throws {
        let fixture = try loadFixtureBytes(fixtureFileName)

        // Fixture bytes should decode and re-encode identically.
        // This guards against encoder ordering changes drifting fixtures silently.
        let fixtureDecoded = try GossipV1Frame.decode(bytes: fixture)
        XCTAssertEqual(fixtureDecoded.encode(), fixture)

        let encoded = frame.encode()
        let decoded = try GossipV1Frame.decode(bytes: encoded)
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(encoded, fixture)
    }

    func helloFixtureFrame() throws -> GossipV1Frame {
        let pubKey = Data(repeating: 0, count: 32)
        let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKey)
        let hello = try GossipV1HelloFrame(
            version: GossipV1.GOSSIP_VERSION,
            nodeID: nodeID,
            nodePublicKeyRawBytes: pubKey,
            capabilities: ["store"],
            propagationClass: "direct",
            maxWant: 128,
            maxTransfer: 16
        )
        return .hello(hello)
    }

    func summaryFixtureFrame() throws -> GossipV1Frame {
        let bloom = Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES)
        let summary = try GossipV1SummaryFrame(
            bloomFilter: bloom,
            itemCount: 0,
            previewItemIDs: [],
            previewCursor: nil
        )
        return .summary(summary)
    }

    func requestFixtureFrame() throws -> GossipV1Frame {
        let a = try GossipV1ItemID(bytes: Data(repeating: 0x00, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0x11, count: 32))
        let request = try GossipV1RequestFrame(
            want: [a, b].sorted(by: { DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending })
        )
        return .request(request)
    }

    func transferFixtureFrame() throws -> GossipV1Frame {
        let envBytes1 = try GossipV1TestSupport.makeTransferEnvelopeBytes(seed: 1)
        let envBytes2 = try GossipV1TestSupport.makeTransferEnvelopeBytes(seed: 2)

        let id1 = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes1)
        let id2 = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes2)

        // Far future expiry to avoid time-dependent test flakiness.
        let expiry: UInt64 = 4_102_444_800_000 // 2100-01-01T00:00:00.000Z
        let obj1 = try GossipV1TransferFrame.Object(itemID: id1, envelopeBytes: envBytes1, expiryUnixMs: expiry, hopCount: 0)
        let obj2 = try GossipV1TransferFrame.Object(itemID: id2, envelopeBytes: envBytes2, expiryUnixMs: expiry, hopCount: 1)

        let transfer = try GossipV1TransferFrame(objects: [obj1, obj2])
        return .transfer(transfer)
    }

    func receiptFixtureFrame() throws -> GossipV1Frame {
        let a = try GossipV1ItemID(bytes: Data(repeating: 0xAA, count: 32))
        let receipt = try GossipV1ReceiptFrame(received: [a])
        return .receipt(receipt)
    }

    func relayIngestFixtureFrame() throws -> GossipV1Frame {
        let a = try GossipV1ItemID(bytes: Data(repeating: 0xBB, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0xCC, count: 32))
        let ingest = try GossipV1RelayIngestFrame(itemIDs: [a, b])
        return .relayIngest(ingest)
    }
}
