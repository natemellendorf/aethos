import Foundation

/// Byte-level ordering helpers.
enum DataLexicographic {
    /// Bytewise lexicographic compare.
    ///
    /// If all compared bytes are equal, shorter data sorts first.
    static func compare(_ lhs: Data, _ rhs: Data) -> ComparisonResult {
        let m = min(lhs.count, rhs.count)
        if m > 0 {
            for i in 0..<m {
                let lb = lhs[lhs.startIndex + i]
                let rb = rhs[rhs.startIndex + i]
                if lb != rb { return lb < rb ? .orderedAscending : .orderedDescending }
            }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }

    /// RFC 8949 deterministic map key ordering.
    ///
    /// Compare by encoded byte length first, then bytewise lexicographic.
    static func compareLengthFirstThenLexicographic(_ lhs: Data, _ rhs: Data) -> ComparisonResult {
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        return compare(lhs, rhs)
    }
}
