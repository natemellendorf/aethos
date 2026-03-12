import Foundation
import XCTest
import AethosCore

final class GossipV1PublicReconciliationAPITests: XCTestCase {
    func testPublicReconciliation_isDeterministicOrderedAndUnique() throws {
        let a = try itemID(firstByte: 0x00)
        let b = try itemID(firstByte: 0x11)
        let c = try itemID(firstByte: 0x22)

        let peerBloom = GossipV1BloomFilter.build(for: [a, b, c])
        let candidates = [c, a, b, a, c]

        let want1 = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: candidates,
            localHaveItemIDs: [],
            peerMaxWant: 128
        )
        let want2 = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: candidates,
            localHaveItemIDs: [],
            peerMaxWant: 128
        )

        XCTAssertEqual(want1, want2)
        XCTAssertEqual(Set(want1).count, want1.count)
        XCTAssertEqual(want1, [a, b, c])

        let expectedByByteLexicographicOrder = want1.sorted { $0.hex < $1.hex }
        XCTAssertEqual(want1, expectedByByteLexicographicOrder)
    }

    func testPublicReconciliation_truncationRespectsPeerMaxWant() throws {
        let ids = try (0..<10).map { i in try itemID(firstByte: UInt8(i)) }
        let peerBloom = GossipV1BloomFilter.build(for: ids)

        let want = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: Array(ids.reversed()),
            localHaveItemIDs: [],
            peerMaxWant: 3
        )

        let expected = ids.sorted { $0.hex < $1.hex }
        XCTAssertEqual(want, Array(expected.prefix(3)))
    }

    func testPublicReconciliation_truncationRespectsGlobalMaxWantItems() throws {
        let ids = try (0..<(GossipV1.MAX_WANT_ITEMS + 10)).map { i in
            var bytes = Data(repeating: 0, count: 32)
            bytes[0] = UInt8(i % 256)
            bytes[1] = UInt8(i / 256)
            return try GossipV1ItemID(bytes: bytes)
        }
        let peerBloom = GossipV1BloomFilter.build(for: ids)

        let want = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: Array(ids.reversed()),
            localHaveItemIDs: [],
            peerMaxWant: GossipV1.MAX_WANT_ITEMS + 100
        )

        let expected = ids.sorted { $0.hex < $1.hex }
        XCTAssertEqual(want, Array(expected.prefix(GossipV1.MAX_WANT_ITEMS)))
    }

    func testPublicReconciliation_invalidBloomByteCountThrows() throws {
        let item = try itemID(firstByte: 0xAB)
        let invalidBloom = Data(repeating: 0x00, count: GossipV1.BLOOM_FILTER_BYTES - 1)

        XCTAssertThrowsError(
            try GossipV1SummaryReconciliation.computeWant(
                bloomFilterBytes: invalidBloom,
                candidateItemIDs: [item],
                localHaveItemIDs: [],
                peerMaxWant: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? GossipV1FrameError,
                .invalidBloomByteCount(expected: GossipV1.BLOOM_FILTER_BYTES, actual: invalidBloom.count)
            )
        }
    }

    private func itemID(firstByte: UInt8) throws -> GossipV1ItemID {
        var bytes = Data(repeating: 0, count: 32)
        bytes[0] = firstByte
        return try GossipV1ItemID(bytes: bytes)
    }
}
