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

    // Query all outbox items (any status) for a given kind, ordered by enqueue time.
    public func listOutbox(kind: OutboxItem.Kind, limit: Int) throws -> [(item: OutboxItem, status: String)] {
        guard limit > 0 else { return [] }
        let sql = """
        SELECT id, kind, payload, status, enqueued_at, expires_at
        FROM outbox
        WHERE kind = ?
        ORDER BY enqueued_at ASC
        LIMIT ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindText(stmt, index: 1, text: kind.rawValue)
        try bindInt32(stmt, index: 2, value: Int32(limit))

        var results: [(item: OutboxItem, status: String)] = []
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

            let statusRaw = sqlite3_column_int(stmt, 3)
            let statusName: String
            switch OutboxStatus(rawValue: statusRaw) {
            case .queued:    statusName = "queued"
            case .inFlight:  statusName = "sending"
            case .delivered: statusName = "delivered"
            case .acked:     statusName = "acked"
            case .none:      statusName = "unknown"
            }

            let enqueuedAt = Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 4)))
            let expiresAtSeconds = columnNullableInt64(stmt, index: 5)
            let expiresAt = expiresAtSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }

            guard let k = OutboxItem.Kind(rawValue: kindText) else {
                throw StoreError.sqliteError("Unknown outbox kind: \(kindText)")
            }

            let item = OutboxItem(id: id, kind: k, payload: payload, enqueuedAt: enqueuedAt, expiresAt: expiresAt)
            results.append((item: item, status: statusName))
        }
        return results
    }

    // Check whether a chunk exists in the store (without reading bytes).
    public func hasChunk(id: Data) throws -> Bool {
        let sql = "SELECT 1 FROM chunks WHERE id = ? LIMIT 1;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindData(stmt, index: 1, data: id)
        return sqlite3_step(stmt) == SQLITE_ROW
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
            try exec("PRAGMA user_version = 1;")
        case 1:
            return
        default:
            throw StoreError.unsupportedSchemaVersion(version)
        }
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
