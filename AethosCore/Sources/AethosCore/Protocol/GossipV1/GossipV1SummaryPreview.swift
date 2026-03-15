import Foundation

/// Deterministic SUMMARY preview pagination helper.
internal enum GossipV1SummaryPreview {
    static func generate(
        eligibleSorted: [GossipV1ItemID],
        startAfter: GossipV1ItemID?
    ) -> (preview: [GossipV1ItemID], cursor: GossipV1ItemID?) {
        let normalizedEligible = normalizedSortedUnique(eligibleSorted)
        guard !normalizedEligible.isEmpty else {
            return (preview: [], cursor: nil)
        }

        let startIndex: Int
        if let startAfter {
            startIndex = firstIndexStrictlyGreater(than: startAfter, in: normalizedEligible)
        } else {
            startIndex = 0
        }

        guard startIndex < normalizedEligible.count else {
            return (preview: [], cursor: nil)
        }

        let endIndex = min(startIndex + GossipV1.MAX_SUMMARY_PREVIEW_ITEMS, normalizedEligible.count)
        let preview = Array(normalizedEligible[startIndex..<endIndex])
        guard endIndex < normalizedEligible.count else {
            return (preview: preview, cursor: nil)
        }
        return (preview: preview, cursor: preview.last)
    }

    private static func normalizedSortedUnique(_ ids: [GossipV1ItemID]) -> [GossipV1ItemID] {
        guard ids.count >= 2 else { return ids }

        var isSorted = true
        for i in 1..<ids.count {
            if compare(ids[i - 1], ids[i]) == .orderedDescending {
                isSorted = false
                break
            }
        }

        let sortedIDs: [GossipV1ItemID]
        if isSorted {
            sortedIDs = ids
        } else {
            sortedIDs = ids.sorted(by: { compare($0, $1) == .orderedAscending })
        }

        var deduplicated: [GossipV1ItemID] = []
        deduplicated.reserveCapacity(sortedIDs.count)
        for id in sortedIDs {
            if let last = deduplicated.last, compare(last, id) == .orderedSame {
                continue
            }
            deduplicated.append(id)
        }
        return deduplicated
    }

    private static func firstIndexStrictlyGreater(than cursor: GossipV1ItemID, in ids: [GossipV1ItemID]) -> Int {
        var low = 0
        var high = ids.count

        while low < high {
            let mid = low + (high - low) / 2
            if compare(ids[mid], cursor) == .orderedDescending {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    private static func compare(_ lhs: GossipV1ItemID, _ rhs: GossipV1ItemID) -> ComparisonResult {
        DataLexicographic.compare(lhs.rawBytes(), rhs.rawBytes())
    }
}
