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

        let want1 = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: candidates,
            localHaveItemIDs: [],
            peerMaxWant: 128
        )
        let want2 = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: candidates,
            localHaveItemIDs: [],
            peerMaxWant: 128
        )

        XCTAssertEqual(want1, want2)
        XCTAssertEqual(Set(want1).count, want1.count)
        XCTAssertEqual(want1, [a, b, c])

        let expectedByByteLexicographicOrder = want1.sorted {
            $0.rawBytes().lexicographicallyPrecedes($1.rawBytes())
        }
        XCTAssertEqual(want1, expectedByByteLexicographicOrder)
    }

    func testPublicReconciliation_truncationRespectsPeerMaxWant() throws {
        let ids = try (0..<10).map { i in try itemID(firstByte: UInt8(i)) }
        let peerBloom = GossipV1BloomFilter.build(for: ids)

        let want = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: Array(ids.reversed()),
            localHaveItemIDs: [],
            peerMaxWant: 3
        )

        let expected = ids.sorted {
            $0.rawBytes().lexicographicallyPrecedes($1.rawBytes())
        }
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

        let want = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: Array(ids.reversed()),
            localHaveItemIDs: [],
            peerMaxWant: UInt64(GossipV1.MAX_WANT_ITEMS + 100)
        )

        let expected = ids.sorted {
            $0.rawBytes().lexicographicallyPrecedes($1.rawBytes())
        }
        XCTAssertEqual(want, Array(expected.prefix(GossipV1.MAX_WANT_ITEMS)))
    }

    func testPublicReconciliation_excludesLocalHaveItemIDs() throws {
        let a = try itemID(firstByte: 0x01)
        let b = try itemID(firstByte: 0x02)
        let peerBloom = GossipV1BloomFilter.build(for: [a, b])

        let want = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: [b, a],
            localHaveItemIDs: [b],
            peerMaxWant: 128
        )

        XCTAssertEqual(want, [a])
    }

    func testPublicReconciliation_peerMaxWantZeroYieldsEmptyWant() throws {
        let item = try itemID(firstByte: 0xAB)
        let peerBloom = GossipV1BloomFilter.build(for: [item])

        let want = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: [item],
            localHaveItemIDs: [],
            peerMaxWant: 0
        )

        XCTAssertEqual(want, [])
    }

    func testPublicReconciliation_invalidBloomByteCountThrows() throws {
        let item = try itemID(firstByte: 0xAB)
        let invalidBloom = Data(repeating: 0x00, count: GossipV1.BLOOM_FILTER_BYTES - 1)

        XCTAssertThrowsError(
            try GossipV1Reconciliation.computeWant(
                bloomFilterBytes: invalidBloom,
                candidateItemIDs: [item],
                localHaveItemIDs: [],
                peerMaxWant: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? GossipV1ReconciliationError,
                .invalidBloomByteCount(expected: GossipV1.BLOOM_FILTER_BYTES, actual: invalidBloom.count)
            )
        }
    }

    func testPublicReconciliation_invalidBloomByteCountTooLongThrows() throws {
        let item = try itemID(firstByte: 0xAB)
        let invalidBloom = Data(repeating: 0x00, count: GossipV1.BLOOM_FILTER_BYTES + 1)

        XCTAssertThrowsError(
            try GossipV1Reconciliation.computeWant(
                bloomFilterBytes: invalidBloom,
                candidateItemIDs: [item],
                localHaveItemIDs: [],
                peerMaxWant: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? GossipV1ReconciliationError,
                .invalidBloomByteCount(expected: GossipV1.BLOOM_FILTER_BYTES, actual: invalidBloom.count)
            )
        }
    }

    func testPublicReconciliation_peerMaxWantUInt64MaxIsClamped() throws {
        let ids = try (0..<(GossipV1.MAX_WANT_ITEMS + 10)).map { i in
            var bytes = Data(repeating: 0, count: 32)
            bytes[0] = UInt8(i % 256)
            bytes[1] = UInt8(i / 256)
            return try GossipV1ItemID(bytes: bytes)
        }
        let peerBloom = GossipV1BloomFilter.build(for: ids)

        let want = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: Array(ids.reversed()),
            localHaveItemIDs: [],
            peerMaxWant: .max
        )

        XCTAssertLessThanOrEqual(want.count, GossipV1.MAX_WANT_ITEMS)
    }

    func testPublicReconciliation_includesUnknownPeerPreviewIDs_evenOutsideCandidates() throws {
        let previewUnknown = try itemID(firstByte: 0xF0)
        let candidateKnown = try itemID(firstByte: 0x01)
        let peerBloom = GossipV1BloomFilter.build(for: [previewUnknown, candidateKnown])

        let want = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: [candidateKnown],
            peerPreviewItemIDs: [previewUnknown],
            localHaveItemIDs: [],
            peerMaxWant: 128
        )

        let expected = [previewUnknown, candidateKnown].sorted {
            $0.rawBytes().lexicographicallyPrecedes($1.rawBytes())
        }
        XCTAssertEqual(want, expected)
    }

    func testPublicReconciliation_previewUnknownPriority_survivesSmallPeerMaxWantTruncation() throws {
        let preview1 = try itemID(firstByte: 0xF0)
        let preview2 = try itemID(firstByte: 0xF1)
        let candidateLowA = try itemID(firstByte: 0x01)
        let candidateLowB = try itemID(firstByte: 0x02)

        let peerBloom = GossipV1BloomFilter.build(for: [preview1, preview2, candidateLowA, candidateLowB])
        let want = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: [candidateLowB, candidateLowA],
            peerPreviewItemIDs: [preview2, preview1],
            localHaveItemIDs: [],
            peerMaxWant: 2
        )

        let expected = [preview1, preview2].sorted {
            $0.rawBytes().lexicographicallyPrecedes($1.rawBytes())
        }
        XCTAssertEqual(want, expected)
    }

    func testPublicReconciliation_previewUnknownFilteredByBloom() throws {
        let previewUnknown = try itemID(firstByte: 0xDD)
        let candidateKnown = try itemID(firstByte: 0x11)
        let peerBloom = GossipV1BloomFilter.build(for: [candidateKnown])

        let want = try GossipV1Reconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: [candidateKnown],
            peerPreviewItemIDs: [previewUnknown],
            localHaveItemIDs: [],
            peerMaxWant: 8
        )

        XCTAssertEqual(want, [candidateKnown])
    }

    private func itemID(firstByte: UInt8) throws -> GossipV1ItemID {
        var bytes = Data(repeating: 0, count: 32)
        bytes[0] = firstByte
        return try GossipV1ItemID(bytes: bytes)
    }
}
