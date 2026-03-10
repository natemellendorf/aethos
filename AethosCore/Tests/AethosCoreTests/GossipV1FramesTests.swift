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

    func testRequestRoundTripAndMatchesFixtureBytes() throws {
        let frame = try requestFixtureFrame()
        try assertRoundTripAndFixture(frame: frame, fixtureFileName: "request.cbor")
    }

    func testTransferRoundTripAndMatchesFixtureBytes() throws {
        let frame = try transferFixtureFrame()
        try assertRoundTripAndFixture(frame: frame, fixtureFileName: "transfer.cbor")
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
}

// MARK: - Fixtures

private extension GossipV1FramesTests {
    func fixturesDir() -> URL {
        // AethosCore/Tests/AethosCoreTests/ -> repo root Fixtures/...
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent() // AethosCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AethosCore
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Fixtures/Protocol/gossip-v1", isDirectory: true)
    }

    func loadFixtureBytes(_ name: String) throws -> Data {
        let url = fixturesDir().appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    func assertRoundTripAndFixture(frame: GossipV1Frame, fixtureFileName: String) throws {
        let encoded = frame.encode()
        let decoded = try GossipV1Frame.decode(bytes: encoded)
        XCTAssertEqual(decoded, frame)

        let fixture = try loadFixtureBytes(fixtureFileName)
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
        let summary = try GossipV1SummaryFrame(bloomFilter: bloom, itemCount: 0)
        return .summary(summary)
    }

    func requestFixtureFrame() throws -> GossipV1Frame {
        let a = try GossipV1ItemID(bytes: Data(repeating: 0x00, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0x11, count: 32))
        let request = try GossipV1RequestFrame(want: [a, b])
        return .request(request)
    }

    func transferFixtureFrame() throws -> GossipV1Frame {
        let envBytes1 = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
        let envBytes2 = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(2))]))

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
