import Foundation

/// Canonical CBOR subset used by Aethos protocols.
///
/// Supported types align with the RFC 8949 deterministic encoding subset we enforce:
/// - Unsigned integers (major 0)
/// - Byte strings (major 2)
/// - Text strings (major 3)
/// - Arrays (major 4)
/// - Maps (major 5)
/// - Bool/null (major 7 simple values)
enum CanonicalCBORValue: Equatable, Sendable {
    struct MapEntry: Equatable, Sendable {
        let key: CanonicalCBORValue
        let value: CanonicalCBORValue

        init(key: CanonicalCBORValue, value: CanonicalCBORValue) {
            self.key = key
            self.value = value
        }
    }

    case unsigned(UInt64)
    case bytes(Data)
    case text(String)
    case array([CanonicalCBORValue])
    case map([MapEntry])
    case bool(Bool)
    case null

    static func == (lhs: CanonicalCBORValue, rhs: CanonicalCBORValue) -> Bool {
        switch (lhs, rhs) {
        case let (.unsigned(a), .unsigned(b)):
            return a == b
        case let (.bytes(a), .bytes(b)):
            return a == b
        case let (.text(a), .text(b)):
            return a == b
        case let (.array(a), .array(b)):
            return a == b
        case let (.bool(a), .bool(b)):
            return a == b
        case (.null, .null):
            return true

        case let (.map(a), .map(b)):
            return mapsEqualIgnoringEntryOrder(a, b)

        default:
            return false
        }
    }

    /// Maps are semantically unordered.
    ///
    /// Equality compares entries after sorting by the bytewise lexicographic
    /// order of each key's deterministic encoding (RFC 8949 §4.2.1).
    private static func mapsEqualIgnoringEntryOrder(_ lhs: [MapEntry], _ rhs: [MapEntry]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        // If keys are non-encodable (e.g. a map key contains duplicate keys),
        // treat values as not equal rather than attempting partial comparison.
        guard let l = canonicalizedEntriesForEquality(lhs) else { return false }
        guard let r = canonicalizedEntriesForEquality(rhs) else { return false }

        for i in 0..<l.count {
            if l[i].keyBytes != r[i].keyBytes { return false }
            if l[i].value != r[i].value { return false }
        }
        return true
    }

    private struct CanonicalizedEntry: Sendable {
        let keyBytes: Data
        let value: CanonicalCBORValue
    }

    private static func canonicalizedEntriesForEquality(_ entries: [MapEntry]) -> [CanonicalizedEntry]? {
        let encoder = CanonicalCBOREncoder()
        var out: [CanonicalizedEntry] = []
        out.reserveCapacity(entries.count)

        for e in entries {
            guard let keyBytes = try? encoder.encode(e.key) else { return nil }
            out.append(CanonicalizedEntry(keyBytes: keyBytes, value: e.value))
        }

        out.sort {
            DataLexicographic.compareDeterministicEncodedKeyBytes($0.keyBytes, $1.keyBytes) == .orderedAscending
        }

        // Duplicate keys make map semantics ambiguous; treat as unequal.
        if out.count >= 2 {
            for i in 1..<out.count {
                if out[i - 1].keyBytes == out[i].keyBytes { return nil }
            }
        }

        return out
    }
}
