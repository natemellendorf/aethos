import Foundation

#if DEBUG
/// Deterministic SUMMARY→REQUEST reconciliation helper.
///
/// Spec references:
/// - `docs/protocol/encounter.md` §8.1
/// - `docs/protocol/frames.md` REQUEST ordering rule
///
/// - Important: This helper is pure computation only. It does not interact with the encounter
///   state machine and performs no I/O.
internal enum GossipV1SummaryReconciliation {
    /// Computes a deterministic REQUEST.want list from a peer SUMMARY bloom filter.
    ///
    /// The output is:
    /// - includes only items the peer bloom indicates it might contain,
    /// - excludes items already present in `localHaveItemIDs` (candidate set MUST NOT include local-have, but we guard anyway),
    /// - sorted by bytewise lexicographic order of decoded digest bytes,
    /// - de-duplicated,
    /// - truncated to `min(peerMaxWant, GossipV1.MAX_WANT_ITEMS)`.
    internal static func computeWant(
        bloomFilterBytes: Data,
        candidateItemIDs: [GossipV1ItemID],
        localHaveItemIDs: Set<GossipV1ItemID>,
        peerMaxWant: Int
    ) throws -> [GossipV1ItemID] {
        guard bloomFilterBytes.count == GossipV1.BLOOM_FILTER_BYTES else {
            throw GossipV1FrameError.invalidBloomByteCount(
                expected: GossipV1.BLOOM_FILTER_BYTES,
                actual: bloomFilterBytes.count
            )
        }
        guard peerMaxWant >= 0 else {
            // Peer max_want is validated at the encounter boundary; guard here for test harnesses.
            throw GossipV1FrameError.invalidRange(field: "max_want")
        }

        let maxItems = min(peerMaxWant, GossipV1.MAX_WANT_ITEMS)
        guard maxItems > 0 else { return [] }

        // Filter candidates to only items we don't already have and the peer bloom might contain.
        // Per spec, `candidateItemIDs` MUST NOT include local-have IDs; we still filter to make
        // this helper resilient for test harnesses.
        let filtered = candidateItemIDs
            .lazy
            .filter { !localHaveItemIDs.contains($0) }
            .filter { GossipV1BloomFilter.mightContain($0, bloom: bloomFilterBytes) }
            .sorted(by: { DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending })

        // Deterministically de-duplicate (REQUEST forbids duplicates).
        var out: [GossipV1ItemID] = []
        out.reserveCapacity(min(candidateItemIDs.count, maxItems))

        var last: GossipV1ItemID?
        for id in filtered {
            if id == last { continue }
            out.append(id)
            last = id
            if out.count == maxItems { break }
        }
        return out
    }
}
#endif
