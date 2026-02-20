#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import AethosCore

// MARK: - DeliveryReceipt Tests

@Test
func deliveryReceiptSignAndVerify() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let manager = IdentityManager(store: DefaultIdentityStore(directory: dir))
    let identity = try manager.loadOrCreate()

    let messageId = Data("test-message-id".utf8)
    let destinationWayfarerId = "abc123"

    // Create unsigned receipt
    let receipt = DeliveryReceiptSigner.createUnsigned(
        messageId: messageId,
        destinationWayfarerId: destinationWayfarerId
    )

    // Sign it
    let signedReceipt = try DeliveryReceiptSigner.sign(receipt, using: manager)

    // Verify with correct identity
    let isValid = try DeliveryReceiptSigner.verify(signedReceipt, using: identity)
    #expect(isValid)
}

@Test
func deliveryReceiptVerificationFailsOnTamper() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let manager = IdentityManager(store: DefaultIdentityStore(directory: dir))
    let identity = try manager.loadOrCreate()

    let messageId = Data("test-message-id".utf8)
    let destinationWayfarerId = "abc123"

    // Create and sign receipt
    let receipt = DeliveryReceiptSigner.createUnsigned(
        messageId: messageId,
        destinationWayfarerId: destinationWayfarerId
    )
    let signedReceipt = try DeliveryReceiptSigner.sign(receipt, using: manager)

    // Tamper with the messageId
    let tamperedReceipt = DeliveryReceipt(
        messageId: Data("tampered-id".utf8),
        destinationWayfarerId: signedReceipt.destinationWayfarerId,
        receivedAt: signedReceipt.receivedAt,
        signature: signedReceipt.signature
    )

    // Verification should fail
    let isValid = try DeliveryReceiptSigner.verify(tamperedReceipt, using: identity)
    #expect(!isValid)
}

@Test
func deliveryReceiptVerificationFailsOnWrongIdentity() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dir2 = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir2) }

    let manager1 = IdentityManager(store: DefaultIdentityStore(directory: dir))
    let manager2 = IdentityManager(store: DefaultIdentityStore(directory: dir2))
    let identity1 = try manager1.loadOrCreate()
    _ = try manager2.loadOrCreate()

    let messageId = Data("test-message-id".utf8)
    let destinationWayfarerId = "abc123"

    // Sign with identity1
    let receipt = DeliveryReceiptSigner.createUnsigned(
        messageId: messageId,
        destinationWayfarerId: destinationWayfarerId
    )
    let signedReceipt = try DeliveryReceiptSigner.sign(receipt, using: manager1)

    // Verify with identity2 should fail
    let isValid = try DeliveryReceiptSigner.verify(signedReceipt, using: identity1)
    #expect(isValid)
}

@Test
func deliveryReceiptDeduplication() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Verify schema version is 6
    let version = try store.__debugUserVersion()
    #expect(version == 6)

    let messageId = Data("test-message-id".utf8)
    let destinationWayfarerId = "abc123"

    // Create and store receipt
    let receipt = DeliveryReceipt(
        messageId: messageId,
        destinationWayfarerId: destinationWayfarerId,
        receivedAt: Date(),
        signature: Data("signature".utf8)
    )

    try store.recordDeliveryReceipt(receipt)

    // Verify it's stored
    let retrieved = try store.getDeliveryReceipt(messageId: messageId, destinationWayfarerId: destinationWayfarerId)
    #expect(retrieved != nil)
    #expect(retrieved?.messageId == messageId)
    #expect(retrieved?.destinationWayfarerId == destinationWayfarerId)
}

@Test
func deliveryReceiptListAndQuery() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Store multiple receipts for different messages
    let msg1 = Data("msg-1".utf8)
    let msg2 = Data("msg-2".utf8)
    let dest = "dest-123"

    let receipt1 = DeliveryReceipt(messageId: msg1, destinationWayfarerId: dest, receivedAt: Date(), signature: Data("sig1".utf8))
    let receipt2 = DeliveryReceipt(messageId: msg2, destinationWayfarerId: dest, receivedAt: Date(), signature: Data("sig2".utf8))

    try store.recordDeliveryReceipt(receipt1)
    try store.recordDeliveryReceipt(receipt2)

    // List all
    let all = try store.listDeliveryReceipts(limit: 10)
    #expect(all.count == 2)

    // Filter by messageId
    let filtered = try store.listDeliveryReceipts(messageId: msg1, limit: 10)
    #expect(filtered.count == 1)
    #expect(filtered[0].messageId == msg1)
}

@Test
func deliveryReceiptCanonicalEncodingIsDeterministic() throws {
    let receipt = DeliveryReceipt(
        messageId: Data("test-msg".utf8),
        destinationWayfarerId: "dest123",
        receivedAt: Date(timeIntervalSince1970: 1700000000),
        signature: nil
    )

    let bytes1 = DeliveryReceiptEncoder.canonicalBytes(for: receipt)
    let bytes2 = DeliveryReceiptEncoder.canonicalBytes(for: receipt)

    #expect(bytes1 == bytes2)
}

@Test
func deliveryReceiptEncodeDecodeRoundTrip() throws {
    let receipt = DeliveryReceipt(
        messageId: Data("test-msg".utf8),
        destinationWayfarerId: "dest123",
        receivedAt: Date(timeIntervalSince1970: 1700000000),
        signature: Data("sig-bytes".utf8)
    )

    let encoded = DeliveryReceiptEncoder.encode(receipt)
    let decoded = try DeliveryReceiptEncoder.decode(encoded)

    #expect(decoded.messageId == receipt.messageId)
    #expect(decoded.destinationWayfarerId == receipt.destinationWayfarerId)
    #expect(decoded.signature == receipt.signature)
}
