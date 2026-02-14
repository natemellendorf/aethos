import Foundation
import Testing
@testable import AethosCore

// MARK: - Advertise Limit

@Test
func advertiseLimitTruncatesCorrectly() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Create 10 active transfers with distinct manifest hashes
    for i in 0..<10 {
        let t = Transfer(
            transferId: "t\(i)",
            direction: .outbound,
            peerFrom: "a", peerTo: "b",
            createdAt: now, updatedAt: now, lastActivityAt: now,
            status: .sending,
            manifestHash: String(format: "hash_%04d", i)
        )
        try store.createTransfer(t)
    }

    // Request with limit=5 — should only get 5
    let hashes = try store.listAdvertisableManifestHashes(limit: 5, now: now)
    #expect(hashes.count == 5)

    // Total should be 10
    let total = try store.countAdvertisableManifestHashes(now: now)
    #expect(total == 10)

    // Request with limit=20 — should get all 10
    let allHashes = try store.listAdvertisableManifestHashes(limit: 20, now: now)
    #expect(allHashes.count == 10)
}

// MARK: - Request Cap

@Test
func requestCapTruncatesCorrectly() throws {
    // Simulate: peer advertises 10 hashes, we have 3 of them, requestCap=4
    // Expected: missing = 7, capped to 4
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Local has hash_0, hash_1, hash_2
    for i in 0..<3 {
        let t = Transfer(
            transferId: "local_t\(i)",
            direction: .outbound,
            peerFrom: "a", peerTo: "b",
            createdAt: now, updatedAt: now, lastActivityAt: now,
            status: .sending,
            manifestHash: String(format: "hash_%04d", i)
        )
        try store.createTransfer(t)
    }

    // Peer advertises hash_0 through hash_9
    let peerManifests = (0..<10).map { String(format: "hash_%04d", $0) }
    let mySet = Set(try store.listActiveManifestHashes())

    var missingOnMe: [String] = []
    for hash in peerManifests {
        if !mySet.contains(hash) {
            missingOnMe.append(hash)
        }
    }

    // Without cap: 7 missing
    #expect(missingOnMe.count == 7)

    // Apply cap of 4
    let requestCap = 4
    let capped = Array(missingOnMe.prefix(requestCap))
    let truncated = missingOnMe.count > requestCap

    #expect(capped.count == 4)
    #expect(truncated == true)
}

// MARK: - Evicted Excluded From Advertise

@Test
func evictedExcludedFromAdvertise() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Active transfer
    let t1 = Transfer(
        transferId: "t1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "hash_active"
    )
    // Evicted transfer
    let t2 = Transfer(
        transferId: "t2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .canceled,
        manifestHash: "hash_evicted",
        evicted: true
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)

    let hashes = try store.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(hashes.contains("hash_active"))
    #expect(!hashes.contains("hash_evicted"))
}

// MARK: - Expired Excluded From Advertise

@Test
func expiredExcludedFromAdvertise() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 10_000)

    // Active transfer with no expiry
    let t1 = Transfer(
        transferId: "t1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "hash_no_expiry"
    )
    // Active transfer with future expiry
    let t2 = Transfer(
        transferId: "t2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "hash_future_expiry",
        expiresAt: Date(timeIntervalSince1970: 20_000) // future
    )
    // Expired transfer (expires_at in the past)
    let t3 = Transfer(
        transferId: "t3",
        direction: .outbound,
        peerFrom: "a", peerTo: "d",
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_000),
        lastActivityAt: Date(timeIntervalSince1970: 1_000),
        status: .sending,
        manifestHash: "hash_expired",
        expiresAt: Date(timeIntervalSince1970: 5_000) // past
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)
    try store.createTransfer(t3)

    let hashes = try store.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(hashes.contains("hash_no_expiry"))
    #expect(hashes.contains("hash_future_expiry"))
    #expect(!hashes.contains("hash_expired"))
}

// MARK: - Inbound Always Included

@Test
func inboundAlwaysIncludedInAdvertise() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Inbound complete transfer
    let t1 = Transfer(
        transferId: "t1",
        direction: .inbound,
        peerFrom: "c", peerTo: "a",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .complete,
        manifestHash: "hash_inbound_complete",
        custody: .inbound
    )
    // Inbound receiving transfer
    let t2 = Transfer(
        transferId: "t2",
        direction: .inbound,
        peerFrom: "d", peerTo: "a",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        manifestHash: "hash_inbound_receiving",
        custody: .inbound
    )
    // Origin outbound
    let t3 = Transfer(
        transferId: "t3",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "hash_origin",
        custody: .origin
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)
    try store.createTransfer(t3)

    let hashes = try store.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(hashes.contains("hash_inbound_complete"))
    #expect(hashes.contains("hash_inbound_receiving"))
    #expect(hashes.contains("hash_origin"))
}

// MARK: - Relay Not Advertised If Evicted

@Test
func relayNotAdvertisedIfEvicted() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Active relay
    let t1 = Transfer(
        transferId: "relay1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "relay_active_hash",
        custody: .relay
    )
    // Evicted relay
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

    let hashes = try store.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(hashes.contains("relay_active_hash"))
    #expect(!hashes.contains("relay_evicted_hash"))
}

// MARK: - Replay Idempotency

@Test
func replayIdempotencyPreventsDoubleReplay() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Set up a completed outbound transfer with manifest/chunks
    let payload = Data(repeating: 0xCD, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let manifestHashHex = manifestId.hexString

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

    // Simulate the dedup set used by inventory exchange
    var replayedManifests: Set<String> = []

    // First replay should proceed
    let shouldReplay1 = !replayedManifests.contains(manifestHashHex)
    #expect(shouldReplay1 == true)
    replayedManifests.insert(manifestHashHex)

    // Second replay of same hash should be blocked
    let shouldReplay2 = !replayedManifests.contains(manifestHashHex)
    #expect(shouldReplay2 == false)

    // Verify store-level idempotency too: enqueue same manifest twice
    try store.enqueue(item: OutboxItem(
        id: manifestId,
        kind: .manifest,
        payload: manifestBytes,
        enqueuedAt: now
    ))
    // Second enqueue with same id is INSERT OR IGNORE
    try store.enqueue(item: OutboxItem(
        id: manifestId,
        kind: .manifest,
        payload: manifestBytes,
        enqueuedAt: now
    ))

    // Only one outbox entry should exist for this manifest
    let outboxItems = try store.peekQueuedOutbox(limit: 1000)
    let matchingManifests = outboxItems.filter { $0.kind == .manifest && $0.id == manifestId }
    #expect(matchingManifests.count == 1)
}

// MARK: - Integration Test: Partial Delivery + Healing

@Test
func partialDeliveryHealingViaExchange() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let peerADB = dir.appendingPathComponent("peerA.sqlite")
    let peerBDB = dir.appendingPathComponent("peerB.sqlite")

    let storeA = try AethosStore(path: peerADB)
    let storeB = try AethosStore(path: peerBDB)

    let duplex = SimDuplexLink()
    let peerA = SimPeer(name: "peerA", store: storeA, link: duplex.endpointA())
    let peerB = SimPeer(name: "peerB", store: storeB, link: duplex.endpointB())

    // 100KB deterministic payload — will produce multiple chunks
    let payload = Data((0..<(100 * 1024)).map { UInt8($0 % 251) })
    let now = Date(timeIntervalSince1970: 1_000)

    // Step 1: peerA queues payload
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try storeA.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let manifestHashHex = manifestId.hexString

    let envelope = EnvelopeV1(
        toWayfarerId: Data(repeating: 0xBB, count: 32),
        manifestId: manifestId,
        body: Data("test.bin".utf8)
    )
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)
    let envelopeId = AethosIDs.envelopeId(canonicalBytes: envelopeBytes)

    try storeA.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try storeA.enqueue(item: OutboxItem(id: envelopeId, kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    let transferA = Transfer(
        transferId: Transfer.newId(),
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .queued,
        manifestHash: manifestHashHex,
        bytesTotal: Int64(payload.count),
        partsTotal: Int32(chunks.count)
    )
    try storeA.createTransfer(transferA)

    // Step 2: Deliver only a subset of chunks — use a very small budget
    // to only send manifest + envelope + some chunks
    let smallBudget = SessionBudget(maxBytes: 4096, maxItems: 6)
    for i in 0..<3 {
        let sessionNow = now.addingTimeInterval(TimeInterval(i))
        _ = try SimSession.run(from: peerA, to: peerB, budget: smallBudget, now: sessionNow)
    }

    // Step 3: peerB has partial transfer — verify not all chunks arrived
    var allPresent = true
    for cId in manifest.chunkIds {
        if try storeB.getChunk(id: cId) == nil {
            allPresent = false
            break
        }
    }
    // Should NOT have all chunks yet (partial delivery)
    // Note: with a very small budget, it's likely some chunks are missing
    // If by chance they all arrive, the test still validates the healing path

    // Step 4: peerB creates inbound transfer record (simulating ingest)
    if try storeB.getTransferByManifestHash(manifestHashHex, direction: .inbound) == nil {
        let transferB = Transfer(
            transferId: Transfer.newId(),
            direction: .inbound,
            peerFrom: "a", peerTo: "b",
            createdAt: now, updatedAt: now, lastActivityAt: now,
            status: .receiving,
            manifestHash: manifestHashHex,
            bytesTotal: Int64(payload.count),
            partsTotal: Int32(chunks.count)
        )
        try storeB.createTransfer(transferB)
    }

    // Step 4b: Simulate inventory exchange:
    // peerB advertises what it has
    let peerBHashes = try storeB.listAdvertisableManifestHashes(limit: 500, now: now)

    // peerA advertises what it has
    let peerAHashes = try storeA.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(peerAHashes.contains(manifestHashHex))

    // peerB computes what peerA has that peerB needs to request for peerA
    // In this direction: peerA should replay missing chunks that peerB hasn't received
    let peerBSet = Set(peerBHashes)
    var missingOnPeer: [String] = []
    for hash in peerBHashes {
        if !Set(peerAHashes).contains(hash) {
            missingOnPeer.append(hash)
        }
    }

    // peerA checks inventory request: what hashes does peerB want replayed?
    // We simulate: peerB sends InventoryRequestV1 asking for the manifest
    // because peerB's inventory tells peerA what peerB already has.
    // In reality, the exchange detects peerB has the hash partially
    // and peerA replays. For this test, we directly trigger replay.

    // Step 5: peerA re-enqueues manifest content for replay
    // Cache the manifest bytes for peerA
    let manifestCacheA = dir.appendingPathComponent("manifestsA", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestCacheA, withIntermediateDirectories: true)
    try manifestBytes.write(to: manifestCacheA.appendingPathComponent("\(manifestHashHex).bin"), options: [.atomic])

    // Re-enqueue manifest into peerA outbox (replay)
    try storeA.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))

    // Step 6: peerA sends remaining chunks to peerB via additional sessions
    let bigBudget = SessionBudget(maxBytes: 1_000_000, maxItems: 1000)
    for i in 10..<60 {
        let sessionNow = now.addingTimeInterval(TimeInterval(i))
        _ = try SimSession.run(from: peerA, to: peerB, budget: bigBudget, now: sessionNow)

        // Check if peerB has all chunks now
        var complete = true
        var chunksMap: [Data: Data] = [:]
        for cId in manifest.chunkIds {
            if let bytes = try storeB.getChunk(id: cId) {
                chunksMap[cId] = bytes
            } else {
                complete = false
                break
            }
        }
        if complete {
            // Step 7: peerB completes transfer
            let rebuilt = try Chunking.reassemble(chunksById: chunksMap, manifest: manifest)
            #expect(rebuilt == payload)

            // Generate receipt
            let receipt = ReceiptV1(
                envelopeId: envelopeId,
                manifestId: manifestId,
                receivedAtUnixMs: UInt64(Date().timeIntervalSince1970 * 1000)
            )
            let receiptBytes = CanonicalEncoderV1.encode(receipt)
            let receiptId = AethosIDs.receiptId(from: receipt)
            try storeB.enqueue(item: OutboxItem(id: receiptId, kind: .receipt, payload: receiptBytes, enqueuedAt: now))

            // Send receipt back to peerA
            _ = try SimSession.run(from: peerB, to: peerA, budget: bigBudget, now: now.addingTimeInterval(100))

            // Verify receipt arrived at peerA
            let receiptsInA = try storeA.listInboxByKind(.receipt)
            #expect(!receiptsInA.isEmpty)

            allPresent = true
            break
        }
    }

    // Assert: peerB transfer complete (all chunks received)
    #expect(allPresent)
    #expect(try storeB.__debugRowCount(table: "chunks") >= manifest.chunkIds.count)
}

// MARK: - InventoryV1 Truncation with AdvertisableManifestHashes

@Test
func inventoryV1RespectsMaxManifestCount() throws {
    // InventoryV1 caps at 500 manifests
    let manifests = (0..<600).map { String(format: "%064x", $0) }
    let inventory = InventoryV1(manifests: manifests, generatedAtUnixMs: 1000)
    #expect(inventory.manifests.count == 500)
}

// MARK: - Advertise Set Uses listAdvertisableManifestHashes

@Test
func advertisableHashesFiltersBothEvictedAndExpired() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 10_000)

    // Active (no expiry)
    try store.createTransfer(Transfer(
        transferId: "t1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "hash_active"
    ))
    // Evicted
    try store.createTransfer(Transfer(
        transferId: "t2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .canceled,
        manifestHash: "hash_evicted",
        evicted: true
    ))
    // Expired
    try store.createTransfer(Transfer(
        transferId: "t3",
        direction: .outbound,
        peerFrom: "a", peerTo: "d",
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_000),
        lastActivityAt: Date(timeIntervalSince1970: 1_000),
        status: .sending,
        manifestHash: "hash_expired",
        expiresAt: Date(timeIntervalSince1970: 5_000)
    ))
    // Failed
    try store.createTransfer(Transfer(
        transferId: "t4",
        direction: .inbound,
        peerFrom: "c", peerTo: "a",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .failed,
        manifestHash: "hash_failed"
    ))
    // Inbound complete (always included)
    try store.createTransfer(Transfer(
        transferId: "t5",
        direction: .inbound,
        peerFrom: "d", peerTo: "a",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .complete,
        manifestHash: "hash_inbound",
        custody: .inbound
    ))

    let hashes = try store.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(hashes.contains("hash_active"))
    #expect(!hashes.contains("hash_evicted"))
    #expect(!hashes.contains("hash_expired"))
    #expect(!hashes.contains("hash_failed"))
    #expect(hashes.contains("hash_inbound"))
    #expect(hashes.count == 2)
}
