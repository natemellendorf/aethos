import Foundation
import Testing
@testable import AethosCore

// MARK: - Schema Migration

@Test
func schemaMigrationV2toV3AddsNewColumns() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    // Fresh database should be at v4 (latest schema).
    #expect(try store.__debugUserVersion() == 4)

    // Verify we can create a transfer with custody fields.
    let now = Date(timeIntervalSince1970: 1_000)
    let t = Transfer(
        transferId: Transfer.newId(),
        direction: .outbound,
        peerFrom: "aaa",
        peerTo: "bbb",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .queued,
        custody: .origin,
        ttlSeconds: 3600,
        completedAt: nil,
        evicted: false
    )
    try store.createTransfer(t)
    let fetched = try store.getTransfer(id: t.transferId)
    #expect(fetched != nil)
    #expect(fetched?.custody == .origin)
    #expect(fetched?.ttlSeconds == 3600)
    #expect(fetched?.expiresAt != nil)
    #expect(fetched?.evicted == false)
}

// MARK: - Custody Assignment

@Test
func outboundTransferDefaultsCustodyToOrigin() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let t = Transfer(
        transferId: Transfer.newId(),
        direction: .outbound,
        peerFrom: "aaa",
        peerTo: "bbb",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .queued
    )
    #expect(t.custody == .origin)
    try store.createTransfer(t)

    let fetched = try store.getTransfer(id: t.transferId)!
    #expect(fetched.custody == .origin)
}

@Test
func inboundTransferDefaultsCustodyToInbound() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let t = Transfer(
        transferId: Transfer.newId(),
        direction: .inbound,
        peerFrom: "aaa",
        peerTo: "bbb",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .receiving
    )
    #expect(t.custody == .inbound)
    try store.createTransfer(t)

    let fetched = try store.getTransfer(id: t.transferId)!
    #expect(fetched.custody == .inbound)
}

@Test
func relayCustodyCanBeSetExplicitly() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let t = Transfer(
        transferId: Transfer.newId(),
        direction: .outbound,
        peerFrom: "aaa",
        peerTo: "bbb",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .sending,
        bytesTotal: 1024,
        custody: .relay,
        ttlSeconds: 600
    )
    #expect(t.custody == .relay)
    try store.createTransfer(t)

    let fetched = try store.getTransfer(id: t.transferId)!
    #expect(fetched.custody == .relay)
    #expect(fetched.ttlSeconds == 600)
}

// MARK: - TTL Expiration

@Test
func ttlSetsExpiresAtFromCreatedAt() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let t = Transfer(
        transferId: Transfer.newId(),
        direction: .outbound,
        peerFrom: "a",
        peerTo: "b",
        createdAt: now,
        updatedAt: now,
        lastActivityAt: now,
        status: .queued,
        ttlSeconds: 3600
    )
    // expires_at should be created_at + ttl_seconds
    #expect(t.expiresAt != nil)
    #expect(Int(t.expiresAt!.timeIntervalSince1970) == 4600)
}

@Test
func expiredTransfersAreEvicted() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Origin transfer with short TTL (already expired).
    let t1 = Transfer(
        transferId: "t1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: now, lastActivityAt: now,
        status: .sending,
        custody: .origin,
        ttlSeconds: 100  // expires at 200, well before now=1000
    )
    // Relay transfer with short TTL (already expired).
    let t2 = Transfer(
        transferId: "t2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: now, lastActivityAt: now,
        status: .sending,
        bytesTotal: 512,
        custody: .relay,
        ttlSeconds: 100
    )
    // Origin transfer with long TTL (NOT expired).
    let t3 = Transfer(
        transferId: "t3",
        direction: .outbound,
        peerFrom: "a", peerTo: "d",
        createdAt: Date(timeIntervalSince1970: 900),
        updatedAt: now, lastActivityAt: now,
        status: .sending,
        custody: .origin,
        ttlSeconds: 3600  // expires at 4500
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)
    try store.createTransfer(t3)

    let evicted = try store.evictExpiredTransfers(now: now)
    #expect(evicted.count == 2)
    #expect(evicted.contains("t1"))
    #expect(evicted.contains("t2"))

    // Verify t1 and t2 are evicted, t3 is not.
    let ft1 = try store.getTransfer(id: "t1")!
    #expect(ft1.evicted == true)
    #expect(ft1.status == .canceled)

    let ft3 = try store.getTransfer(id: "t3")!
    #expect(ft3.evicted == false)
    #expect(ft3.status == .sending)
}

@Test
func inboundTransfersNeverTTLEvicted() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Inbound transfer with expired TTL — should NOT be evicted.
    let t = Transfer(
        transferId: "tinbound",
        direction: .inbound,
        peerFrom: "a", peerTo: "b",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: now, lastActivityAt: now,
        status: .receiving,
        custody: .inbound,
        ttlSeconds: 10,
        expiresAt: Date(timeIntervalSince1970: 110)
    )
    try store.createTransfer(t)

    let evicted = try store.evictExpiredTransfers(now: now)
    #expect(evicted.isEmpty)

    let fetched = try store.getTransfer(id: "tinbound")!
    #expect(fetched.evicted == false)
}

// MARK: - Relay Cache Accounting + Eviction

@Test
func relayCacheAccountingTracksBytes() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    #expect(try store.relayCacheBytes() == 0)

    let t1 = Transfer(
        transferId: "r1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        bytesTotal: 1024,
        custody: .relay
    )
    let t2 = Transfer(
        transferId: "r2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        bytesTotal: 2048,
        custody: .relay
    )
    // Origin transfer — should NOT count.
    let t3 = Transfer(
        transferId: "o1",
        direction: .outbound,
        peerFrom: "a", peerTo: "d",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        bytesTotal: 4096,
        custody: .origin
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)
    try store.createTransfer(t3)

    #expect(try store.relayCacheBytes() == 3072)
}

@Test
func relayEvictionUnderPressure() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Create three relay transfers, oldest first.
    let t1 = Transfer(
        transferId: "r1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: now, lastActivityAt: now,
        status: .sending,
        bytesTotal: 1000,
        custody: .relay
    )
    let t2 = Transfer(
        transferId: "r2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: Date(timeIntervalSince1970: 200),
        updatedAt: now, lastActivityAt: now,
        status: .sending,
        bytesTotal: 1000,
        custody: .relay
    )
    let t3 = Transfer(
        transferId: "r3",
        direction: .outbound,
        peerFrom: "a", peerTo: "d",
        createdAt: Date(timeIntervalSince1970: 300),
        updatedAt: now, lastActivityAt: now,
        status: .sending,
        bytesTotal: 1000,
        custody: .relay
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)
    try store.createTransfer(t3)

    // Set max to 1500 — should evict oldest transfers until <= 1500.
    let evicted = try store.evictRelayTransfers(maxCacheBytes: 1500, now: now)

    // Need to evict at least the oldest (t1, 1000) + next (t2, 1000) to get to 1000 <= 1500.
    // Wait: 3000 - 1000 = 2000 > 1500, so evict t1. Then 2000 - 1000 = 1000 <= 1500. Done.
    // Actually: remaining starts at 3000. After evicting t1: remaining = 2000 > 1500. Evict t2: remaining = 1000 <= 1500. Done.
    #expect(evicted.count == 2)
    #expect(evicted.contains("r1"))
    #expect(evicted.contains("r2"))

    let ft1 = try store.getTransfer(id: "r1")!
    #expect(ft1.evicted == true)

    let ft3 = try store.getTransfer(id: "r3")!
    #expect(ft3.evicted == false)

    #expect(try store.relayCacheBytes() == 1000)
}

@Test
func relayEvictionDoesNotTouchOriginOrInbound() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Create origin + inbound transfers.
    let origin = Transfer(
        transferId: "origin1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        bytesTotal: 5000,
        custody: .origin
    )
    let inbound = Transfer(
        transferId: "inbound1",
        direction: .inbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .receiving,
        bytesTotal: 5000,
        custody: .inbound
    )
    try store.createTransfer(origin)
    try store.createTransfer(inbound)

    // Relay eviction with maxCacheBytes=0 should evict nothing (no relay transfers).
    let evicted = try store.evictRelayTransfers(maxCacheBytes: 0, now: now)
    #expect(evicted.isEmpty)

    #expect(try store.getTransfer(id: "origin1")!.evicted == false)
    #expect(try store.getTransfer(id: "inbound1")!.evicted == false)
}

// MARK: - Outbound GC

@Test
func completedOutboundGCAfterGracePeriod() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    // Completed origin transfer, completed long ago.
    let t1 = Transfer(
        transferId: "gc1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: now, lastActivityAt: now,
        status: .complete,
        custody: .origin,
        completedAt: Date(timeIntervalSince1970: 200)
    )
    // Completed origin transfer, completed recently (within grace).
    let t2 = Transfer(
        transferId: "gc2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: Date(timeIntervalSince1970: 900),
        updatedAt: now, lastActivityAt: now,
        status: .complete,
        custody: .origin,
        completedAt: Date(timeIntervalSince1970: 990)
    )
    // Non-complete origin transfer — not GC'd.
    let t3 = Transfer(
        transferId: "gc3",
        direction: .outbound,
        peerFrom: "a", peerTo: "d",
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: now, lastActivityAt: now,
        status: .sending,
        custody: .origin
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)
    try store.createTransfer(t3)

    // Grace period of 60 seconds. At now=1000:
    // t1 completed at 200, cutoff = 1000 - 60 = 940 → 200 <= 940 → GC'd
    // t2 completed at 990, cutoff = 940 → 990 > 940 → NOT GC'd
    let gcd = try store.gcCompletedTransfers(graceSeconds: 60, now: now)
    #expect(gcd.count == 1)
    #expect(gcd.contains("gc1"))

    let ft1 = try store.getTransfer(id: "gc1")!
    #expect(ft1.evicted == true)

    let ft2 = try store.getTransfer(id: "gc2")!
    #expect(ft2.evicted == false)

    let ft3 = try store.getTransfer(id: "gc3")!
    #expect(ft3.evicted == false)
}

// MARK: - Chunk Cleanup

@Test
func deleteChunksRemovesSpecifiedIds() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let c1 = Data([0x01, 0x02, 0x03])
    let c2 = Data([0x04, 0x05, 0x06])
    let c3 = Data([0x07, 0x08, 0x09])

    try store.putChunk(id: c1, bytes: Data("chunk1".utf8), receivedAt: now)
    try store.putChunk(id: c2, bytes: Data("chunk2".utf8), receivedAt: now)
    try store.putChunk(id: c3, bytes: Data("chunk3".utf8), receivedAt: now)

    #expect(try store.__debugRowCount(table: "chunks") == 3)

    let deleted = try store.deleteChunks(ids: [c1, c2])
    #expect(deleted == 2)
    #expect(try store.__debugRowCount(table: "chunks") == 1)
    #expect(try store.getChunk(id: c3) != nil)
    #expect(try store.getChunk(id: c1) == nil)
}

// MARK: - Manifest Hash Lookup

@Test
func getManifestHashesReturnsHashesForTransferIds() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_000)

    let t1 = Transfer(
        transferId: "m1",
        direction: .outbound,
        peerFrom: "a", peerTo: "b",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending,
        manifestHash: "abcdef1234"
    )
    let t2 = Transfer(
        transferId: "m2",
        direction: .outbound,
        peerFrom: "a", peerTo: "c",
        createdAt: now, updatedAt: now, lastActivityAt: now,
        status: .sending
        // no manifest hash
    )
    try store.createTransfer(t1)
    try store.createTransfer(t2)

    let hashes = try store.getManifestHashes(transferIds: ["m1", "m2", "nonexistent"])
    #expect(hashes.count == 1)
    #expect(hashes[0] == "abcdef1234")
}
