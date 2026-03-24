import Foundation
import Testing
@testable import AethosCore

@Test
func gossipV1_storeAdapter_roundTripIngestThenEligibleAndFetch() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let adapter = AethosStore.GossipV1StoreAdapter(store: store)

    let envelopeBytes = try envelopeBytes(seed: 1)
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)
    let expiryUnixMs: UInt64 = 120_000

    try adapter.ingest(itemID, envelopeBytes: envelopeBytes, expiryUnixMs: expiryUnixMs, hopCount: 2)

    let eligible = try adapter.eligibleItemIDs(nowMs: 1_000)
    #expect(eligible == [itemID])

    let fetched = try adapter.fetch(itemID)
    #expect(fetched?.envelopeBytes == envelopeBytes)
    #expect(fetched?.expiryUnixMs == expiryUnixMs)
    #expect(fetched?.hopCount == 2)
}

@Test
func gossipV1_storeAdapter_dedupesByItemID_andRemainsIdempotent() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let adapter = AethosStore.GossipV1StoreAdapter(store: store)

    let envelopeBytes = try envelopeBytes(seed: 2)
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)

    try adapter.ingest(itemID, envelopeBytes: envelopeBytes, expiryUnixMs: 100_000, hopCount: 1)
    try adapter.ingest(itemID, envelopeBytes: envelopeBytes, expiryUnixMs: 100_000, hopCount: 1)

    #expect(try store.__debugRowCount(table: "gossip_items") == 1)
    #expect(try adapter.eligibleItemIDs(nowMs: 0) == [itemID])
}

@Test
func gossipV1_storeAdapter_rejectsHopRegression() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let adapter = AethosStore.GossipV1StoreAdapter(store: store)

    let envelopeBytes = try envelopeBytes(seed: 3)
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)

    try adapter.ingest(itemID, envelopeBytes: envelopeBytes, expiryUnixMs: 100_000, hopCount: 7)

    #expect(throws: GossipV1EncounterEngine.ValidationError.hopRegression(existing: 7, incoming: 6)) {
        try adapter.ingest(itemID, envelopeBytes: envelopeBytes, expiryUnixMs: 100_000, hopCount: 6)
    }

    #expect(try adapter.existingHopCount(itemID) == 7)
}

@Test
func gossipV1_storeAdapter_filtersEligibleByExpiryBoundary() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let adapter = AethosStore.GossipV1StoreAdapter(store: store)

    let nowMs: UInt64 = 1_000
    let boundary = nowMs + GossipV1.CLOCK_SKEW_TOLERANCE_MS

    let envelopeA = try envelopeBytes(seed: 10)
    let idA = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeA)
    try adapter.ingest(idA, envelopeBytes: envelopeA, expiryUnixMs: boundary + 1, hopCount: 0)

    let envelopeB = try envelopeBytes(seed: 11)
    let idB = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeB)
    try adapter.ingest(idB, envelopeBytes: envelopeB, expiryUnixMs: boundary, hopCount: 0)

    let eligible = try adapter.eligibleItemIDs(nowMs: nowMs)
    #expect(eligible.count == 1)
    #expect(eligible == [idA])
}

@Test
func gossipV1_storeAdapter_canIncludeQueuedOutboxEnvelopesPolicy() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let adapter = AethosStore.GossipV1StoreAdapter(store: store, policy: .gossipObjectsAndQueuedOutboxEnvelopes)

    let envelopeBytes = try envelopeBytes(seed: 42)
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envelopeBytes)
    let expiresAt = Date(timeIntervalSince1970: 100)
    try store.enqueue(item: OutboxItem(
        id: itemID.rawBytes(),
        kind: .envelope,
        payload: envelopeBytes,
        enqueuedAt: Date(timeIntervalSince1970: 0),
        expiresAt: expiresAt
    ))

    let eligible = try adapter.eligibleItemIDs(nowMs: 1_000)
    #expect(eligible == [itemID])

    let fetched = try adapter.fetch(itemID)
    #expect(fetched?.envelopeBytes == envelopeBytes)
    #expect(fetched?.hopCount == 0)
    #expect(fetched?.expiryUnixMs == 100_000)
}

private func envelopeBytes(seed: UInt64) throws -> Data {
    try GossipV1TestSupport.makeTransferEnvelopeBytes(seed: seed)
}
