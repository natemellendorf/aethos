import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite3
#endif

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct OutboxItem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case envelope
        case manifest
        case receipt
    }

    public let id: Data
    public let kind: Kind
    public let payload: Data
    public let enqueuedAt: Date
    public let expiresAt: Date?

    public init(id: Data, kind: Kind, payload: Data, enqueuedAt: Date, expiresAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.enqueuedAt = enqueuedAt
        self.expiresAt = expiresAt
    }
}

public struct InboxItem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case envelope
        case manifest
        case receipt
    }

    public let id: Data
    public let kind: Kind
    public let payload: Data
    public let receivedAt: Date
    public let expiresAt: Date?

    public init(id: Data, kind: Kind, payload: Data, receivedAt: Date, expiresAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
    }
}

public struct EvictionCounts: Equatable, Sendable {
    public let chunks: Int
    public let outbox: Int
    public let inbox: Int

    public init(chunks: Int, outbox: Int, inbox: Int) {
        self.chunks = chunks
        self.outbox = outbox
        self.inbox = inbox
    }
}

public final class AethosStore {
    public enum StoreError: Swift.Error, Equatable {
        case openFailed(String)
        case sqliteError(String)
        case unsupportedSchemaVersion(Int)
    }

    private enum OutboxStatus: Int32 {
        case queued = 0
        case inFlight = 1
        case delivered = 2
        case acked = 3
    }

    private let db: OpaquePointer

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let rc = sqlite3_open(path.path, &handle)
        guard rc == SQLITE_OK, let handle else {
            throw StoreError.openFailed(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle

        // Pragmas
        _ = try? exec("PRAGMA foreign_keys = ON;")
        _ = try? exec("PRAGMA journal_mode = WAL;")
        sqlite3_busy_timeout(db, 5_000)

        try migrateIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: ChunkStore

    public func putChunk(id: Data, bytes: Data, receivedAt: Date) throws {
        try putChunk(id: id, bytes: bytes, receivedAt: receivedAt, expiresAt: nil)
    }

    public func putChunk(id: Data, bytes: Data, receivedAt: Date, expiresAt: Date?) throws {
        let sql = """
        INSERT OR IGNORE INTO chunks (id, bytes, received_at, expires_at)
        VALUES (?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindData(stmt, index: 1, data: id)
        try bindData(stmt, index: 2, data: bytes)
        try bindInt64(stmt, index: 3, value: Self.epochSeconds(receivedAt))
        try bindNullableInt64(stmt, index: 4, value: expiresAt.map(Self.epochSeconds))

        try stepDone(stmt)
    }

    public func getChunk(id: Data) throws -> Data? {
        let sql = "SELECT bytes FROM chunks WHERE id = ? LIMIT 1;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindData(stmt, index: 1, data: id)

        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            return columnData(stmt, index: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    // MARK: Outbox

    public func enqueue(item: OutboxItem) throws {
        let sql = """
        INSERT OR IGNORE INTO outbox (id, kind, payload, status, enqueued_at, updated_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let now = Self.epochSeconds(Date())

        try bindData(stmt, index: 1, data: item.id)
        try bindText(stmt, index: 2, text: item.kind.rawValue)
        try bindData(stmt, index: 3, data: item.payload)
        try bindInt32(stmt, index: 4, value: OutboxStatus.queued.rawValue)
        try bindInt64(stmt, index: 5, value: Self.epochSeconds(item.enqueuedAt))
        try bindInt64(stmt, index: 6, value: now)
        try bindNullableInt64(stmt, index: 7, value: item.expiresAt.map(Self.epochSeconds))

        try stepDone(stmt)
    }

    public func dequeueBatch(limit: Int) throws -> [OutboxItem] {
        guard limit > 0 else { return [] }
        try exec("BEGIN IMMEDIATE;")
        var didCommit = false
        defer {
            if !didCommit {
                _ = try? exec("ROLLBACK;")
            }
        }

        let selectSQL = """
        SELECT id, kind, payload, enqueued_at, expires_at
        FROM outbox
        WHERE status = ?
        ORDER BY enqueued_at ASC, rowid ASC
        LIMIT ?;
        """
        let selectStmt = try prepare(selectSQL)
        defer { sqlite3_finalize(selectStmt) }

        try bindInt32(selectStmt, index: 1, value: OutboxStatus.queued.rawValue)
        try bindInt32(selectStmt, index: 2, value: Int32(limit))

        var items: [OutboxItem] = []
        while true {
            let rc = sqlite3_step(selectStmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }

            guard let id = columnData(selectStmt, index: 0),
                  let kindText = columnText(selectStmt, index: 1),
                  let payload = columnData(selectStmt, index: 2)
            else {
                throw StoreError.sqliteError("Unexpected NULL column")
            }

            let enqueuedAt = Date(timeIntervalSince1970: TimeInterval(columnInt64(selectStmt, index: 3)))
            let expiresAtSeconds = columnNullableInt64(selectStmt, index: 4)
            let expiresAt = expiresAtSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }

            guard let kind = OutboxItem.Kind(rawValue: kindText) else {
                throw StoreError.sqliteError("Unknown outbox kind: \(kindText)")
            }

            items.append(OutboxItem(id: id, kind: kind, payload: payload, enqueuedAt: enqueuedAt, expiresAt: expiresAt))
        }

        if !items.isEmpty {
            let updateSQL = "UPDATE outbox SET status = ?, updated_at = ? WHERE id = ?;"
            let updateStmt = try prepare(updateSQL)
            defer { sqlite3_finalize(updateStmt) }
            let now = Self.epochSeconds(Date())

            for item in items {
                sqlite3_reset(updateStmt)
                sqlite3_clear_bindings(updateStmt)

                try bindInt32(updateStmt, index: 1, value: OutboxStatus.inFlight.rawValue)
                try bindInt64(updateStmt, index: 2, value: now)
                try bindData(updateStmt, index: 3, data: item.id)
                try stepDone(updateStmt)
            }
        }

        try exec("COMMIT;")
        didCommit = true
        return items
    }

    // Planning-only API: read queued outbox items without modifying store state.
    public func peekQueuedOutbox(limit: Int) throws -> [OutboxItem] {
        guard limit > 0 else { return [] }
        let sql = """
        SELECT id, kind, payload, enqueued_at, expires_at
        FROM outbox
        WHERE status = ?
        ORDER BY enqueued_at ASC, rowid ASC
        LIMIT ?;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindInt32(stmt, index: 1, value: OutboxStatus.queued.rawValue)
        try bindInt32(stmt, index: 2, value: Int32(limit))

        var items: [OutboxItem] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }

            guard let id = columnData(stmt, index: 0),
                  let kindText = columnText(stmt, index: 1),
                  let payload = columnData(stmt, index: 2)
            else {
                throw StoreError.sqliteError("Unexpected NULL column")
            }

            let enqueuedAt = Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 3)))
            let expiresAtSeconds = columnNullableInt64(stmt, index: 4)
            let expiresAt = expiresAtSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }

            guard let kind = OutboxItem.Kind(rawValue: kindText) else {
                throw StoreError.sqliteError("Unknown outbox kind: \(kindText)")
            }

            items.append(OutboxItem(id: id, kind: kind, payload: payload, enqueuedAt: enqueuedAt, expiresAt: expiresAt))
        }

        return items
    }

    public func markDelivered(itemId: Data) throws {
        try updateOutboxStatus(id: itemId, status: .delivered)
    }

    public func markAcked(envelopeId: Data) throws {
        try updateOutboxStatus(id: envelopeId, status: .acked)
    }

    // MARK: Inbox

    public func recordReceived(item: InboxItem) throws {
        let sql = """
        INSERT OR IGNORE INTO inbox (id, kind, payload, received_at, expires_at)
        VALUES (?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindData(stmt, index: 1, data: item.id)
        try bindText(stmt, index: 2, text: item.kind.rawValue)
        try bindData(stmt, index: 3, data: item.payload)
        try bindInt64(stmt, index: 4, value: Self.epochSeconds(item.receivedAt))
        try bindNullableInt64(stmt, index: 5, value: item.expiresAt.map(Self.epochSeconds))

        try stepDone(stmt)
    }

    // MARK: TTL + Eviction

    public func evictExpired(now: Date) throws -> EvictionCounts {
        let nowSec = Self.epochSeconds(now)
        let chunks = try deleteExpired(table: "chunks", nowSec: nowSec)
        let outbox = try deleteExpired(table: "outbox", nowSec: nowSec)
        let inbox = try deleteExpired(table: "inbox", nowSec: nowSec)
        return EvictionCounts(chunks: chunks, outbox: outbox, inbox: inbox)
    }

    // MARK: Transfers

    public func createTransfer(_ t: Transfer) throws {
        let sql = """
        INSERT OR IGNORE INTO transfers (
            transfer_id, direction, peer_from, peer_to,
            created_at, updated_at, last_activity_at, status,
            original_filename, bytes_total, bytes_sent, bytes_received,
            parts_total, parts_sent, parts_received,
            manifest_hash, payload_hash, verified, last_error
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let now = Self.epochSeconds(Date())
        try bindText(stmt, index: 1, text: t.transferId)
        try bindText(stmt, index: 2, text: t.direction.rawValue)
        try bindText(stmt, index: 3, text: t.peerFrom)
        try bindText(stmt, index: 4, text: t.peerTo)
        try bindInt64(stmt, index: 5, value: Self.epochSeconds(t.createdAt))
        try bindInt64(stmt, index: 6, value: Self.epochSeconds(t.updatedAt))
        try bindInt64(stmt, index: 7, value: Self.epochSeconds(t.lastActivityAt))
        try bindText(stmt, index: 8, text: t.status.rawValue)
        try bindNullableText(stmt, index: 9, text: t.originalFilename)
        try bindInt64(stmt, index: 10, value: t.bytesTotal)
        try bindInt64(stmt, index: 11, value: t.bytesSent)
        try bindInt64(stmt, index: 12, value: t.bytesReceived)
        try bindInt32(stmt, index: 13, value: t.partsTotal)
        try bindInt32(stmt, index: 14, value: t.partsSent)
        try bindInt32(stmt, index: 15, value: t.partsReceived)
        try bindNullableText(stmt, index: 16, text: t.manifestHash)
        try bindNullableText(stmt, index: 17, text: t.payloadHash)
        try bindInt32(stmt, index: 18, value: t.verified ? 1 : 0)
        try bindNullableText(stmt, index: 19, text: t.lastError)

        try stepDone(stmt)
    }

    public func updateTransfer(_ t: Transfer) throws {
        let sql = """
        UPDATE transfers SET
            status = ?, updated_at = ?, last_activity_at = ?,
            original_filename = ?, bytes_sent = ?, bytes_received = ?,
            parts_sent = ?, parts_received = ?,
            manifest_hash = ?, payload_hash = ?, verified = ?, last_error = ?
        WHERE transfer_id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindText(stmt, index: 1, text: t.status.rawValue)
        try bindInt64(stmt, index: 2, value: Self.epochSeconds(t.updatedAt))
        try bindInt64(stmt, index: 3, value: Self.epochSeconds(t.lastActivityAt))
        try bindNullableText(stmt, index: 4, text: t.originalFilename)
        try bindInt64(stmt, index: 5, value: t.bytesSent)
        try bindInt64(stmt, index: 6, value: t.bytesReceived)
        try bindInt32(stmt, index: 7, value: t.partsSent)
        try bindInt32(stmt, index: 8, value: t.partsReceived)
        try bindNullableText(stmt, index: 9, text: t.manifestHash)
        try bindNullableText(stmt, index: 10, text: t.payloadHash)
        try bindInt32(stmt, index: 11, value: t.verified ? 1 : 0)
        try bindNullableText(stmt, index: 12, text: t.lastError)
        try bindText(stmt, index: 13, text: t.transferId)

        try stepDone(stmt)
    }

    public func getTransfer(id: String) throws -> Transfer? {
        let sql = "SELECT * FROM transfers WHERE transfer_id = ? LIMIT 1;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: id)

        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            return try readTransferRow(stmt)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func getTransferByManifestHash(_ hash: String, direction: Transfer.Direction) throws -> Transfer? {
        let sql = "SELECT * FROM transfers WHERE manifest_hash = ? AND direction = ? LIMIT 1;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: hash)
        try bindText(stmt, index: 2, text: direction.rawValue)

        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            return try readTransferRow(stmt)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    public func listTransfers(direction: Transfer.Direction? = nil) throws -> [Transfer] {
        let sql: String
        if let direction {
            sql = "SELECT * FROM transfers WHERE direction = ? ORDER BY created_at DESC;"
        } else {
            sql = "SELECT * FROM transfers ORDER BY created_at DESC;"
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        if let direction {
            try bindText(stmt, index: 1, text: direction.rawValue)
        }

        var transfers: [Transfer] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            transfers.append(try readTransferRow(stmt))
        }
        return transfers
    }

    private func readTransferRow(_ stmt: OpaquePointer) throws -> Transfer {
        guard let transferId = columnText(stmt, index: 0),
              let directionStr = columnText(stmt, index: 1),
              let peerFrom = columnText(stmt, index: 2),
              let peerTo = columnText(stmt, index: 3),
              let statusStr = columnText(stmt, index: 7)
        else {
            throw StoreError.sqliteError("NULL in required transfer column")
        }

        guard let direction = Transfer.Direction(rawValue: directionStr) else {
            throw StoreError.sqliteError("Unknown transfer direction: \(directionStr)")
        }
        guard let status = Transfer.Status(rawValue: statusStr) else {
            throw StoreError.sqliteError("Unknown transfer status: \(statusStr)")
        }

        return Transfer(
            transferId: transferId,
            direction: direction,
            peerFrom: peerFrom,
            peerTo: peerTo,
            createdAt: Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 4))),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 5))),
            lastActivityAt: Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 6))),
            status: status,
            originalFilename: columnText(stmt, index: 8),
            bytesTotal: columnInt64(stmt, index: 9),
            bytesSent: columnInt64(stmt, index: 10),
            bytesReceived: columnInt64(stmt, index: 11),
            partsTotal: Int32(columnInt64(stmt, index: 12)),
            partsSent: Int32(columnInt64(stmt, index: 13)),
            partsReceived: Int32(columnInt64(stmt, index: 14)),
            manifestHash: columnText(stmt, index: 15),
            payloadHash: columnText(stmt, index: 16),
            verified: columnInt64(stmt, index: 17) != 0,
            lastError: columnText(stmt, index: 18)
        )
    }

    // MARK: Schema

    private func migrateIfNeeded() throws {
        let version = try userVersion()
        switch version {
        case 0:
            try exec("""
            CREATE TABLE IF NOT EXISTS chunks (
                id BLOB PRIMARY KEY NOT NULL,
                bytes BLOB NOT NULL,
                received_at INTEGER NOT NULL,
                expires_at INTEGER
            );

            CREATE TABLE IF NOT EXISTS outbox (
                id BLOB PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                payload BLOB NOT NULL,
                status INTEGER NOT NULL,
                enqueued_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                expires_at INTEGER
            );

            CREATE INDEX IF NOT EXISTS outbox_status_enqueued_idx
            ON outbox(status, enqueued_at);

            CREATE TABLE IF NOT EXISTS inbox (
                id BLOB PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                payload BLOB NOT NULL,
                received_at INTEGER NOT NULL,
                expires_at INTEGER
            );
            """)
            try migrateV1toV2()
            try exec("PRAGMA user_version = 2;")
        case 1:
            try migrateV1toV2()
            try exec("PRAGMA user_version = 2;")
        case 2:
            return
        default:
            throw StoreError.unsupportedSchemaVersion(version)
        }
    }

    private func migrateV1toV2() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS transfers (
            transfer_id TEXT PRIMARY KEY NOT NULL,
            direction TEXT NOT NULL,
            peer_from TEXT NOT NULL,
            peer_to TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            last_activity_at INTEGER NOT NULL,
            status TEXT NOT NULL,
            original_filename TEXT,
            bytes_total INTEGER NOT NULL DEFAULT 0,
            bytes_sent INTEGER NOT NULL DEFAULT 0,
            bytes_received INTEGER NOT NULL DEFAULT 0,
            parts_total INTEGER NOT NULL DEFAULT 0,
            parts_sent INTEGER NOT NULL DEFAULT 0,
            parts_received INTEGER NOT NULL DEFAULT 0,
            manifest_hash TEXT,
            payload_hash TEXT,
            verified INTEGER NOT NULL DEFAULT 0,
            last_error TEXT
        );

        CREATE INDEX IF NOT EXISTS transfers_status_idx ON transfers(status);
        CREATE INDEX IF NOT EXISTS transfers_manifest_hash_idx ON transfers(manifest_hash);
        CREATE INDEX IF NOT EXISTS transfers_direction_idx ON transfers(direction);
        """)
    }

    private func userVersion() throws -> Int {
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqliteError() }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: Helpers

    private static func epochSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private func deleteExpired(table: String, nowSec: Int64) throws -> Int {
        let sql = "DELETE FROM \(table) WHERE expires_at IS NOT NULL AND expires_at <= ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindInt64(stmt, index: 1, value: nowSec)
        try stepDone(stmt)
        return Int(sqlite3_changes(db))
    }

    private func updateOutboxStatus(id: Data, status: OutboxStatus) throws {
        let sql = "UPDATE outbox SET status = ?, updated_at = ? WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindInt32(stmt, index: 1, value: status.rawValue)
        try bindInt64(stmt, index: 2, value: Self.epochSeconds(Date()))
        try bindData(stmt, index: 3, data: id)
        try stepDone(stmt)
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(err)
            throw StoreError.sqliteError(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw sqliteError() }
        return stmt
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw sqliteError() }
    }

    private func sqliteError() -> StoreError {
        StoreError.sqliteError(String(cString: sqlite3_errmsg(db)))
    }

    private func bindInt32(_ stmt: OpaquePointer, index: Int32, value: Int32) throws {
        guard sqlite3_bind_int(stmt, index, value) == SQLITE_OK else { throw sqliteError() }
    }

    private func bindInt64(_ stmt: OpaquePointer, index: Int32, value: Int64) throws {
        guard sqlite3_bind_int64(stmt, index, value) == SQLITE_OK else { throw sqliteError() }
    }

    private func bindNullableInt64(_ stmt: OpaquePointer, index: Int32, value: Int64?) throws {
        if let value {
            try bindInt64(stmt, index: index, value: value)
        } else {
            guard sqlite3_bind_null(stmt, index) == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, text: String) throws {
        guard sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT) == SQLITE_OK else { throw sqliteError() }
    }

    private func bindNullableText(_ stmt: OpaquePointer, index: Int32, text: String?) throws {
        if let text {
            try bindText(stmt, index: index, text: text)
        } else {
            guard sqlite3_bind_null(stmt, index) == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func bindData(_ stmt: OpaquePointer, index: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.baseAddress
            let rc = sqlite3_bind_blob(stmt, index, base, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            guard rc == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func columnInt64(_ stmt: OpaquePointer, index: Int32) -> Int64 {
        sqlite3_column_int64(stmt, index)
    }

    private func columnNullableInt64(_ stmt: OpaquePointer, index: Int32) -> Int64? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    private func columnText(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func columnData(_ stmt: OpaquePointer, index: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, index) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: ptr, count: len)
    }

    // MARK: Test helpers

    func __debugRowCount(table: String) throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM \(table);")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqliteError() }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
