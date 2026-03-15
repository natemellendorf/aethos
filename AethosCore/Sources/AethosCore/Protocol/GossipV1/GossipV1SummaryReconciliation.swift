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
    /// - prioritizes unknown peer preview IDs first (while still honoring bloom checks),
    /// - includes only items the peer bloom indicates it might contain,
    /// - excludes items already present in `localHaveItemIDs` (candidate set may include local-have IDs; they are filtered out),
    /// - deterministically selects candidate IDs in bytewise lexicographic order,
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
            .filter { GossipV1BloomFilter.mightContain($0, bloom: bloomFilterBytes) }
            .sorted(by: {
                DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending
            })

        // Filter candidates to only items we don't already have and the peer bloom might contain.
        // `candidateItemIDs` may include local-have IDs; we filter them out deterministically.
        let bloomFiltered = candidateItemIDs
            .lazy
            .filter { !localHaveItemIDs.contains($0) }
            .filter { GossipV1BloomFilter.mightContain($0, bloom: bloomFilterBytes) }
            .sorted(by: {
                DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending
            })

        // Deterministically select preview-unknown first, then fill from bloom-filtered candidates.
        var out: [GossipV1ItemID] = []
        out.reserveCapacity(min(candidateItemIDs.count + peerPreviewItemIDs.count, maxItems))

        var seen = Set<GossipV1ItemID>()
        seen.reserveCapacity(candidateItemIDs.count + peerPreviewItemIDs.count)

        for id in previewUnknown {
            guard seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count == maxItems { break }
        }

        if out.count < maxItems {
            for id in bloomFiltered {
                guard seen.insert(id).inserted else { continue }
                out.append(id)
                if out.count == maxItems { break }
            }
        }

        // REQUEST ordering must be bytewise lexicographic over decoded digest bytes.
        out.sort {
            DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending
        }
        return out
    }
}
