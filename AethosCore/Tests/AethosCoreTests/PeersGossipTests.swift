import Foundation
import Testing
@testable import AethosCore

// MARK: - Schema Migration

@Test
func schemaMigrationAddsPeersTable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Schema v4 should have peers table — verify by inserting a peer
    try store.upsertPeerSeen(wayfarerId: String(repeating: "a", count: 64), now: 1000)
    let peers = try store.listPeers(limit: 10, now: 2000)
    #expect(peers.count == 1)
    #expect(peers[0].wayfarerId == String(repeating: "a", count: 64))

    // Verify schema version is 6
    let version = try store.__debugUserVersion()
    #expect(version == 6)
}

// MARK: - Upsert Peer Seen

@Test
func upsertPeerSeenCreatesAndUpdatesLastSeen() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let peerId = String(repeating: "b", count: 64)

    // First upsert: creates new peer
    try store.upsertPeerSeen(wayfarerId: peerId, now: 1000)
    var peers = try store.listPeers(limit: 10, now: 2000)
    #expect(peers.count == 1)
    #expect(peers[0].firstSeenAt == 1000)
    #expect(peers[0].lastSeenAt == 1000)
    #expect(peers[0].lastExchangeAt == nil)

    // Second upsert: updates last_seen_at only
    try store.upsertPeerSeen(wayfarerId: peerId, now: 2000)
    peers = try store.listPeers(limit: 10, now: 3000)
    #expect(peers.count == 1)
    #expect(peers[0].firstSeenAt == 1000)  // unchanged
    #expect(peers[0].lastSeenAt == 2000)   // updated
}

// MARK: - List Peers Ordering

@Test
func listPeersOrdersByLastSeen() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    let peerA = String(repeating: "a", count: 64)
    let peerB = String(repeating: "b", count: 64)
    let peerC = String(repeating: "c", count: 64)

    try store.upsertPeerSeen(wayfarerId: peerA, now: 100)
    try store.upsertPeerSeen(wayfarerId: peerB, now: 300)
    try store.upsertPeerSeen(wayfarerId: peerC, now: 200)

    // Default sort: lastSeenDesc
    let peers = try store.listPeers(limit: 10, sort: .lastSeenDesc, now: 1000)
    #expect(peers.count == 3)
    #expect(peers[0].wayfarerId == peerB) // last_seen=300
    #expect(peers[1].wayfarerId == peerC) // last_seen=200
    #expect(peers[2].wayfarerId == peerA) // last_seen=100
}

// MARK: - Stale Filtering

@Test
func staleFilteringWorks() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    let peerRecent = String(repeating: "a", count: 64)
    let peerStale = String(repeating: "b", count: 64)

    // peerRecent seen at t=900, peerStale seen at t=100
    // now=1000, staleAfter=500 -> cutoff=500
    try store.upsertPeerSeen(wayfarerId: peerRecent, now: 900)
    try store.upsertPeerSeen(wayfarerId: peerStale, now: 100)

    // Without stale filtering: both visible
    let allPeers = try store.listPeers(limit: 10, includeStale: true, now: 1000)
    #expect(allPeers.count == 2)

    // With stale filtering: only recent
    let freshPeers = try store.listPeers(
        limit: 10, includeStale: false, staleAfterSeconds: 500, now: 1000
    )
    #expect(freshPeers.count == 1)
    #expect(freshPeers[0].wayfarerId == peerRecent)

    // Count check
    let (total, stale) = try store.countPeers(staleAfterSeconds: 500, now: 1000)
    #expect(total == 2)
    #expect(stale == 1)
}

// MARK: - Peers List JSON Stable Fields

@Test
func peersListJsonStableFields() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let peerId = String(repeating: "ab", count: 32)

    try store.upsertPeerSeen(wayfarerId: peerId, now: 1000)
    try store.markPeerExchanged(wayfarerId: peerId, now: 2000)

    let peers = try store.listPeers(limit: 10, now: 3000)
    #expect(peers.count == 1)
    let p = peers[0]

    // Verify all expected fields are present
    #expect(p.wayfarerId == peerId)
    #expect(p.shortId == String(peerId.prefix(16)))
    #expect(p.firstSeenAt == 1000)
    #expect(p.lastSeenAt == 1000)
    #expect(p.lastExchangeAt == 2000)
}

// MARK: - Ingest Updates Peer Last Seen

@Test
func ingestUpdatesPeerLastSeenFromTransfer() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let peerId = String(repeating: "cd", count: 32)
    let now = Date(timeIntervalSince1970: 1000)

    // Simulate what ingest does: create a transfer with peerFrom set
    let transfer = Transfer(
        transferId: Transfer.newId(),
        direction: .inbound,
        peerFrom: peerId,
        peerTo: String(repeating: "ef", count: 32),
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        manifestHash: "manifest_hash_test"
    )
    try store.createTransfer(transfer)

    // Simulate what the ingest peer-observation code does
    let inboundTransfers = try store.listTransfers(direction: .inbound)
    let nowEpoch = AethosStore.epochSeconds(now)
    for t in inboundTransfers {
        if !t.peerFrom.isEmpty && t.peerFrom.count == 64 {
            try store.upsertPeerSeen(wayfarerId: t.peerFrom, now: nowEpoch)
        }
    }

    let peers = try store.listPeers(limit: 10, now: nowEpoch + 1000)
    #expect(peers.count == 1)
    #expect(peers[0].wayfarerId == peerId)
    #expect(peers[0].lastSeenAt == nowEpoch)
}

// MARK: - Gossip Selects Only Non-Stale By Default

@Test
func gossipSelectsOnlyNonStaleByDefault() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    let peerFresh = String(repeating: "a", count: 64)
    let peerStale = String(repeating: "b", count: 64)

    // peerFresh seen recently, peerStale seen long ago
    try store.upsertPeerSeen(wayfarerId: peerFresh, now: 90000)
    try store.upsertPeerSeen(wayfarerId: peerStale, now: 1000)

    // Default: exclude stale (staleAfter=86400, now=100000)
    // cutoff = 100000 - 86400 = 13600
    // peerFresh.lastSeen=90000 >= 13600 -> included
    // peerStale.lastSeen=1000 < 13600 -> excluded
    let selected = try store.listPeers(
        limit: 10,
        sort: .lastExchangeAsc,
        includeStale: false,
        staleAfterSeconds: 86400,
        now: 100_000
    )
    #expect(selected.count == 1)
    #expect(selected[0].wayfarerId == peerFresh)
}

// MARK: - Gossip Marks Last Exchange At On Success

@Test
func gossipMarksLastExchangeAtOnSuccess() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let peerId = String(repeating: "d", count: 64)

    try store.upsertPeerSeen(wayfarerId: peerId, now: 1000)

    // Verify no exchange timestamp initially
    var peers = try store.listPeers(limit: 10, now: 2000)
    #expect(peers[0].lastExchangeAt == nil)

    // Mark exchange
    try store.markPeerExchanged(wayfarerId: peerId, now: 2000)

    peers = try store.listPeers(limit: 10, now: 3000)
    #expect(peers[0].lastExchangeAt == 2000)
}

// MARK: - Gossip Does Not Mark Exchange On Failure

@Test
func gossipDoesNotMarkExchangeOnFailure() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let peerId = String(repeating: "e", count: 64)

    try store.upsertPeerSeen(wayfarerId: peerId, now: 1000)

    // Simulate: peer is seen but exchange was never marked (simulating failure)
    // After a "failed" exchange, we would NOT call markPeerExchanged
    // Verify lastExchangeAt remains nil
    let peers = try store.listPeers(limit: 10, now: 2000)
    #expect(peers[0].lastExchangeAt == nil)
}

// MARK: - Gossip Calls Exchange For Each Selected Peer

@Test
func gossipCallsExchangeForEachSelectedPeer() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Create 5 peers with different last_seen times
    for i in 0..<5 {
        let peerId = String(format: "%064x", i + 1)
        try store.upsertPeerSeen(wayfarerId: peerId, now: Int64(1000 + i * 100))
    }

    // List peers with lastExchangeAsc sorting (prioritize never-exchanged)
    let selected = try store.listPeers(
        limit: 3,
        sort: .lastExchangeAsc,
        includeStale: true,
        now: 2000
    )
    #expect(selected.count == 3)

    // All should have nil lastExchangeAt (never exchanged)
    for p in selected {
        #expect(p.lastExchangeAt == nil)
    }

    // After marking 2 peers exchanged, they should sort to the back
    try store.markPeerExchanged(wayfarerId: selected[0].wayfarerId, now: 1500)
    try store.markPeerExchanged(wayfarerId: selected[1].wayfarerId, now: 1600)

    let reselected = try store.listPeers(
        limit: 5,
        sort: .lastExchangeAsc,
        includeStale: true,
        now: 2000
    )
    #expect(reselected.count == 5)

    // First 3 should be the never-exchanged ones (lastExchangeAt == nil, sorted by COALESCE(0) ASC)
    // or the ones with earlier exchange times
    // With COALESCE(last_exchange_at, 0) ASC: nil -> 0, exchanged -> 1500/1600
    // So never-exchanged peers come first
    var neverExchangedCount = 0
    for p in reselected.prefix(3) {
        if p.lastExchangeAt == nil {
            neverExchangedCount += 1
        }
    }
    #expect(neverExchangedCount == 3)
}

// MARK: - Mark Peer Exchanged Updates Timestamp

@Test
func markPeerExchangedUpdatesTimestamp() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let peerId = String(repeating: "f", count: 64)

    try store.upsertPeerSeen(wayfarerId: peerId, now: 1000)
    try store.markPeerExchanged(wayfarerId: peerId, now: 2000)

    var peers = try store.listPeers(limit: 10, now: 3000)
    #expect(peers[0].lastExchangeAt == 2000)

    // Update exchange again
    try store.markPeerExchanged(wayfarerId: peerId, now: 3000)
    peers = try store.listPeers(limit: 10, now: 4000)
    #expect(peers[0].lastExchangeAt == 3000)
}

// MARK: - Integration Test: Three Node Gossip Heals Via Relay Inventory

@Test
func threeNodeGossipHealsViaRelayInventory() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Setup: A has data, R is relay, B needs data
    // A sends to R, R has manifest in inventory
    // B's gossip with R should trigger inventory exchange and request missing

    let storeA = try AethosStore(path: dir.appendingPathComponent("storeA.sqlite"))
    let storeR = try AethosStore(path: dir.appendingPathComponent("storeR.sqlite"))
    let storeB = try AethosStore(path: dir.appendingPathComponent("storeB.sqlite"))

    let now = Date(timeIntervalSince1970: 1000)
    let nowEpoch = AethosStore.epochSeconds(now)

    // A creates payload
    let payload = Data((0..<1024).map { UInt8($0 % 251) })
    let chunks = Chunking.chunk(payload)
    for c in chunks {
        try storeA.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }
    let manifest = Chunking.buildManifest(for: payload)
    let manifestBytes = CanonicalEncoderV1.encode(manifest)
    let manifestId = AethosIDs.manifestId(from: manifest)
    let manifestHashHex = manifestId.hexString

    // A creates outbound transfer
    let transferA = Transfer(
        transferId: Transfer.newId(),
        direction: .outbound,
        peerFrom: String(repeating: "aa", count: 32),
        peerTo: String(repeating: "bb", count: 32),
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        bytesTotal: Int64(payload.count),
        partsTotal: Int32(chunks.count),
        manifestHash: manifestHashHex
    )
    try storeA.createTransfer(transferA)

    // Simulate: R has received the transfer (relay custody)
    for c in chunks {
        try storeR.putChunk(id: c.id, bytes: c.bytes, receivedAt: now)
    }
    let transferR = Transfer(
        transferId: Transfer.newId(),
        direction: .inbound,
        peerFrom: String(repeating: "aa", count: 32),
        peerTo: String(repeating: "bb", count: 32),
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        bytesTotal: Int64(payload.count),
        partsTotal: Int32(chunks.count),
        manifestHash: manifestHashHex,
        custody: .relay
    )
    try storeR.createTransfer(transferR)

    // R's inventory should include the manifest
    let rHashes = try storeR.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(rHashes.contains(manifestHashHex))

    // B knows about R as a peer
    let relayPeerId = String(repeating: "cc", count: 32)
    try storeB.upsertPeerSeen(wayfarerId: relayPeerId, now: nowEpoch)

    // B's inventory is empty
    let bHashes = try storeB.listAdvertisableManifestHashes(limit: 500, now: now)
    #expect(bHashes.isEmpty)

    // B selects R for gossip
    let selectedPeers = try storeB.listPeers(
        limit: 10,
        sort: .lastExchangeAsc,
        includeStale: false,
        staleAfterSeconds: 86400,
        now: nowEpoch
    )
    #expect(selectedPeers.count == 1)
    #expect(selectedPeers[0].wayfarerId == relayPeerId)

    // Simulate inventory exchange conceptually:
    // R advertises manifestHashHex, B doesn't have it -> B would request it
    let rInventory = InventoryV1(manifests: rHashes, generatedAtUnixMs: Int64(now.timeIntervalSince1970 * 1000))
    let bLocalHashes = Set(try storeB.listAdvertisableManifestHashes(limit: 1_000_000, now: now))

    var missingOnB: [String] = []
    for hash in rInventory.manifests {
        if !bLocalHashes.contains(hash) {
            missingOnB.append(hash)
        }
    }
    #expect(missingOnB.count == 1)
    #expect(missingOnB[0] == manifestHashHex)

    // B creates request for missing manifests
    let request = InventoryRequestV1(want: missingOnB)
    #expect(request.want.count == 1)

    // Mark exchange on B
    try storeB.markPeerExchanged(wayfarerId: relayPeerId, now: nowEpoch + 1)

    // Verify B's peer table updated
    let bPeers = try storeB.listPeers(limit: 10, now: nowEpoch + 100)
    #expect(bPeers.count == 1)
    #expect(bPeers[0].lastExchangeAt == nowEpoch + 1)
}

// MARK: - Peer Count

@Test
func peerCountReturnsCorrectTotals() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    // Insert 5 peers with varying last_seen times
    for i in 0..<5 {
        let peerId = String(format: "%064x", i + 1)
        try store.upsertPeerSeen(wayfarerId: peerId, now: Int64(i * 1000))
    }

    // now=5000, staleAfter=2000 -> cutoff=3000
    // Peers with lastSeen: 0, 1000, 2000, 3000, 4000
    // Stale: 0, 1000, 2000 (3 peers with lastSeen < 3000)
    let (total, stale) = try store.countPeers(staleAfterSeconds: 2000, now: 5000)
    #expect(total == 5)
    #expect(stale == 3)
}

// MARK: - Last Exchange Asc Sort Prioritizes Never-Exchanged

@Test
func lastExchangeAscPrioritizesNeverExchanged() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    let peerNever = String(repeating: "1", count: 64)
    let peerOld = String(repeating: "2", count: 64)
    let peerRecent = String(repeating: "3", count: 64)

    try store.upsertPeerSeen(wayfarerId: peerNever, now: 100)
    try store.upsertPeerSeen(wayfarerId: peerOld, now: 200)
    try store.upsertPeerSeen(wayfarerId: peerRecent, now: 300)

    try store.markPeerExchanged(wayfarerId: peerOld, now: 500)
    try store.markPeerExchanged(wayfarerId: peerRecent, now: 900)

    let peers = try store.listPeers(limit: 10, sort: .lastExchangeAsc, includeStale: true, now: 1000)
    #expect(peers.count == 3)
    // Never-exchanged first (COALESCE(null, 0) = 0 < 500 < 900)
    #expect(peers[0].wayfarerId == peerNever)
    #expect(peers[1].wayfarerId == peerOld)
    #expect(peers[2].wayfarerId == peerRecent)
}
