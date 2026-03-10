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

    // Initial implementation relies on synthesis; hardening refines map equality behavior.
}
