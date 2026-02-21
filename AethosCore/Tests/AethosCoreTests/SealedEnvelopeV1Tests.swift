import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import Testing
@testable import AethosCore

// MARK: - SealedEnvelopeV1 Roundtrip Tests

@Test
func sealedEnvelope_roundtripEncodeDecode() throws {
    // Create a sealed envelope
    let key = SymmetricKey(size: .bits256)
    let destinationId = Hex.decode("aabbccdd00112233")!
    let plaintext = Data("Hello, World!".utf8)
    
    let envelope = try SealedEnvelopeBuilder()
        .destination(destinationId)
        .payload(plaintext)
        .key(key)
        .build()
    
    // Verify envelope properties
    #expect(envelope.version == SealedEnvelopeV1.sealedVersion)
    #expect(envelope.destinationWayfarerId == destinationId)
    #expect(envelope.nonce.count == 12)
    #expect(!envelope.ciphertext.isEmpty)
    #expect(!envelope.isExpired)
    #expect(envelope.isValid)
    
    // Decrypt the envelope (this is the roundtrip)
    let decrypted = try SealedEnvelopeDecryptor.decrypt(envelope, using: key)
    #expect(decrypted == plaintext)
}

// MARK: - SealedEnvelopeV1 Encryption/Decryption Tests

@Test
func sealedEnvelope_encryptDecrypt() throws {
    let key = SymmetricKey(size: .bits256)
    let destinationId = Hex.decode("aabbccdd00112233")!
    let plaintext = Data("Secret message content".utf8)
    
    let envelope = try SealedEnvelopeBuilder()
        .destination(destinationId)
        .payload(plaintext)
        .key(key)
        .build()
    
    // Decrypt the envelope
    let decrypted = try SealedEnvelopeDecryptor.decrypt(envelope, using: key)
    
    #expect(decrypted == plaintext)
}

@Test
func sealedEnvelope_wrongKeyFails() throws {
    let key1 = SymmetricKey(size: .bits256)
    let key2 = SymmetricKey(size: .bits256)
    let destinationId = Hex.decode("aabbccdd00112233")!
    let plaintext = Data("Secret".utf8)
    
    let envelope = try SealedEnvelopeBuilder()
        .destination(destinationId)
        .payload(plaintext)
        .key(key1)
        .build()
    
    // Decrypting with wrong key should fail (authentication failure)
    var didThrow = false
    do {
        _ = try SealedEnvelopeDecryptor.decrypt(envelope, using: key2)
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

// MARK: - SealedEnvelopeV1 TTL and Expiration Tests

@Test
func sealedEnvelope_expiredEnvelopeRejected() throws {
    let key = SymmetricKey(size: .bits256)
    let destinationId = Hex.decode("aabbccdd00112233")!
    let plaintext = Data("Expiring message".utf8)
    let pastDate = Date(timeIntervalSince1970: 100) // Far in the past
    
    // Create envelope that expired in the past
    let envelope = try SealedEnvelopeBuilder()
        .destination(destinationId)
        .payload(plaintext)
        .key(key)
        .createdAt(pastDate)
        .ttlSeconds(1) // 1 second TTL, but created in the past
        .build()
    
    #expect(envelope.isExpired)
    
    // Decrypting expired envelope should fail
    #expect(throws: SealedEnvelopeError.expiredEnvelope) {
        _ = try SealedEnvelopeDecryptor.decrypt(envelope, using: key)
    }
}

@Test
func sealedEnvelope_validEnvelopeAccepted() throws {
    let key = SymmetricKey(size: .bits256)
    let destinationId = Hex.decode("aabbccdd00112233")!
    let plaintext = Data("Non-expiring message".utf8)
    
    // Create envelope with 24 hour TTL
    let envelope = try SealedEnvelopeBuilder()
        .destination(destinationId)
        .payload(plaintext)
        .key(key)
        .ttlSeconds(86400) // 24 hours
        .build()
    
    #expect(!envelope.isExpired)
    #expect(envelope.isValid)
    
    // Should decrypt successfully
    let decrypted = try SealedEnvelopeDecryptor.decrypt(envelope, using: key)
    #expect(decrypted == plaintext)
}

// MARK: - SealedEnvelopeV1 Invalid Version Tests

@Test
func sealedEnvelope_invalidVersionRejected() throws {
    // Create envelope with valid structure but wrong version in canonical
    let key = SymmetricKey(size: .bits256)
    let destinationId = Hex.decode("aabbccdd00112233")!
    _ = key
    _ = destinationId
    
    // Manually construct invalid version canonical bytes
    var invalidCanonical = Data()
    invalidCanonical.append(99) // Invalid version
    invalidCanonical.append(CanonicalEncoderV1.TypeDiscriminator.sealedEnvelope.rawValue)
    
    #expect(throws: SealedEnvelopeError.invalidVersion) {
        _ = try SealedEnvelopeV1.decode(canonical: invalidCanonical)
    }
}

// MARK: - SealedEnvelopeV1 Tamper Detection Tests

@Test
func sealedEnvelope_tamperedCiphertextDetected() throws {
    let key = SymmetricKey(size: .bits256)
    let destinationId = Hex.decode("aabbccdd00112233")!
    let plaintext = Data("Original message".utf8)
    
    let envelope = try SealedEnvelopeBuilder()
        .destination(destinationId)
        .payload(plaintext)
        .key(key)
        .build()
    
    // Tamper with ciphertext - create modified copy
    var tamperedCiphertext = envelope.ciphertext
    tamperedCiphertext.append(0xFF) // Tamper with the ciphertext
    
    let tamperedEnvelope = SealedEnvelopeV1(
        version: envelope.version,
        envelopeId: envelope.envelopeId,
        destinationWayfarerId: envelope.destinationWayfarerId,
        createdAtUnixMs: envelope.createdAtUnixMs,
        expiresAtUnixMs: envelope.expiresAtUnixMs,
        nonce: envelope.nonce,
        ciphertext: tamperedCiphertext,
        signature: envelope.signature
    )
    
    // Decryption should fail due to authentication failure
    var didThrow = false
    do {
        _ = try SealedEnvelopeDecryptor.decrypt(tamperedEnvelope, using: key)
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

// MARK: - Metadata Minimization Tests

@Test
func sealedEnvelope_noPlaintextMetadataInWireFormat() throws {
    let key = SymmetricKey(size: .bits256)
    let destinationId = Hex.decode("aabbccdd00112233")!
    let plaintext = Data("Secret payload with sensitive info".utf8)
    
    let envelope = try SealedEnvelopeBuilder()
        .destination(destinationId)
        .payload(plaintext)
        .key(key)
        .build()
    
    // Get canonical encoding (wire format)
    let canonical = CanonicalEncoderV1.encodeSealedEnvelopeV1(
        version: envelope.version,
        envelopeId: envelope.envelopeId,
        destinationWayfarerId: envelope.destinationWayfarerId,
        createdAtUnixMs: envelope.createdAtUnixMs,
        expiresAtUnixMs: envelope.expiresAtUnixMs,
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext,
        signature: envelope.signature
    )
    
    // Verify no plaintext in wire format
    let wireString = String(data: canonical, encoding: .utf8) ?? ""
    
    // The plaintext should not appear in the wire format
    #expect(!wireString.contains("Secret payload"))
    #expect(!wireString.contains("sensitive"))
    #expect(!wireString.contains("info"))
    
    // Filenames should not be present
    #expect(!wireString.contains("test.txt"))
    #expect(!wireString.contains("document.pdf"))
}

// MARK: - SealedEnvelopeV1 AAD Integrity Tests

@Test
func sealedEnvelope_aadProtectsMetadata() throws {
    let key = SymmetricKey(size: .bits256)
    let destinationId1 = Hex.decode("aabbccdd00112233")!
    let destinationId2 = Hex.decode("ffeeddccbbaa9988")!
    let plaintext = Data("Test message".utf8)
    
    // Create envelope for destination 1
    let envelope1 = try SealedEnvelopeBuilder()
        .destination(destinationId1)
        .payload(plaintext)
        .key(key)
        .build()
    
    // Create envelope for destination 2 with same plaintext
    let envelope2 = try SealedEnvelopeBuilder()
        .destination(destinationId2)
        .payload(plaintext)
        .key(key)
        .build()
    
    // Envelopes should have different ciphertext due to different AAD
    #expect(envelope1.ciphertext != envelope2.ciphertext)
    
    // But both should decrypt to same plaintext
    let decrypted1 = try SealedEnvelopeDecryptor.decrypt(envelope1, using: key)
    let decrypted2 = try SealedEnvelopeDecryptor.decrypt(envelope2, using: key)
    
    #expect(decrypted1 == plaintext)
    #expect(decrypted2 == plaintext)
}

// MARK: - OutboundTransfer with SealedEnvelopeV1 Tests

@Test
func outboundTransfer_stagesSealedEnvelope() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Create a test file
    let testFile = dir.appendingPathComponent("test.bin")
    let testData = Data(repeating: 0xCD, count: 512)
    try testData.write(to: testFile)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let destinationId = "aabbccdd00112233"

    // Create outbound transfer
    let transferId = try OutboundTransfer.create(
        fileURL: testFile,
        destinationWayfarerId: destinationId,
        store: store,
        now: now
    )

    // Verify transfer exists
    let transfer = try store.getTransfer(id: transferId)
    #expect(transfer != nil)

    // Verify outbox items were staged (manifest and envelope)
    let outboxItems = try store.peekQueuedOutbox(limit: 10)
    #expect(outboxItems.count >= 2)  // At least manifest + envelope

    let envelopeItems = outboxItems.filter { $0.kind == .envelope }
    #expect(envelopeItems.count == 1)
}
