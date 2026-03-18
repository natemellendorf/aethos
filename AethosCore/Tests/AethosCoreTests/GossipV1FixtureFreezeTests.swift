import Foundation
import XCTest
@testable import AethosCore

final class GossipV1FixtureFreezeTests: XCTestCase {
    func testFreezeKnownGoodFixtureBytes_allFramesMatchFixtures_exactly() throws {
        let vectors: [(fixture: String, build: () throws -> GossipV1Frame)] = [
            ("hello.cbor", { try .hello(GossipV1FixtureFrames.hello()) }),
            ("summary.cbor", { try .summary(GossipV1FixtureFrames.summary()) }),
            ("request.cbor", { try .request(GossipV1FixtureFrames.request()) }),
            ("transfer.cbor", { try .transfer(GossipV1FixtureFrames.transfer()) }),
            ("receipt.cbor", { try .receipt(GossipV1FixtureFrames.receipt()) }),
            ("relay_ingest.cbor", { try .relayIngest(GossipV1FixtureFrames.relayIngest()) }),
        ]

        for v in vectors {
            let expected = try GossipV1TestSupport.fixtureData(v.fixture)
            let built = try v.build().encode()
            XCTAssertEqual(built, expected, "Fixture drift: \(v.fixture) bytes changed")
        }
    }
}

private enum GossipV1FixtureFrames {
    static func hello() throws -> GossipV1HelloFrame {
        // Matches Fixtures/Protocol/gossip-v1/hello.json.
        let pubKey = Data(repeating: 0, count: 32)
        let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKey)
        return try GossipV1HelloFrame(
            version: GossipV1.GOSSIP_VERSION,
            nodeID: nodeID,
            nodePublicKeyRawBytes: pubKey,
            capabilities: ["store"],
            propagationClass: "direct",
            maxWant: 128,
            maxTransfer: 16
        )
    }

    static func summary() throws -> GossipV1SummaryFrame {
        // Matches Fixtures/Protocol/gossip-v1/summary.json.
        try GossipV1SummaryFrame(
            bloomFilter: Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES),
            itemCount: 0
        )
    }

    static func request() throws -> GossipV1RequestFrame {
        // Matches Fixtures/Protocol/gossip-v1/request.json.
        let a = try GossipV1ItemID(bytes: Data(repeating: 0x00, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0x11, count: 32))
        let want = [a, b].sorted(by: { DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending })
        return try GossipV1RequestFrame(want: want)
    }

    static func transfer() throws -> GossipV1TransferFrame {
        // Matches Fixtures/Protocol/gossip-v1/transfer.json.
        return try GossipV1TestSupport.makeTransferFixtureFrame()
    }

    static func receipt() throws -> GossipV1ReceiptFrame {
        // Matches Fixtures/Protocol/gossip-v1/receipt.json.
        let a = try GossipV1ItemID(bytes: Data(repeating: 0xAA, count: 32))
        return try GossipV1ReceiptFrame(received: [a])
    }

    static func relayIngest() throws -> GossipV1RelayIngestFrame {
        // Matches Fixtures/Protocol/gossip-v1/relay_ingest.json.
        let a = try GossipV1ItemID(bytes: Data(repeating: 0xBB, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0xCC, count: 32))
        return try GossipV1RelayIngestFrame(itemIDs: [a, b])
    }
}
