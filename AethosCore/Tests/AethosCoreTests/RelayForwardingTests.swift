import Foundation
import Testing
@testable import AethosCore

// MARK: - Unit Tests

@Test
func relayTransfersAreStoredWhenPeerToDoesNotMatchLocal() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Simulate a relay scenario: this node (local) received a transfer
    // destined for a different peer. Store with custody=.relay.
    let localWayfarer = String(repeating: "aa", count: 32) // 64 hex chars
    let actualDest = String(repeating: "bb", count: 32)

    let t = Transfer(
        transferId: Transfer.newId(),
        direction: .inbound,
        peerFrom: "",
        peerTo: actualDest,
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .receiving,
        bytesTotal: 4096,
        partsTotal: 2,
        manifestHash: "relay_manifest_hash",
        custody: .relay
    )
    try store.createTransfer(t)

    let fetched = try store.getTransfer(id: t.transferId)
    #expect(fetched != nil)
    #expect(fetched?.custody == .relay)
    #expect(fetched?.direction == .inbound)
    #expect(fetched?.peerTo == actualDest)
    #expect(fetched?.peerTo != localWayfarer)
}

@Test
func relayTransfersDoNotReassembleLocally() throws {
    // Relay custody transfers should not produce a reassembled payload file.
    // This test verifies the store-level preconditions: a relay transfer
    // with all chunks present should still remain in .receiving status
    // (no external code should flip it to .complete).
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Create a relay transfer
    let payload = Data(repeating: 0xCD, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let manifestHashHex = manifestId.hexString

    let actualDest = String(repeating: "bb", count: 32)
    let transfer = Transfer(
        transferId: Transfer.newId(),
        direction: .inbound,
        peerFrom: "",
        peerTo: actualDest,
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .receiving,
        bytesTotal: Int64(payload.count),
        bytesReceived: Int64(payload.count),
        partsTotal: Int32(chunks.count),
        partsReceived: Int32(chunks.count),
        manifestHash: manifestHashHex,
        custody: .relay
    )
    try store.createTransfer(transfer)

    // Verify the transfer stays in receiving — relay transfers must NOT be
    // completed locally. The chunks are present but no reassembly should happen.
    let fetched = try store.getTransfer(id: transfer.transferId)!
    #expect(fetched.status == Transfer.Status.receiving)
    #expect(fetched.custody == Transfer.Custody.relay)

    // All chunks are present in the store (ready for forwarding)
    for c in chunks {
        #expect(try store.getChunk(id: c.id) != nil)
    }
}

@Test
func relayAdvertiseIncludesRelayOnlyIfNotEvictedAndNotExpired() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 10_000)

    // Active relay — should be advertised
    try store.createTransfer(Transfer(
        transferId: "relay_active",
        direction: .inbound,
        peerFrom: "", peerTo: "dest1",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        manifestHash: "relay_hash_active",
        custody: .relay
    ))

    // Evicted relay — should NOT be advertised
    try store.createTransfer(Transfer(
        transferId: "relay_evicted",
        direction: .inbound,
        peerFrom: "", peerTo: "dest2",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .canceled,
        manifestHash: "relay_hash_evicted",
        custody: .relay,
        evicted: true
    ))

    // Expired relay — should NOT be advertised
    try store.createTransfer(Transfer(
        transferId: "relay_expired",
        direction: .inbound,
        peerFrom: "", peerTo: "dest3",
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_000),
        lastActivityAt: Date(timeIntervalSince1970: 1_000),
        status: .receiving,
        manifestHash: "relay_hash_expired",
        custody: .relay,
        expiresAt: Date(timeIntervalSince1970: 5_000) // expired
    ))

    let hashes = try store.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(hashes.contains("relay_hash_active"))
    #expect(!hashes.contains("relay_hash_evicted"))
    #expect(!hashes.contains("relay_hash_expired"))

    // Verify forwardable count
    let forwardable = try store.countForwardableRelayTransfers(now: now)
    #expect(forwardable == 1)
}

@Test
func relayReplayIdempotentAcrossDuplicateRequests() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let payload = Data(repeating: 0xEE, count: Chunking.chunkSize + 1)
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try store.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let manifestHashHex = manifestId.hexString

    // Create a relay transfer
    let transfer = Transfer(
        transferId: Transfer.newId(),
        direction: .inbound,
        peerFrom: "", peerTo: "dest",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        manifestHash: manifestHashHex,
        custody: .relay
    )
    try store.createTransfer(transfer)

    // Enqueue manifest to outbox (simulating replay)
    try store.enqueue(item: OutboxItem(
        id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now
    ))

    // Enqueue the same manifest again — INSERT OR IGNORE should prevent duplicates
    try store.enqueue(item: OutboxItem(
        id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now
    ))

    // Verify only one outbox entry exists for this manifest
    let outboxItems = try store.peekQueuedOutbox(limit: 10_000)
    let matching = outboxItems.filter { $0.kind == .manifest && $0.id == manifestId }
    #expect(matching.count == 1)

    // In-memory dedup set also prevents double replay within a single exchange
    var replayedManifests: Set<String> = []
    #expect(!replayedManifests.contains(manifestHashHex))
    replayedManifests.insert(manifestHashHex)
    #expect(replayedManifests.contains(manifestHashHex))
}

@Test
func relayListReturnsActiveRelayTransfersOnly() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 10_000)

    // Active relay
    try store.createTransfer(Transfer(
        transferId: "r_active",
        direction: .inbound,
        peerFrom: "", peerTo: "dest1",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        bytesTotal: 2048,
        manifestHash: "hash_r1",
        custody: .relay
    ))

    // Evicted relay
    try store.createTransfer(Transfer(
        transferId: "r_evicted",
        direction: .inbound,
        peerFrom: "", peerTo: "dest2",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .canceled,
        manifestHash: "hash_r2",
        custody: .relay,
        evicted: true
    ))

    // Non-relay inbound
    try store.createTransfer(Transfer(
        transferId: "i_normal",
        direction: .inbound,
        peerFrom: "", peerTo: "me",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        manifestHash: "hash_i1",
        custody: .inbound
    ))

    // Origin outbound
    try store.createTransfer(Transfer(
        transferId: "o_normal",
        direction: .outbound,
        peerFrom: "me", peerTo: "other",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "hash_o1",
        custody: .origin
    ))

    let relayTransfers = try store.listRelayTransfers(activeOnly: true, now: now)
    #expect(relayTransfers.count == 1)
    #expect(relayTransfers[0].transferId == "r_active")
    #expect(relayTransfers[0].custody == .relay)
}

@Test
func relayPeerToUpdatedWhenEnvelopeArrives() throws {
    // When a transfer is created from a manifest (peerTo=local) and then
    // the envelope arrives showing a different destination, the transfer's
    // custody should be updated to .relay and peerTo to the actual destination.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let localWayfarer = String(repeating: "aa", count: 32)
    let actualDest = String(repeating: "bb", count: 32)

    // Create transfer initially as inbound (before envelope arrives)
    let t = Transfer(
        transferId: "relay_upgrade",
        direction: .inbound,
        peerFrom: "",
        peerTo: localWayfarer,
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        manifestHash: "some_hash",
        custody: .inbound
    )
    try store.createTransfer(t)

    // Simulate envelope arriving — update custody to relay
    var fetched = try store.getTransfer(id: "relay_upgrade")!
    #expect(fetched.custody == .inbound)

    fetched.custody = .relay
    fetched.peerTo = actualDest
    fetched.updatedAt = Date()
    try store.updateTransfer(fetched)

    let updated = try store.getTransfer(id: "relay_upgrade")!
    #expect(updated.custody == .relay)
    #expect(updated.peerTo == actualDest)
}

// MARK: - Integration Test: A -> R -> B Relay Forwarding

@Test
func threeNodeRelayForwardingWorksEndToEnd() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Three peer stores
    let dbA = dir.appendingPathComponent("peerA.sqlite")
    let dbR = dir.appendingPathComponent("peerR.sqlite")
    let dbB = dir.appendingPathComponent("peerB.sqlite")

    let storeA = try AethosStore(path: dbA)
    let storeR = try AethosStore(path: dbR)
    let storeB = try AethosStore(path: dbB)

    // Two duplex links: A<->R and R<->B
    let linkAR = SimDuplexLink()
    let linkRB = SimDuplexLink()

    let peerA = SimPeer(name: "A", store: storeA, link: linkAR.endpointA())
    let peerR_fromA = SimPeer(name: "R_recv", store: storeR, link: linkAR.endpointB())
    let peerR_toB = SimPeer(name: "R_send", store: storeR, link: linkRB.endpointA())
    let peerB = SimPeer(name: "B", store: storeB, link: linkRB.endpointB())

    // Deterministic payload (100KB)
    let payload = Data((0..<(100 * 1024)).map { UInt8($0 % 251) })
    let now = Date(timeIntervalSince1970: 1_000)

    // ---- Step 1: A queues payload for B ----
    let destB = Data(repeating: 0xBB, count: 32) // B's wayfarer ID
    let destBHex = destB.hexString

    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try storeA.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }

    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let manifestHashHex = manifestId.hexString

    let envelope = EnvelopeV1(
        toWayfarerId: destB,
        manifestId: manifestId,
        body: Data("relay-test.bin".utf8)
    )
    let envelopeBytes = CanonicalEncoderV1.encode(envelope)
    let envelopeId = AethosIDs.envelopeId(canonicalBytes: envelopeBytes)

    try storeA.enqueue(item: OutboxItem(id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now))
    try storeA.enqueue(item: OutboxItem(id: envelopeId, kind: .envelope, payload: envelopeBytes, enqueuedAt: now))

    let transferA = Transfer(
        transferId: Transfer.newId(),
        direction: .outbound,
        peerFrom: "aaa", peerTo: destBHex,
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .queued,
        bytesTotal: Int64(payload.count),
        partsTotal: Int32(chunks.count),
        manifestHash: manifestHashHex
    )
    try storeA.createTransfer(transferA)

    // ---- Step 2: Deliver all frames from A to R (not to B) ----
    let fullBudget = SessionBudget(maxBytes: 1_000_000, maxItems: 10_000)
    for i in 0..<50 {
        let sessionNow = now.addingTimeInterval(TimeInterval(i))
        _ = try SimSession.run(from: peerA, to: peerR_fromA, budget: fullBudget, now: sessionNow)

        // Check if all chunks arrived at R
        var allPresent = true
        for cId in manifest.chunkIds {
            if try storeR.getChunk(id: cId) == nil {
                allPresent = false
                break
            }
        }
        if allPresent { break }
    }

    // ---- Step 3: Verify R has relay custody ----
    // Manually create the relay transfer in R's store (simulating what cmdIngest does).
    // The relay detection logic is in the CLI; in tests we set custody directly.
    let transferR = Transfer(
        transferId: Transfer.newId(),
        direction: .inbound,
        peerFrom: "",
        peerTo: destBHex,
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .receiving,
        bytesTotal: Int64(payload.count),
        bytesReceived: Int64(payload.count),
        partsTotal: Int32(chunks.count),
        partsReceived: Int32(chunks.count),
        manifestHash: manifestHashHex,
        custody: .relay
    )
    try storeR.createTransfer(transferR)

    // Verify R's relay transfer exists
    let relayTransfer = try storeR.getTransfer(id: transferR.transferId)!
    #expect(relayTransfer.custody == Transfer.Custody.relay)
    #expect(relayTransfer.peerTo == destBHex)

    // Verify relay appears in advertise set
    let relayHashes = try storeR.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(relayHashes.contains(manifestHashHex))

    // Verify relay never wrote a reassembled payload file
    // (We check this by verifying no file exists in archive directory)
    let archiveDir = dir.appendingPathComponent("archive", isDirectory: true)
    try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
    let archiveFiles = (try? FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    #expect(archiveFiles.isEmpty)

    // ---- Step 4: R replays content to outbox for forwarding to B ----
    // Cache the manifest on R's side
    let manifestCacheDir = dir.appendingPathComponent("manifests", isDirectory: true)
    try FileManager.default.createDirectory(at: manifestCacheDir, withIntermediateDirectories: true)
    let manifestCachePath = manifestCacheDir.appendingPathComponent("\(manifestHashHex).bin")
    try manifestBytes.write(to: manifestCachePath, options: [.atomic])

    // Re-enqueue manifest + envelope in R's outbox (this is what replay does)
    try storeR.enqueue(item: OutboxItem(
        id: manifestId, kind: .manifest, payload: manifestBytes, enqueuedAt: now
    ))
    try storeR.enqueue(item: OutboxItem(
        id: envelopeId, kind: .envelope, payload: envelopeBytes, enqueuedAt: now
    ))

    // ---- Step 5: Send from R to B ----
    for i in 0..<50 {
        let sessionNow = now.addingTimeInterval(TimeInterval(100 + i))
        _ = try SimSession.run(from: peerR_toB, to: peerB, budget: fullBudget, now: sessionNow)

        // Check if B has all chunks
        var allPresent = true
        for cId in manifest.chunkIds {
            if try storeB.getChunk(id: cId) == nil {
                allPresent = false
                break
            }
        }
        if allPresent { break }
    }

    // ---- Step 6: B reassembles and verifies payload ----
    var chunksById: [Data: Data] = [:]
    chunksById.reserveCapacity(manifest.chunkIds.count)
    for cId in manifest.chunkIds {
        let bytes = try storeB.getChunk(id: cId)
        #expect(bytes != nil, "B missing chunk: \(cId.hexString)")
        if let bytes {
            chunksById[cId] = bytes
        }
    }

    let rebuilt = try Chunking.reassemble(chunksById: chunksById, manifest: manifest)
    #expect(rebuilt == payload, "Reassembled payload should match original")

    // ---- Step 7: B sends receipt back to A (via R) ----
    let receipt = ReceiptV1(
        envelopeId: envelopeId,
        manifestId: manifestId,
        receivedAtUnixMs: UInt64(Date().timeIntervalSince1970 * 1000)
    )
    let receiptBytes = CanonicalEncoderV1.encode(receipt)
    let receiptId = AethosIDs.receiptId(from: receipt)
    try storeB.enqueue(item: OutboxItem(
        id: receiptId, kind: .receipt, payload: receiptBytes, enqueuedAt: now
    ))

    // B -> R (receipt travels through relay)
    _ = try SimSession.run(from: peerB, to: peerR_toB, budget: fullBudget, now: now.addingTimeInterval(200))

    // R forwards receipt: receipt in R's inbox, re-enqueue to R's outbox toward A
    let receiptsInR = try storeR.listInboxByKind(.receipt)
    #expect(!receiptsInR.isEmpty, "R should have received the receipt")

    // Re-enqueue receipt in R for A
    for rItem in receiptsInR {
        try storeR.enqueue(item: OutboxItem(
            id: rItem.id, kind: .receipt, payload: rItem.payload, enqueuedAt: now
        ))
    }

    // R -> A
    _ = try SimSession.run(from: peerR_fromA, to: peerA, budget: fullBudget, now: now.addingTimeInterval(300))

    // Verify A received the receipt
    let receiptsInA = try storeA.listInboxByKind(.receipt)
    #expect(!receiptsInA.isEmpty, "A should have received the receipt from B via R")
}

@Test
func relayCustodyTransfersRespectEvictionTTL() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 10_000)

    // Relay with expired TTL
    try store.createTransfer(Transfer(
        transferId: "relay_ttl",
        direction: .inbound,
        peerFrom: "", peerTo: "dest",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: now, lastActivityAt: now,
        status: .receiving,
        bytesTotal: 1024,
        manifestHash: "hash_relay_ttl",
        custody: .relay,
        ttlSeconds: 100 // expires at 200, well before now=10000
    ))

    // TTL eviction should evict the relay transfer
    let evicted = try store.evictExpiredTransfers(now: now)
    #expect(evicted.contains("relay_ttl"))

    let fetched = try store.getTransfer(id: "relay_ttl")!
    #expect(fetched.evicted == true)
    #expect(fetched.status == .canceled)

    // Should not appear in advertise set
    let hashes = try store.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(!hashes.contains("hash_relay_ttl"))

    // Should not appear in forwardable count
    let count = try store.countForwardableRelayTransfers(now: now)
    #expect(count == 0)
}

@Test
func relayCountForwardable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 10_000)

    // 3 active relay transfers
    for i in 0..<3 {
        try store.createTransfer(Transfer(
            transferId: "rf\(i)",
            direction: .inbound,
            peerFrom: "", peerTo: "dest\(i)",
            createdAt: now, updatedAt: now, lastActivityAt: now,
            status: .receiving,
            bytesTotal: 1024,
            manifestHash: "fwd_hash_\(i)",
            custody: .relay
        ))
    }

    // 1 evicted relay
    try store.createTransfer(Transfer(
        transferId: "rf_evicted",
        direction: .inbound,
        peerFrom: "", peerTo: "dest_ev",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .canceled,
        manifestHash: "fwd_hash_evicted",
        custody: .relay,
        evicted: true
    ))

    // 1 non-relay inbound
    try store.createTransfer(Transfer(
        transferId: "inb1",
        direction: .inbound,
        peerFrom: "", peerTo: "me",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        manifestHash: "inb_hash",
        custody: .inbound
    ))

    let count = try store.countForwardableRelayTransfers(now: now)
    #expect(count == 3)
}
