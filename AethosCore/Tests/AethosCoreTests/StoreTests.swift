import Foundation
import Testing
@testable import AethosCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite3
#endif

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

@Test
func messageInsertIsIdempotentAndListWorks() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let msg = MessageV1(
        createdAtUnixMs: 123_456_789,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("hello".utf8)
    )
    let canonical = CanonicalEncoderV1.encode(msg)
    let id = AethosIDs.messageId(canonicalBytes: canonical)

    let row = AethosStore.MessageRow(
        messageId: id,
        kind: "message.v2",
        direction: .outbound,
        authorWayfarerId: String(repeating: "a", count: 64),
        receivedFromPeerId: String(repeating: "b", count: 64),
        peerTo: String(repeating: "b", count: 64),
        createdAt: now,
        canonical: canonical
    )

    try store.recordMessage(row)
    try store.recordMessage(row)

    let rows = try store.listMessages(limit: 10)
    #expect(rows.count == 1)
    #expect(rows[0] == row)

    let got = try store.getMessage(id: id)
    #expect(got == row)
}

@Test
func inboundMessageAttributionUsesCanonicalAuthorAndPreservesTransportPeerMetadata() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let receivedAt = Date(timeIntervalSince1970: 1_700_000_001)

    let canonicalAuthor = Data(repeating: 0x11, count: 32)
    let message = MessageV1(
        createdAtUnixMs: 123,
        authorWayfarerId: canonicalAuthor,
        body: Data("hello".utf8)
    )
    let canonical = CanonicalEncoderV1.encode(message)
    let messageId = AethosIDs.messageId(canonicalBytes: canonical)

    try store.recordReceived(item: InboxItem(
        id: messageId,
        kind: .message,
        payload: canonical,
        receivedFromPeerId: String(repeating: "f", count: 64),
        receivedAt: receivedAt
    ))

    let stored = try store.getMessage(id: messageId)
    #expect(stored?.authorWayfarerId == Hex.encode(canonicalAuthor))
    #expect(stored?.receivedFromPeerId == String(repeating: "f", count: 64))
}

@Test
func recordMessageRejectsCanonicalAuthorMismatch() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let message = MessageV1(
        createdAtUnixMs: 200,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("x".utf8)
    )
    let canonical = CanonicalEncoderV1.encode(message)
    let messageId = AethosIDs.messageId(canonicalBytes: canonical)

    let forgedRow = AethosStore.MessageRow(
        messageId: messageId,
        kind: "message.v2",
        direction: .inbound,
        authorWayfarerId: String(repeating: "0", count: 64),
        receivedFromPeerId: String(repeating: "f", count: 64),
        peerTo: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_002),
        canonical: canonical
    )

    #expect(throws: AethosStore.StoreError.sqliteError("author_wayfarer_id must match canonical message author")) {
        try store.recordMessage(forgedRow)
    }
}

@Test
func recordReceivedRejectsMalformedMessageBeforeAnyDurableWrite() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let malformedCanonical = Data(hex: "01030100000008000000000000000103000000026869")

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.invalidType) {
        try store.recordReceived(item: InboxItem(
            id: Data(repeating: 0x01, count: 32),
            kind: .message,
            payload: malformedCanonical,
            receivedFromPeerId: String(repeating: "f", count: 64),
            receivedAt: Date()
        ))
    }

    #expect(try store.__debugRowCount(table: "inbox") == 0)
    #expect(try store.__debugRowCount(table: "messages") == 0)
}

@Test
func enqueueRejectsMalformedMessageBeforeAnyDurableWrite() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let store = try AethosStore(path: dir.appendingPathComponent("store.sqlite"))
    let malformedCanonical = Data(hex: "01030100000008000000000000000103000000026869")

    #expect(throws: CanonicalEncoderV1.CanonicalDecoderError.invalidType) {
        try store.enqueue(item: OutboxItem(
            id: Data(repeating: 0x01, count: 32),
            kind: .message,
            payload: malformedCanonical,
            enqueuedAt: Date()
        ))
    }

    #expect(try store.__debugRowCount(table: "outbox") == 0)
    #expect(try store.__debugRowCount(table: "messages") == 0)
}

@Test
func migrationV7ToV9PreservesExistingMessageRows() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let dbURL = dir.appendingPathComponent("store.sqlite")

    let author = String(repeating: "a", count: 64)
    let message = MessageV1(
        createdAtUnixMs: 123_456_789,
        authorWayfarerId: Data(repeating: 0xaa, count: 32),
        body: Data("hello".utf8)
    )
    let canonical = CanonicalEncoderV1.encode(message)
    let messageID = AethosIDs.messageId(canonicalBytes: canonical)

    var db: OpaquePointer?
    #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
    defer {
        if let db { sqlite3_close(db) }
    }
    guard let db else {
        Issue.record("failed to open sqlite handle")
        return
    }

    try sqliteExec(db, sql: """
    CREATE TABLE messages (
        message_id BLOB PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        direction TEXT NOT NULL,
        peer_from TEXT,
        peer_to TEXT,
        created_at INTEGER NOT NULL,
        canonical BLOB NOT NULL
    );
    """)

    let insertSQL = "INSERT INTO messages (message_id, kind, direction, peer_from, peer_to, created_at, canonical) VALUES (?, ?, ?, ?, ?, ?, ?);"
    var stmt: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK)
    guard let stmt else {
        Issue.record("failed to prepare sqlite insert")
        return
    }
    defer { sqlite3_finalize(stmt) }

    messageID.withUnsafeBytes { raw in
        _ = sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), sqliteTransient)
    }
    "message.v2".withCString { value in
        _ = sqlite3_bind_text(stmt, 2, value, -1, sqliteTransient)
    }
    "inbound".withCString { value in
        _ = sqlite3_bind_text(stmt, 3, value, -1, sqliteTransient)
    }
    author.withCString { value in
        _ = sqlite3_bind_text(stmt, 4, value, -1, sqliteTransient)
    }
    _ = sqlite3_bind_null(stmt, 5)
    _ = sqlite3_bind_int64(stmt, 6, 1_700_000_000)
    canonical.withUnsafeBytes { raw in
        _ = sqlite3_bind_blob(stmt, 7, raw.baseAddress, Int32(raw.count), sqliteTransient)
    }
    #expect(sqlite3_step(stmt) == SQLITE_DONE)

    try sqliteExec(db, sql: "PRAGMA user_version = 7;")

    let store = try AethosStore(path: dbURL)
    #expect(try store.__debugUserVersion() == 9)
    #expect(try store.__debugRowCount(table: "messages") == 1)

    let row = try store.getMessage(id: messageID)
    #expect(row?.authorWayfarerId == nil)
    #expect(row?.receivedFromPeerId == author)
}

@Test
func migrationV8ToV9ConvertsLegacyGossipObjectsToGossipItems() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let dbURL = dir.appendingPathComponent("store.sqlite")
    let itemID = Data((0..<32).map(UInt8.init))
    let envelopeBytes = Data([0xFA, 0xFB, 0xFC, 0xFD])
    let expiryUnixMs: Int64 = 4_102_444_800_000
    let hopCount: Int64 = 7

    var db: OpaquePointer?
    #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
    defer {
        if let db { sqlite3_close(db) }
    }
    guard let db else {
        Issue.record("failed to open sqlite handle")
        return
    }

    try sqliteExec(db, sql: """
    CREATE TABLE gossip_objects (
        item_id BLOB PRIMARY KEY NOT NULL,
        envelope_bytes BLOB NOT NULL,
        expiry_unix_ms INTEGER NOT NULL,
        hop_count INTEGER NOT NULL
    );
    """)

    var insert: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "INSERT INTO gossip_objects (item_id, envelope_bytes, expiry_unix_ms, hop_count) VALUES (?, ?, ?, ?);", -1, &insert, nil) == SQLITE_OK)
    guard let insert else {
        Issue.record("failed to prepare legacy gossip insert")
        return
    }
    defer { sqlite3_finalize(insert) }

    itemID.withUnsafeBytes { raw in
        _ = sqlite3_bind_blob(insert, 1, raw.baseAddress, Int32(raw.count), sqliteTransient)
    }
    envelopeBytes.withUnsafeBytes { raw in
        _ = sqlite3_bind_blob(insert, 2, raw.baseAddress, Int32(raw.count), sqliteTransient)
    }
    _ = sqlite3_bind_int64(insert, 3, expiryUnixMs)
    _ = sqlite3_bind_int64(insert, 4, hopCount)
    #expect(sqlite3_step(insert) == SQLITE_DONE)

    try sqliteExec(db, sql: "PRAGMA user_version = 8;")

    let migratedBefore = AethosStore.epochMilliseconds(Date())
    let store = try AethosStore(path: dbURL)
    let migratedAfter = AethosStore.epochMilliseconds(Date())

    #expect(try store.__debugUserVersion() == 9)
    #expect(try store.__debugRowCount(table: "gossip_items") == 1)
    #expect(try store.__debugRowCount(table: "gossip_objects") == 1)

    let migrated = try store.getGossipItem(itemID: itemID)
    #expect(migrated?.itemID == itemID)
    #expect(migrated?.envelopeBytes == envelopeBytes)
    #expect(migrated?.expiryUnixMs == expiryUnixMs)
    #expect(migrated?.hopCount == hopCount)
    if let recordedAtUnixMs = migrated?.recordedAtUnixMs {
        #expect(recordedAtUnixMs >= migratedBefore)
        #expect(recordedAtUnixMs <= migratedAfter)
    } else {
        Issue.record("missing migrated recorded_at_unix_ms")
    }

    var verifyDB: OpaquePointer?
    #expect(sqlite3_open(dbURL.path, &verifyDB) == SQLITE_OK)
    defer {
        if let verifyDB { sqlite3_close(verifyDB) }
    }
    guard let verifyDB else {
        Issue.record("failed to open sqlite verification handle")
        return
    }

    let expectedItemIDHex = Hex.encode(itemID)
    let expectedEnvelopeB64 = GossipV1Base64URL.encode(envelopeBytes)
    let textRow = try sqliteQuerySingleTextPair(
        verifyDB,
        sql: "SELECT item_id, envelope_b64 FROM gossip_items WHERE item_id = ? LIMIT 1;",
        bindText: expectedItemIDHex
    )
    #expect(textRow?.0 == expectedItemIDHex)
    #expect(textRow?.1 == expectedEnvelopeB64)

    let marker = try sqliteQuerySingleInt64(
        verifyDB,
        sql: "SELECT meta_value FROM gossip_meta WHERE meta_key = ? LIMIT 1;",
        bindText: "legacy_gossip_objects_to_items_migrated_v1"
    )
    #expect(marker == 1)

    _ = try AethosStore(path: dbURL)
    #expect(try store.__debugRowCount(table: "gossip_items") == 1)
}

private func sqliteExec(_ db: OpaquePointer, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    if rc != SQLITE_OK {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
        sqlite3_free(errorMessage)
        struct SQLiteExecError: Swift.Error {}
        Issue.record("sqlite exec failed: \(message)")
        throw SQLiteExecError()
    }
}

private func sqliteQuerySingleTextPair(_ db: OpaquePointer, sql: String, bindText: String) throws -> (String, String)? {
    var stmt: OpaquePointer?
    let prepareRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard prepareRC == SQLITE_OK, let stmt else {
        struct SQLiteQueryError: Swift.Error {}
        Issue.record("sqlite query prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        throw SQLiteQueryError()
    }
    defer { sqlite3_finalize(stmt) }

    bindText.withCString { value in
        _ = sqlite3_bind_text(stmt, 1, value, -1, sqliteTransient)
    }

    let rc = sqlite3_step(stmt)
    if rc == SQLITE_DONE {
        return nil
    }
    guard rc == SQLITE_ROW else {
        struct SQLiteQueryError: Swift.Error {}
        Issue.record("sqlite query step failed: \(String(cString: sqlite3_errmsg(db)))")
        throw SQLiteQueryError()
    }

    let first = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    let second = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
    guard let first, let second else {
        struct SQLiteQueryError: Swift.Error {}
        Issue.record("sqlite query returned NULL text column")
        throw SQLiteQueryError()
    }
    return (first, second)
}

private func sqliteQuerySingleInt64(_ db: OpaquePointer, sql: String, bindText: String) throws -> Int64? {
    var stmt: OpaquePointer?
    let prepareRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard prepareRC == SQLITE_OK, let stmt else {
        struct SQLiteQueryError: Swift.Error {}
        Issue.record("sqlite query prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        throw SQLiteQueryError()
    }
    defer { sqlite3_finalize(stmt) }

    bindText.withCString { value in
        _ = sqlite3_bind_text(stmt, 1, value, -1, sqliteTransient)
    }

    let rc = sqlite3_step(stmt)
    if rc == SQLITE_DONE {
        return nil
    }
    guard rc == SQLITE_ROW else {
        struct SQLiteQueryError: Swift.Error {}
        Issue.record("sqlite query step failed: \(String(cString: sqlite3_errmsg(db)))")
        throw SQLiteQueryError()
    }
    return sqlite3_column_int64(stmt, 0)
}

private extension Data {
    init(hex: String) {
        var bytes = Data()
        bytes.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            let slice = hex[index..<next]
            let byte = UInt8(slice, radix: 16)!
            bytes.append(byte)
            index = next
        }

        self = bytes
    }
}
