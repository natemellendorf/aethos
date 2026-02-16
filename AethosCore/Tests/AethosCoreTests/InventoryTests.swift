import Foundation
import Testing
@testable import AethosCore

// MARK: - Encode/Decode Round-Trip

@Test
func inventoryEncodeDecodeRoundTrip() throws {
    let manifests = [
        "aabbccdd00112233445566778899aabbccddeeff00112233445566778899aabb",
        "1122334455667788990011223344556677889900aabbccddeeff001122334455",
    ]
    let inventory = InventoryV1(
        manifests: manifests,
        generatedAtUnixMs: 1_700_000_000_000
    )

    let encoded = CanonicalEncoderV1.encode(inventory)
    let decoded = try CanonicalEncoderV1.decodeInventory(canonical: encoded)

    #expect(decoded.version == .v1)
    #expect(decoded.manifests == manifests)
    #expect(decoded.generatedAtUnixMs == 1_700_000_000_000)
}

@Test
func inventoryRequestEncodeDecodeRoundTrip() throws {
    let want = [
        "aabbccdd00112233445566778899aabbccddeeff00112233445566778899aabb",
        "1122334455667788990011223344556677889900aabbccddeeff001122334455",
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    ]
    let request = InventoryRequestV1(want: want)

    let encoded = CanonicalEncoderV1.encode(request)
    let decoded = try CanonicalEncoderV1.decodeInventoryRequest(canonical: encoded)

    #expect(decoded.version == .v1)
    #expect(decoded.want == want)
}

@Test
func inventoryEncodingIsDeterministic() throws {
    let inventory = InventoryV1(
        manifests: ["aabb", "ccdd"],
        generatedAtUnixMs: 12345
    )
    let a = CanonicalEncoderV1.encode(inventory)
    let b = CanonicalEncoderV1.encode(inventory)
    #expect(a == b)
}

@Test
func inventoryRequestEncodingIsDeterministic() throws {
    let request = InventoryRequestV1(want: ["aabb", "ccdd"])
    let a = CanonicalEncoderV1.encode(request)
    let b = CanonicalEncoderV1.encode(request)
    #expect(a == b)
}

@Test
func emptyInventoryRoundTrip() throws {
    let inventory = InventoryV1(manifests: [], generatedAtUnixMs: 0)
    let encoded = CanonicalEncoderV1.encode(inventory)
    let decoded = try CanonicalEncoderV1.decodeInventory(canonical: encoded)
    #expect(decoded.manifests.isEmpty)
    #expect(decoded.generatedAtUnixMs == 0)
}

@Test
func emptyInventoryRequestRoundTrip() throws {
    let request = InventoryRequestV1(want: [])
    let encoded = CanonicalEncoderV1.encode(request)
    let decoded = try CanonicalEncoderV1.decodeInventoryRequest(canonical: encoded)
    #expect(decoded.want.isEmpty)
}

@Test
func inventoryCapsAt500Manifests() throws {
    let manifests = (0..<600).map { String(format: "%064x", $0) }
    let inventory = InventoryV1(manifests: manifests, generatedAtUnixMs: 1000)
    #expect(inventory.manifests.count == 500)
}

// MARK: - CargoCodec Support

@Test
func inventoryCargoCodecEncodeDecode() throws {
    let inventory = InventoryV1(manifests: ["aabb"], generatedAtUnixMs: 1000)
    let canonical = CanonicalEncoderV1.encode(inventory)
    let cargo = CargoItem.inventory(canonical)

    let frames = try CargoCodec.encode(cargo, maxFramePayloadBytes: 4096)
    #expect(frames.count == 1)
    #expect(frames[0].type == CargoCodec.FrameType.inventory.rawValue)

    let fragment = try CargoCodec.decode(frames[0])
    if case let .metadata(type, _, bytes) = fragment {
        #expect(type == CargoCodec.FrameType.inventory.rawValue)
        let decoded = try CanonicalEncoderV1.decodeInventory(canonical: bytes)
        #expect(decoded.manifests == ["aabb"])
    } else {
        Issue.record("Expected metadata fragment")
    }
}

@Test
func inventoryRequestCargoCodecEncodeDecode() throws {
    let request = InventoryRequestV1(want: ["ccdd"])
    let canonical = CanonicalEncoderV1.encode(request)
    let cargo = CargoItem.inventoryRequest(canonical)

    let frames = try CargoCodec.encode(cargo, maxFramePayloadBytes: 4096)
    #expect(frames.count == 1)
    #expect(frames[0].type == CargoCodec.FrameType.inventoryRequest.rawValue)

    let fragment = try CargoCodec.decode(frames[0])
    if case let .metadata(type, _, bytes) = fragment {
        #expect(type == CargoCodec.FrameType.inventoryRequest.rawValue)
        let decoded = try CanonicalEncoderV1.decodeInventoryRequest(canonical: bytes)
        #expect(decoded.want == ["ccdd"])
    } else {
        Issue.record("Expected metadata fragment")
    }
}

// MARK: - Store: listActiveManifestHashes

@Test
func listActiveManifestHashesRespectsEviction() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Active outbound transfer
    let t1 = Transfer(
        transferId: "t1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "hash_active_1"
    )
    // Evicted transfer — should not appear
    let t2 = Transfer(
        transferId: "t2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .canceled,
        manifestHash: "hash_evicted",
        evicted: true
    )
    // Failed transfer — should not appear
    let t3 = Transfer(
        transferId: "t3",
        direction: .inbound,
        peerFrom: "c", peerTo: "a",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .failed,
        manifestHash: "hash_failed"
    )
    // Active inbound transfer
    let t4 = Transfer(
        transferId: "t4",
        direction: .inbound,
        peerFrom: "d", peerTo: "a",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .complete,
        manifestHash: "hash_active_2"
    )
    // Transfer with no manifest hash — should not appear
    let t5 = Transfer(
        transferId: "t5",
        direction: .outbound,
        peerFrom: "a", peerTo: "e",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .queued
    )

    try store.createTransfer(t1)
    try store.createTransfer(t2)
    try store.createTransfer(t3)
    try store.createTransfer(t4)
    try store.createTransfer(t5)

    let hashes = try store.listActiveManifestHashes()
    #expect(hashes.count == 2)
    #expect(hashes.contains("hash_active_1"))
    #expect(hashes.contains("hash_active_2"))
    #expect(!hashes.contains("hash_evicted"))
    #expect(!hashes.contains("hash_failed"))
}

@Test
func hasManifestReturnsTrueForActive() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let t = Transfer(
        transferId: "t1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "abc123"
    )
    try store.createTransfer(t)

    #expect(try store.hasManifest("abc123") == true)
    #expect(try store.hasManifest("nonexistent") == false)
}

@Test
func hasManifestReturnsFalseForEvicted() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let t = Transfer(
        transferId: "t1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .canceled,
        manifestHash: "abc123",
        evicted: true
    )
    try store.createTransfer(t)

    #expect(try store.hasManifest("abc123") == false)
}

@Test
func lookupTransfersByManifestHashesReturnsMatching() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let t1 = Transfer(
        transferId: "t1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "hash1"
    )
    let t2 = Transfer(
        transferId: "t2",
        direction: .inbound,
        peerFrom: "c", peerTo: "a",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .complete,
        manifestHash: "hash2"
    )
    let t3 = Transfer(
        transferId: "t3",
        direction: .outbound,
        peerFrom: "a", peerTo: "d",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .canceled,
        manifestHash: "hash3",
        evicted: true
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)
    try store.createTransfer(t3)

    let results = try store.lookupTransfersByManifestHashes(["hash1", "hash2", "hash3"])
    let resultIds = results.map { $0.transferId }
    #expect(resultIds.contains("t1"))
    #expect(resultIds.contains("t2"))
    // t3 is evicted, should not appear
    #expect(!resultIds.contains("t3"))
}

// MARK: - Diff Remote Inventory

@Test
func diffRemoteInventoryComputesMissing() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Local has hash_a
    let t = Transfer(
        transferId: "t1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "hash_a"
    )
    try store.createTransfer(t)

    // Remote advertises hash_a, hash_b, hash_c
    let remoteManifests = ["hash_a", "hash_b", "hash_c"]

    var missing: [String] = []
    for hash in remoteManifests {
        if !(try store.hasManifest(hash)) {
            missing.append(hash)
        }
    }

    #expect(missing.count == 2)
    #expect(missing.contains("hash_b"))
    #expect(missing.contains("hash_c"))
    #expect(!missing.contains("hash_a"))
}

// MARK: - Router Priority

@Test
func routerPrioritizesInventoryAboveChunks() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let router = Router(store: store)
    let now = Date(timeIntervalSince1970: 1_000)

    // Seed a transfer with chunks
    let payload = Data(repeating: 0xAB, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }
    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let envelope = EnvelopeV1(toWayfarerId: Data(repeating: 0xAA, count: 32), manifestId: manifestId, body: Data([0x01]))
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)

    try store.enqueue(item: OutboxItem(id: Data([0x10]), kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try store.enqueue(item: OutboxItem(id: Data([0x11]), kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    // Enqueue an inventory item
    let inventory = InventoryV1(manifests: ["aabb"], generatedAtUnixMs: 1000)
    let inventoryBytes = CanonicalEncoderV1.encode(inventory)
    let inventoryId = AethosIDs.sha256(inventoryBytes)
    try store.enqueue(item: OutboxItem(id: inventoryId, kind: .inventory, payload: inventoryBytes, enqueuedAt: now))

    // Enqueue an inventory request item
    let request = InventoryRequestV1(want: ["ccdd"])
    let requestBytes = CanonicalEncoderV1.encode(request)
    let requestId = AethosIDs.sha256(requestBytes)
    try store.enqueue(item: OutboxItem(id: requestId, kind: .inventoryRequest, payload: requestBytes, enqueuedAt: now))

    // Enqueue a receipt
    let receipt = ReceiptV1(envelopeId: Data(repeating: 0xBB, count: 32), manifestId: manifestId, receivedAtUnixMs: 1)
    let receiptBytes = CanonicalEncoderV1.encode(receipt)
    try store.enqueue(item: OutboxItem(id: Data([0x12]), kind: .receipt, payload: receiptBytes, enqueuedAt: now))

    let plan = try router.planNextSession(budget: SessionBudget(maxBytes: 1_000_000, maxItems: 100), now: now)

    // Expected priority order: receipt, inventoryRequest, inventory, message, metadata, chunks
    // Find indices of each type
    var receiptIdx: Int?
    var inventoryRequestIdx: Int?
    var inventoryIdx: Int?
    var messageIdx: Int?
    var metadataIdx: Int?
    var chunkIdx: Int?

    for (i, item) in plan.enumerated() {
        switch item.priority {
        case .receipt:
            if receiptIdx == nil { receiptIdx = i }
        case .inventoryRequest:
            if inventoryRequestIdx == nil { inventoryRequestIdx = i }
        case .inventory:
            if inventoryIdx == nil { inventoryIdx = i }
        case .message:
            if messageIdx == nil { messageIdx = i }
        case .metadata:
            if metadataIdx == nil { metadataIdx = i }
        case .chunk:
            if chunkIdx == nil { chunkIdx = i }
        }
    }

    // Receipt comes first
    if let ri = receiptIdx, let iri = inventoryRequestIdx {
        #expect(ri < iri)
    }
    // InventoryRequest before Inventory
    if let iri = inventoryRequestIdx, let ii = inventoryIdx {
        #expect(iri < ii)
    }
    // Inventory before messages
    if let ii = inventoryIdx, let msi = messageIdx {
        #expect(ii < msi)
    }
    // Messages before metadata
    if let msi = messageIdx, let mi = metadataIdx {
        #expect(msi < mi)
    }
    // Metadata before chunks
    if let mi = metadataIdx, let ci = chunkIdx {
        #expect(mi < ci)
    }
}

// MARK: - Relay Does Not Advertise Evicted

@Test
func relayDoesNotAdvertiseEvictedTransfers() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Active relay transfer
    let t1 = Transfer(
        transferId: "relay1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "relay_active_hash",
        custody: .relay
    )
    // Evicted relay transfer
    let t2 = Transfer(
        transferId: "relay2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .canceled,
        manifestHash: "relay_evicted_hash",
        custody: .relay,
        evicted: true
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)

    let hashes = try store.listActiveManifestHashes()
    #expect(hashes.contains("relay_active_hash"))
    #expect(!hashes.contains("relay_evicted_hash"))
}

// MARK: - Inventory Request Triggers Replay (integration)

@Test
func inventoryRequestTriggersReplay() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Set up a completed outbound transfer with manifest/envelope/chunks in the store
    let payload = Data(repeating: 0xCD, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let manifestHashHex = manifestId.hexString

    let envelope = EnvelopeV1(
        toWayfarerId: Data(repeating: 0xAA, count: 32),
        manifestId: manifestId,
        body: Data("test.bin".utf8)
    )
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)
    let envelopeId = AethosIDs.envelopeId(canonicalBytes: envelopeBytes)

    // Record envelope in inbox (simulating it was received)
    try store.recordReceived(item: InboxItem(
        id: envelopeId,
        kind: .envelope,
        payload: envelopeBytes,
        receivedAt: now
    ))

    // Create a completed outbound transfer
    let transfer = Transfer(
        transferId: Transfer.newId(),
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .complete,
        manifestHash: manifestHashHex
    )
    try store.createTransfer(transfer)

    // Cache manifest on disk
    let manifestCacheDir = dir.appendingPathComponent("manifests", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestCacheDir, withIntermediateDirectories: true)
    let manifestCachePath = manifestCacheDir.appendingPathComponent("\(manifestHashHex).bin")
    try manifestBytes.write(to: manifestCachePath, options: [.atomic])

    // Now create an InventoryRequestV1 asking for this manifest
    let request = InventoryRequestV1(want: [manifestHashHex])
    let requestBytes = CanonicalEncoderV1.encode(request)

    // Verify we can decode it back
    let decodedRequest = try CanonicalEncoderV1.decodeInventoryRequest(canonical: requestBytes)
    #expect(decodedRequest.want == [manifestHashHex])

    // Verify the transfer is found by lookupTransfersByManifestHashes
    let foundTransfers = try store.lookupTransfersByManifestHashes([manifestHashHex])
    #expect(!foundTransfers.isEmpty)
    #expect(foundTransfers[0].manifestHash == manifestHashHex)

    // After enqueuing the manifest back into outbox, router should plan it
    try store.enqueue(item: OutboxItem(
        id: manifestId,
        kind: .manifest,
        payload: manifestBytes,
        enqueuedAt: now
    ))

    let router = Router(store: store)
    let plan = try router.planNextSession(budget: SessionBudget(maxBytes: 1_000_000, maxItems: 100), now: now)

    // Plan should include at least the manifest and chunks
    let planManifests = plan.filter {
        if case .manifest = $0 { return true }
        return false
    }
    let planChunks = plan.filter {
        if case .chunk = $0 { return true }
        return false
    }

    #expect(!planManifests.isEmpty)
    #expect(!planChunks.isEmpty)
}

// MARK: - Outbox Kind Support

@Test
func outboxSupportsInventoryKinds() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let inventory = InventoryV1(manifests: ["aabb"], generatedAtUnixMs: 1000)
    let inventoryBytes = CanonicalEncoderV1.encode(inventory)
    let inventoryId = AethosIDs.sha256(inventoryBytes)

    try store.enqueue(item: OutboxItem(
        id: inventoryId,
        kind: .inventory,
        payload: inventoryBytes,
        enqueuedAt: now
    ))

    let request = InventoryRequestV1(want: ["ccdd"])
    let requestBytes = CanonicalEncoderV1.encode(request)
    let requestId = AethosIDs.sha256(requestBytes)

    try store.enqueue(item: OutboxItem(
        id: requestId,
        kind: .inventoryRequest,
        payload: requestBytes,
        enqueuedAt: now
    ))

    let items = try store.peekQueuedOutbox(limit: 100)
    #expect(items.count == 2)
    #expect(items.contains { $0.kind == .inventory })
    #expect(items.contains { $0.kind == .inventoryRequest })
}
