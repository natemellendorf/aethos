import Foundation

public struct IdentityV1: Codable, Equatable, Sendable {
    public let wayfarerId: Data
    public var shortId: String {
        Hex.encode(wayfarerId.prefix(8))
    }

    public let signingPublicKey: Data
    public let exchangePublicKey: Data

    public init(wayfarerId: Data, signingPublicKey: Data, exchangePublicKey: Data) {
        self.wayfarerId = wayfarerId
        self.signingPublicKey = signingPublicKey
        self.exchangePublicKey = exchangePublicKey
    }

    // MARK: - Self-certifying identity helpers

    /// The algorithm used for the signing keypair.
    /// Curve25519/Ed25519 chosen for compact 32-byte keys, fast signing,
    /// and wide CryptoKit/swift-crypto support on all Apple + Linux platforms.
    public static let keyType: String = "Ed25519"

    /// Hex-encoded signing public key (64 chars).
    public var signingPublicKeyHex: String {
        Hex.encode(signingPublicKey)
    }

    /// Hex-encoded exchange public key (64 chars).
    public var exchangePublicKeyHex: String {
        Hex.encode(exchangePublicKey)
    }

    /// Short fingerprint of the identity: first 8 bytes of wayfarerId as hex (16 chars).
    public var keyFingerprint: String {
        shortId
    }

    /// Verify that this identity is self-certifying: wayfarerId == SHA-256(signingPublicKey).
    public var isSelfCertifying: Bool {
        wayfarerId == AethosIDs.sha256(signingPublicKey)
    }

    /// Canonical representation of the public identity for wire use and verification.
    /// Format: [1 byte keyType tag][32 bytes signingPublicKey][32 bytes exchangePublicKey]
    /// This is stable and deterministic.
    public var canonicalPublicKeyBytes: Data {
        CanonicalEncoderV1.encodePublicIdentity(self)
    }
}
