import Foundation

/// Namespace for Canonical CBOR shared types.
enum CanonicalCBOR {
    enum Error: Swift.Error, Equatable {
        case duplicateMapKey
    }
}
