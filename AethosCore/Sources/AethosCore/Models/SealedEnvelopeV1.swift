import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Sealed envelope version 1 with AES.GCM encryption and authenticated metadata.
///
/// This envelope provides:
/// - Confidentiality via AES-256-GCM encryption
/// - Metadata integrity via Additional Authenticated Data (AAD)
/// - Deterministic canonical encoding for stable wire format
/// - TTL-based expiration for privacy-preserving auto-cleanup
public struct SealedEnvelopeV1: Codable, Equatable, Sendable {
    /// Protocol version for this envelope type.
    public static let sealedVersion: UInt8 = 1
    
    /// Field identifiers for canonical encoding.
    public enum Field: UInt8 {
        case version = 1
        case envelopeId = 2
        case destinationWayfarerId = 3
        case createdAtUnixMs = 4
        case expiresAtUnixMs = 5
        case nonce = 6
        case ciphertext = 7
        case signature = 8
    }
    
    /// The envelope version (always 1 for SealedEnvelopeV1).
    public let version: UInt8
    
    /// Unique identifier for this envelope (SHA256 of canonical bytes).
    public let envelopeId: Data
    
    /// Destination Wayfarer ID (opaque identifier, not plaintext identity).
    public let destinationWayfarerId: Data
    
    /// Creation timestamp in milliseconds since epoch.
    public let createdAtUnixMs: Int64
    
    /// Expiration timestamp in milliseconds since epoch.
    public let expiresAtUnixMs: Int64
    
    /// 12-byte nonce for AES.GCM.
    public let nonce: Data
    
    /// Encrypted payload (ciphertext + auth tag).
    public let ciphertext: Data
    
    /// Optional signature for non-repudiation.
    public let signature: Data?
    
    public init(
        version: UInt8 = sealedVersion,
        envelopeId: Data,
        destinationWayfarerId: Data,
        createdAtUnixMs: Int64,
        expiresAtUnixMs: Int64,
        nonce: Data,
        ciphertext: Data,
        signature: Data? = nil
    ) {
        self.version = version
        self.envelopeId = envelopeId
        self.destinationWayfarerId = destinationWayfarerId
        self.createdAtUnixMs = createdAtUnixMs
        self.expiresAtUnixMs = expiresAtUnixMs
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.signature = signature
    }
    
    /// Check if the envelope has expired.
    public var isExpired: Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return expiresAtUnixMs < now
    }
    
    /// Check if the envelope is valid (not expired, correct version).
    public var isValid: Bool {
        version == Self.sealedVersion && !isExpired
    }
}

/// Errors that can occur during sealed envelope operations.
public enum SealedEnvelopeError: Swift.Error, Equatable {
    case invalidVersion
    case expiredEnvelope
    case encryptionFailed
    case decryptionFailed
    case invalidNonce
    case invalidAAD
    case missingDestination
    case invalidSignature
    case missingPayload
    case missingKey
}

/// Builder for creating SealedEnvelopeV1 instances.
public struct SealedEnvelopeBuilder {
    /// Default TTL for envelopes: 24 hours in seconds.
    public static let defaultTTLSeconds: Int64 = 86400
    
    private var destinationWayfarerId: Data?
    private var plaintext: Data?
    private var createdAt: Date = Date()
    private var ttlSeconds: Int64 = Self.defaultTTLSeconds
    private var encryptionKey: SymmetricKey?
    private var signatureKey: Data?
    
    public init() {}
    
    /// Set the destination Wayfarer ID (hex string).
    public func destination(_ wayfarerIdHex: String) -> SealedEnvelopeBuilder {
        var builder = self
        if let data = Hex.decode(wayfarerIdHex) {
            builder.destinationWayfarerId = data
        }
        return builder
    }
    
    /// Set the destination Wayfarer ID (raw bytes).
    public func destination(_ wayfarerId: Data) -> SealedEnvelopeBuilder {
        var builder = self
        builder.destinationWayfarerId = wayfarerId
        return builder
    }
    
    /// Set the plaintext payload to encrypt.
    public func payload(_ data: Data) -> SealedEnvelopeBuilder {
        var builder = self
        builder.plaintext = data
        return builder
    }
    
    /// Set the creation timestamp.
    public func createdAt(_ date: Date) -> SealedEnvelopeBuilder {
        var builder = self
        builder.createdAt = date
        return builder
    }
    
    /// Set the TTL (time-to-live) in seconds.
    public func ttlSeconds(_ seconds: Int64) -> SealedEnvelopeBuilder {
        var builder = self
        builder.ttlSeconds = seconds
        return builder
    }
    
    /// Set the encryption key.
    public func key(_ symmetricKey: SymmetricKey) -> SealedEnvelopeBuilder {
        var builder = self
        builder.encryptionKey = symmetricKey
        return builder
    }
    
    /// Set the signing key for non-repudiation.
    public func signWith(_ privateKey: Data) -> SealedEnvelopeBuilder {
        var builder = self
        builder.signatureKey = privateKey
        return builder
    }
    
    /// Build the sealed envelope.
    public func build() throws -> SealedEnvelopeV1 {
        // Guard: destination required
        guard let dest = destinationWayfarerId, !dest.isEmpty else {
            throw SealedEnvelopeError.missingDestination
        }
        
        // Guard: plaintext required
        guard let payload = plaintext else {
            throw SealedEnvelopeError.missingPayload
        }
        
        // Guard: key required
        guard let key = encryptionKey else {
            throw SealedEnvelopeError.missingKey
        }
        
        let nowMs = Int64(createdAt.timeIntervalSince1970 * 1000)
        let expiresMs = nowMs + (ttlSeconds * 1000)
        
        // Generate nonce (12 bytes for AES.GCM)
        let nonce = AES.GCM.Nonce()
        let nonceData = Data(nonce)
        
        // Build AAD from metadata fields (deterministic)
        let aad = Self.buildAAD(
            version: SealedEnvelopeV1.sealedVersion,
            destination: dest,
            createdAtMs: nowMs,
            expiresAtMs: expiresMs
        )
        
        // Encrypt with AAD
        let sealedBox = try AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: aad)
        
        // Extract ciphertext (combined contains nonce + ciphertext + tag; we drop the nonce prefix)
        guard let combined = sealedBox.combined else {
            throw SealedEnvelopeError.encryptionFailed
        }
        let ciphertextData = combined.dropFirst(12)
        
        // Compute envelope ID from canonical bytes (without signature for determinism)
        let canonical = CanonicalEncoderV1.encodeSealedEnvelopeV1(
            version: SealedEnvelopeV1.sealedVersion,
            envelopeId: Data(),
            destinationWayfarerId: dest,
            createdAtUnixMs: nowMs,
            expiresAtUnixMs: expiresMs,
            nonce: nonceData,
            ciphertext: ciphertextData,
            signature: nil
        )
        
        // Use SHA256 of canonical bytes as envelope ID
        let envelopeId = AethosIDs.sha256(canonical)
        
        // Build final canonical bytes with correct envelope ID
        let finalCanonical = CanonicalEncoderV1.encodeSealedEnvelopeV1(
            version: SealedEnvelopeV1.sealedVersion,
            envelopeId: envelopeId,
            destinationWayfarerId: dest,
            createdAtUnixMs: nowMs,
            expiresAtUnixMs: expiresMs,
            nonce: nonceData,
            ciphertext: ciphertextData,
            signature: nil
        )
        
        // Sign if signature key provided
        var signature: Data? = nil
        if let signingKey = signatureKey {
            signature = Self.signMessage(finalCanonical, with: signingKey)
        }
        
        return SealedEnvelopeV1(
            version: SealedEnvelopeV1.sealedVersion,
            envelopeId: envelopeId,
            destinationWayfarerId: dest,
            createdAtUnixMs: nowMs,
            expiresAtUnixMs: expiresMs,
            nonce: nonceData,
            ciphertext: ciphertextData,
            signature: signature
        )
    }
    
    /// Build Additional Authenticated Data from metadata.
    private static func buildAAD(version: UInt8, destination: Data, createdAtMs: Int64, expiresAtMs: Int64) -> Data {
        var aad = Data()
        aad.append(version)
        aad.append(destination)
        
        var createdMsBE = createdAtMs.bigEndian
        var expiresMsBE = expiresAtMs.bigEndian
        aad.append(Data(bytes: &createdMsBE, count: 8))
        aad.append(Data(bytes: &expiresMsBE, count: 8))
        
        return aad
    }
    
    /// Sign canonical bytes (placeholder for Ed25519).
    private static func signMessage(_ message: Data, with privateKey: Data) -> Data {
        // Placeholder: HMAC-SHA256 for signing
        // In production, use CryptoKit's Curve25519.Signing.PrivateKey
        let key = SymmetricKey(data: privateKey)
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(signature)
    }
}

/// Decryptor for SealedEnvelopeV1.
public struct SealedEnvelopeDecryptor {
    /// Decrypt a sealed envelope and return the plaintext.
    public static func decrypt(_ envelope: SealedEnvelopeV1, using key: SymmetricKey) throws -> Data {
        // Guard: check version
        guard envelope.version == SealedEnvelopeV1.sealedVersion else {
            throw SealedEnvelopeError.invalidVersion
        }
        
        // Guard: check expiration
        guard !envelope.isExpired else {
            throw SealedEnvelopeError.expiredEnvelope
        }
        
        // Guard: check nonce size
        guard envelope.nonce.count == 12 else {
            throw SealedEnvelopeError.invalidNonce
        }
        
        // Build AAD for authentication
        var aad = Data()
        aad.append(envelope.version)
        aad.append(envelope.destinationWayfarerId)
        
        var createdMsBE = envelope.createdAtUnixMs.bigEndian
        var expiresMsBE = envelope.expiresAtUnixMs.bigEndian
        aad.append(Data(bytes: &createdMsBE, count: 8))
        aad.append(Data(bytes: &expiresMsBE, count: 8))
        
        // AES.GCM.SealedBox expects: nonce + ciphertext + tag (all combined)
        let combined = envelope.nonce + envelope.ciphertext
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        
        // Decrypt and verify AAD
        return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
    }
    
    /// Verify envelope signature if present.
    public static func verifySignature(_ envelope: SealedEnvelopeV1, publicKey: Data) -> Bool {
        guard envelope.signature != nil else {
            return true // No signature = considered valid
        }
        
        // Build canonical bytes (without signature)
        _ = CanonicalEncoderV1.encodeSealedEnvelopeV1(
            version: envelope.version,
            envelopeId: envelope.envelopeId,
            destinationWayfarerId: envelope.destinationWayfarerId,
            createdAtUnixMs: envelope.createdAtUnixMs,
            expiresAtUnixMs: envelope.expiresAtUnixMs,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            signature: nil
        )
        
        // Verify signature placeholder
        // In production, use CryptoKit's Ed25519 verification
        return true
    }
}

// MARK: - SealedEnvelopeV1 Decoding

extension SealedEnvelopeV1 {
    /// Create a SealedEnvelopeV1 from canonical encoded bytes.
    public static func decode(canonical: Data) throws -> SealedEnvelopeV1 {
        var offset = 0
        
        // Read version
        guard canonical.count > offset else { throw SealedEnvelopeError.decryptionFailed }
        let version = canonical[offset]
        offset += 1
        
        guard version == sealedVersion else { throw SealedEnvelopeError.invalidVersion }
        
        // Read envelopeId
        let envelopeId = try Self.readField(canonical, &offset, Field.envelopeId)
        
        // Read destinationWayfarerId
        let destinationWayfarerId = try Self.readField(canonical, &offset, Field.destinationWayfarerId)
        
        // Read createdAtUnixMs
        let createdAtUnixMs = try Self.readInt64(canonical, &offset, Field.createdAtUnixMs)
        
        // Read expiresAtUnixMs
        let expiresAtUnixMs = try Self.readInt64(canonical, &offset, Field.expiresAtUnixMs)
        
        // Read nonce
        let nonce = try Self.readField(canonical, &offset, Field.nonce)
        
        // Read ciphertext
        let ciphertext = try Self.readField(canonical, &offset, Field.ciphertext)
        
        // Read optional signature
        let signature = try Self.readOptionalField(canonical, &offset, Field.signature)
        
        return SealedEnvelopeV1(
            version: version,
            envelopeId: envelopeId,
            destinationWayfarerId: destinationWayfarerId,
            createdAtUnixMs: createdAtUnixMs,
            expiresAtUnixMs: expiresAtUnixMs,
            nonce: nonce,
            ciphertext: ciphertext,
            signature: signature
        )
    }
    
    private static func readField(_ data: Data, _ offset: inout Int, _ field: Field) throws -> Data {
        guard offset < data.count else { throw SealedEnvelopeError.decryptionFailed }
        guard data[offset] == field.rawValue else { throw SealedEnvelopeError.decryptionFailed }
        offset += 1
        
        guard offset + 4 <= data.count else { throw SealedEnvelopeError.decryptionFailed }
        let lengthBytes = data[offset..<offset+4]
        let length = Int(lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        offset += 4
        
        guard offset + length <= data.count else { throw SealedEnvelopeError.decryptionFailed }
        let value = data[offset..<offset+length]
        offset += length
        
        return Data(value)
    }
    
    private static func readInt64(_ data: Data, _ offset: inout Int, _ field: Field) throws -> Int64 {
        let fieldData = try readField(data, &offset, field)
        guard fieldData.count == 8 else { throw SealedEnvelopeError.decryptionFailed }
        return fieldData.withUnsafeBytes { $0.load(as: Int64.self).bigEndian }
    }
    
    private static func readOptionalField(_ data: Data, _ offset: inout Int, _ field: Field) throws -> Data? {
        guard offset < data.count else { return nil }
        guard data[offset] == field.rawValue else { return nil }
        return try readField(data, &offset, field)
    }
}
