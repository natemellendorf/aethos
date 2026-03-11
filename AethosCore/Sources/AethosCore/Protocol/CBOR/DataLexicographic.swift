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

    /// RFC 8949 deterministic CBOR map key ordering (§4.2.1).
    ///
    /// Keys are sorted by the bytewise lexicographic order of their deterministic encodings.
    /// (This is *not* the RFC 7049 compatibility mode that compares by length first.)
    static func compareDeterministicEncodedKeyBytes(_ lhs: Data, _ rhs: Data) -> ComparisonResult {
        compare(lhs, rhs)
    }
}
