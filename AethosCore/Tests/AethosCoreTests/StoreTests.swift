import Foundation
import Testing
@testable import AethosCore

@Test
func chunkInsertIsIdempotent() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let dbURL = dir.appendingPathComponent("store.sqlite", isDirectory: false)
    let store = try AethosStore(path: dbURL)

    let id = Data(repeating: 0xAA, count: 32)
    let bytes = Data("chunk".utf8)
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    try store.putChunk(id: id, bytes: bytes, receivedAt: now)
    try store.putChunk(id: id, bytes: bytes, receivedAt: now)

    #expect(try store.__debugRowCount(table: "chunks") == 1)
    #expect(try store.getChunk(id: id) == bytes)
}

@Test
func outboxEnqueueDequeueOrdering() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    let early = Date(timeIntervalSince1970: 100)
    let late = Date(timeIntervalSince1970: 200)

    let item1 = OutboxItem(
        id: Data([0x01]),
        kind: .manifest,
        payload: Data([0xA1]),
        enqueuedAt: early
    )
    let item2 = OutboxItem(
        id: Data([0x02]),
        kind: .envelope,
        payload: Data([0xB2]),
        enqueuedAt: late
    )

    try store.enqueue(item: item2)
    try store.enqueue(item: item1)

    let batch1 = try store.dequeueBatch(limit: 1)
    #expect(batch1.count == 1)
    #expect(batch1[0].id == item1.id)

    let batch2 = try store.dequeueBatch(limit: 1)
    #expect(batch2.count == 1)
    #expect(batch2[0].id == item2.id)

    #expect(try store.__debugRowCount(table: "outbox") == 2)
}

@Test
func evictionRemovesExpiredRows() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))

    let now = Date(timeIntervalSince1970: 1_000)
    let past = Date(timeIntervalSince1970: 900)
    let future = Date(timeIntervalSince1970: 2_000)

    try store.putChunk(
        id: Data([0x10]),
        bytes: Data([0xAA]),
        receivedAt: now,
        expiresAt: past
    )
    try store.putChunk(
        id: Data([0x11]),
        bytes: Data([0xBB]),
        receivedAt: now,
        expiresAt: future
    )

    try store.enqueue(item: OutboxItem(id: Data([0x20]), kind: .receipt, payload: Data([0x01]), enqueuedAt: now, expiresAt: past))
    try store.enqueue(item: OutboxItem(id: Data([0x21]), kind: .receipt, payload: Data([0x02]), enqueuedAt: now, expiresAt: future))

    try store.recordReceived(item: InboxItem(id: Data([0x30]), kind: .manifest, payload: Data([0x03]), receivedAt: now, expiresAt: past))
    try store.recordReceived(item: InboxItem(id: Data([0x31]), kind: .manifest, payload: Data([0x04]), receivedAt: now, expiresAt: future))

    let counts = try store.evictExpired(now: now)
    #expect(counts == EvictionCounts(chunks: 1, outbox: 1, inbox: 1))

    #expect(try store.__debugRowCount(table: "chunks") == 1)
    #expect(try store.__debugRowCount(table: "outbox") == 1)
    #expect(try store.__debugRowCount(table: "inbox") == 1)
}
