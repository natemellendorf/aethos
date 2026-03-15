import Foundation

public enum GossipV1ReconciliationError: Error, Equatable, Sendable {
    case invalidBloomByteCount(expected: Int, actual: Int)
    case invalidPeerMaxWant
}

/// Deterministic SUMMARY→REQUEST reconciliation helper.
///
/// Spec references:
/// - `docs/protocol/encounter.md` §8.1
/// - `docs/protocol/frames.md` REQUEST ordering rule
///
/// - Important: This helper is pure computation only. It does not interact with the encounter
///   state machine and performs no I/O.
public enum GossipV1Reconciliation {
    /// Computes a deterministic REQUEST.want list from a peer SUMMARY bloom filter.
    ///
    /// The output is:
    /// - includes only items the peer bloom indicates it might contain,
    /// - excludes items already present in `localHaveItemIDs` (candidate set may include local-have IDs; they are filtered out),
    /// - sorted by bytewise lexicographic order of decoded digest bytes,
    /// - de-duplicated,
    /// - truncated to `min(peerMaxWant, GossipV1.MAX_WANT_ITEMS)`.
    public static func computeWant(
        bloomFilterBytes: Data,
        candidateItemIDs: [GossipV1ItemID],
        peerPreviewItemIDs: [GossipV1ItemID] = [],
        localHaveItemIDs: Set<GossipV1ItemID>,
        peerMaxWant: UInt64
    ) throws -> [GossipV1ItemID] {
        let semanticPeerMaxWantCap = UInt64(GossipV1.MAX_WANT_ITEMS)
        let boundedPeerMaxWant = min(peerMaxWant, semanticPeerMaxWantCap)
        let clampedPeerMaxWant = Int(min(boundedPeerMaxWant, UInt64(Int.max)))

        do {
            return try GossipV1SummaryReconciliation.computeWant(
                bloomFilterBytes: bloomFilterBytes,
                candidateItemIDs: candidateItemIDs,
                peerPreviewItemIDs: peerPreviewItemIDs,
                localHaveItemIDs: localHaveItemIDs,
                peerMaxWant: clampedPeerMaxWant
            )
        } catch let error as GossipV1FrameError {
            switch error {
            case .invalidBloomByteCount(let expected, let actual):
                throw GossipV1ReconciliationError.invalidBloomByteCount(expected: expected, actual: actual)
            case .invalidRange(let field) where field == "max_want":
                throw GossipV1ReconciliationError.invalidPeerMaxWant
            default:
                assertionFailure("Unexpected GossipV1FrameError mapped to invalidPeerMaxWant: \(error)")
                throw GossipV1ReconciliationError.invalidPeerMaxWant
            }
        }
    }
}

/// Deterministic SUMMARY→REQUEST reconciliation helper.
///
/// Spec references:
/// - `docs/protocol/encounter.md` §8.1
/// - `docs/protocol/frames.md` REQUEST ordering rule
///
/// - Important: This helper is pure computation only. It does not interact with the encounter
///   state machine and performs no I/O.
internal enum GossipV1SummaryReconciliation {
    static func computeWant(
        bloomFilterBytes: Data,
        candidateItemIDs: [GossipV1ItemID],
        peerPreviewItemIDs: [GossipV1ItemID] = [],
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
            throw GossipV1FrameError.invalidRange(field: "max_want")
        }

        let maxItems = min(peerMaxWant, GossipV1.MAX_WANT_ITEMS)
        guard maxItems > 0 else { return [] }

        let previewUnknown = peerPreviewItemIDs.lazy
            .filter { !localHaveItemIDs.contains($0) }

        // Filter candidates to only items we don't already have and the peer bloom might contain.
        // `candidateItemIDs` may include local-have IDs; we filter them out deterministically.
        let bloomFiltered = candidateItemIDs
            .lazy
            .filter { !localHaveItemIDs.contains($0) }
            .filter { GossipV1BloomFilter.mightContain($0, bloom: bloomFilterBytes) }
        let prioritizedCombined = Array(previewUnknown) + Array(bloomFiltered)
        let sortedCombined = prioritizedCombined.sorted(by: {
            DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending
        })

        // Deterministically de-duplicate (REQUEST forbids duplicates).
        var out: [GossipV1ItemID] = []
        out.reserveCapacity(min(candidateItemIDs.count + peerPreviewItemIDs.count, maxItems))

        var last: GossipV1ItemID?
        for id in sortedCombined {
            if id == last { continue }
            out.append(id)
            last = id
            if out.count == maxItems { break }
        }
        return out
    }
}
