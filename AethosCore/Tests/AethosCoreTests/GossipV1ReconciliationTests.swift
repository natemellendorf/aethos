import Foundation
import XCTest
@testable import AethosCore

final class GossipV1ReconciliationTests: XCTestCase {
    // Spec references:
    // - `docs/protocol/encounter.md` §8.1 (SUMMARY→REQUEST reconciliation; corrected semantics: want items we might be missing that peer bloom might contain)
    // - `docs/protocol/frames.md` (REQUEST ordering: bytewise lexicographic over decoded digest bytes)

    func testReconciliationScenario_peerHasXY_localHasY_requestsX_deterministically() throws {
        let x = try GossipV1ItemID(bytes: Data(repeating: 0x01, count: 32))
        let y = try GossipV1ItemID(bytes: Data(repeating: 0x02, count: 32))

        // Peer SUMMARY bloom: peer has {X, Y}.
        let peerBloom = GossipV1BloomFilter.build(for: [x, y])

        let localHave: Set<GossipV1ItemID> = [y]
        let candidates = [x, y]

        let want1 = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: candidates,
            localHaveItemIDs: localHave,
            peerMaxWant: 128
        )
        let want2 = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: candidates,
            localHaveItemIDs: localHave,
            peerMaxWant: 128
        )

        XCTAssertEqual(want1, [x])
        XCTAssertEqual(want2, [x])
    }

    func testReconciliationOrdering_stableAndLexicographic_overScrambledCandidates() throws {
        let a = try GossipV1ItemID(bytes: Data(repeating: 0x00, count: 32))
        let b = try GossipV1ItemID(bytes: Data(repeating: 0x11, count: 32))
        let c = try GossipV1ItemID(bytes: Data(repeating: 0x22, count: 32))

        let peerBloom = GossipV1BloomFilter.build(for: [a, b, c])
        let scrambled = [c, a, b]

        let want1 = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: scrambled,
            localHaveItemIDs: [],
            peerMaxWant: 128
        )
        let want2 = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: scrambled,
            localHaveItemIDs: [],
            peerMaxWant: 128
        )

        XCTAssertEqual(want1, [a, b, c])
        XCTAssertEqual(want2, [a, b, c])
    }

    func testReconciliationBloomMayFalsePositive_requestsAreAllowed() throws {
        // Bloom filters can yield false positives. The receiver may request an ID even if the peer
        // does not actually have it; this is acceptable per encounter.md §8.1.
        let maybe = try GossipV1ItemID(bytes: Data(repeating: 0xAA, count: 32))

        // An all-ones bloom will report "might contain" for any ID.
        let peerBloom = Data(repeating: 0xFF, count: GossipV1.BLOOM_FILTER_BYTES)

        let want = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: [maybe],
            localHaveItemIDs: [],
            peerMaxWant: 128
        )

        XCTAssertEqual(want, [maybe])
    }

    func testReconciliationTruncation_respectsPeerMaxWant_andGlobalMaxWantItems() throws {
        // Make 10 deterministic IDs with increasing first byte so ordering is unambiguous.
        let ids: [GossipV1ItemID] = try (0..<10).map { i in
            var bytes = Data(repeating: 0, count: 32)
            bytes[0] = UInt8(i)
            return try GossipV1ItemID(bytes: bytes)
        }

        let peerBloom = GossipV1BloomFilter.build(for: ids)
        let scrambled = Array(ids.reversed())

        let peerMaxWant = 3
        let want = try GossipV1SummaryReconciliation.computeWant(
            bloomFilterBytes: peerBloom,
            candidateItemIDs: scrambled,
            localHaveItemIDs: [],
            peerMaxWant: peerMaxWant
        )

        let expectedSorted = ids.sorted(by: {
            DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending
        })
        XCTAssertEqual(want, Array(expectedSorted.prefix(peerMaxWant)))
    }

    func testReconciliationTruncation_peerMaxWantAboveGlobalMax_isCapped() throws {
        // Create > MAX_WANT_ITEMS deterministic IDs with a total ordering.
        let ids: [GossipV1ItemID] = try (0..<(GossipV1.MAX_WANT_ITEMS + 10)).map { i in
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

        XCTAssertEqual(want.count, GossipV1.MAX_WANT_ITEMS)
        XCTAssertEqual(
            want,
            ids.sorted(by: { DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending })
                .prefix(GossipV1.MAX_WANT_ITEMS)
                .map { $0 }
        )
    }
}
