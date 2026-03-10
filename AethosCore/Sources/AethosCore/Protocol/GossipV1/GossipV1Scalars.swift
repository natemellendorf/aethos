import Foundation

/// Lowercase hex SHA-256 digest scalar utilities for gossip v1.
///
/// Both `item_id` and `node_id` share the same encoding: `[0-9a-f]{64}`.
enum GossipV1Scalars {
    private static let digestByteCount = 32
    private static let digestHexChars = 64

    static func isValidLowercaseHexDigest(_ s: String) -> Bool {
        let bytes = s.utf8
        guard bytes.count == digestHexChars else { return false }
        for c in bytes {
            switch c {
            case 48...57, 97...102: // 0-9, a-f
                continue
            default:
                return false
            }
        }
        return true
    }

    static func decodeLowercaseHexDigest(_ s: String) throws -> Data {
        let bytes = Array(s.utf8)
        guard bytes.count == digestHexChars else {
            throw GossipV1Error.invalidHexDigest(expectedChars: digestHexChars, actualChars: bytes.count)
        }

        func nybble(_ c: UInt8) throws -> UInt8 {
            switch c {
            case 48...57: return c - 48 // 0-9
            case 97...102: return c - 87 // a-f
            default: throw GossipV1Error.invalidHexCharacter
            }
        }

        var out = Data()
        out.reserveCapacity(digestByteCount)
        var i = 0
        while i < bytes.count {
            let hi = try nybble(bytes[i])
            let lo = try nybble(bytes[i + 1])
            out.append((hi << 4) | lo)
            i += 2
        }

        guard out.count == digestByteCount else {
            throw GossipV1Error.invalidDigestByteCount(expected: digestByteCount, actual: out.count)
        }
        return out
    }
}

public struct GossipV1ItemID: Hashable, Sendable {
    // Internal representation is fixed 32 bytes (SHA-256).
    internal let bytes: Data

    /// Raw SHA-256 digest bytes.
    ///
    /// Prefer `hex` for human-facing usage.
    public func rawBytes() -> Data { bytes }

    public var hex: String {
        // Hex.encode is lowercase by construction.
        Hex.encode(bytes)
    }

    public init(hex: String) throws {
        self.bytes = try GossipV1Scalars.decodeLowercaseHexDigest(hex)
    }

    public init(bytes: Data) throws {
        guard bytes.count == 32 else {
            throw GossipV1Error.invalidDigestByteCount(expected: 32, actual: bytes.count)
        }
        self.bytes = bytes
    }

    internal init(unsafeDigestBytes bytes: Data) {
        assert(bytes.count == 32, "SHA-256 must be 32 bytes")
        self.bytes = bytes
    }

    public static func derive(fromEnvelopeBytes envelopeBytes: Data) -> GossipV1ItemID {
        GossipV1ItemID(unsafeDigestBytes: AethosIDs.sha256(envelopeBytes))
    }
}

public struct GossipV1NodeID: Hashable, Sendable {
    // Internal representation is fixed 32 bytes (SHA-256).
    internal let bytes: Data

    /// Raw SHA-256 digest bytes.
    ///
    /// Prefer `hex` for human-facing usage.
    public func rawBytes() -> Data { bytes }

    public var hex: String {
        Hex.encode(bytes)
    }

    public init(hex: String) throws {
        self.bytes = try GossipV1Scalars.decodeLowercaseHexDigest(hex)
    }

    public init(bytes: Data) throws {
        guard bytes.count == 32 else {
            throw GossipV1Error.invalidDigestByteCount(expected: 32, actual: bytes.count)
        }
        self.bytes = bytes
    }

    internal init(unsafeDigestBytes bytes: Data) {
        assert(bytes.count == 32, "SHA-256 must be 32 bytes")
        self.bytes = bytes
    }

    public static func derive(fromPublicKeyRawBytes publicKeyRawBytes: Data) -> GossipV1NodeID {
        GossipV1NodeID(unsafeDigestBytes: AethosIDs.sha256(publicKeyRawBytes))
    }
}
