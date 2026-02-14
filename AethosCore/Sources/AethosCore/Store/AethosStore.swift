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
        case inventory
        case inventoryRequest = "inventory_request"
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
        case inventory
        case inventoryRequest = "inventory_request"
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

    public func deleteChunks(ids: [Data]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var deleted = 0
        let sql = "DELETE FROM chunks WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bindData(stmt, index: 1, data: id)
            try stepDone(stmt)
            deleted += Int(sqlite3_changes(db))
        }
        return deleted
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

    public func deleteOutboxByIds(_ ids: [Data]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var deleted = 0
        let sql = "DELETE FROM outbox WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bindData(stmt, index: 1, data: id)
            try stepDone(stmt)
            deleted += Int(sqlite3_changes(db))
        }
        return deleted
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

    public func listInboxByKind(_ kind: InboxItem.Kind) throws -> [InboxItem] {
        let sql = "SELECT id, kind, payload, received_at, expires_at FROM inbox WHERE kind = ? ORDER BY received_at ASC;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: kind.rawValue)

        var items: [InboxItem] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }

            guard let id = columnData(stmt, index: 0),
                  let kindText = columnText(stmt, index: 1),
                  let payload = columnData(stmt, index: 2)
            else {
                throw StoreError.sqliteError("Unexpected NULL column in inbox")
            }
            let receivedAt = Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 3)))
            let expiresAtSec = columnNullableInt64(stmt, index: 4)
            let expiresAt = expiresAtSec.map { Date(timeIntervalSince1970: TimeInterval($0)) }

            guard let k = InboxItem.Kind(rawValue: kindText) else {
                throw StoreError.sqliteError("Unknown inbox kind: \(kindText)")
            }
            items.append(InboxItem(id: id, kind: k, payload: payload, receivedAt: receivedAt, expiresAt: expiresAt))
        }
        return items
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
            manifest_hash, payload_hash, verified, last_error,
            custody, ttl_seconds, expires_at, completed_at, evicted
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

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
        try bindText(stmt, index: 20, text: t.custody.rawValue)
        try bindNullableInt64(stmt, index: 21, value: t.ttlSeconds)
        try bindNullableInt64(stmt, index: 22, value: t.expiresAt.map(Self.epochSeconds))
        try bindNullableInt64(stmt, index: 23, value: t.completedAt.map(Self.epochSeconds))
        try bindInt32(stmt, index: 24, value: t.evicted ? 1 : 0)

        try stepDone(stmt)
    }

    public func updateTransfer(_ t: Transfer) throws {
        let sql = """
        UPDATE transfers SET
            status = ?, updated_at = ?, last_activity_at = ?,
            original_filename = ?, bytes_sent = ?, bytes_received = ?,
            parts_sent = ?, parts_received = ?,
            manifest_hash = ?, payload_hash = ?, verified = ?, last_error = ?,
            custody = ?, ttl_seconds = ?, expires_at = ?, completed_at = ?, evicted = ?
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
        try bindText(stmt, index: 13, text: t.custody.rawValue)
        try bindNullableInt64(stmt, index: 14, value: t.ttlSeconds)
        try bindNullableInt64(stmt, index: 15, value: t.expiresAt.map(Self.epochSeconds))
        try bindNullableInt64(stmt, index: 16, value: t.completedAt.map(Self.epochSeconds))
        try bindInt32(stmt, index: 17, value: t.evicted ? 1 : 0)
        try bindText(stmt, index: 18, text: t.transferId)

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

        // v3 columns (indices 19-23)
        let custodyStr = columnText(stmt, index: 19) ?? (direction == .outbound ? "origin" : "inbound")
        let custody = Transfer.Custody(rawValue: custodyStr) ?? (direction == .outbound ? .origin : .inbound)
        let ttlSeconds = columnNullableInt64(stmt, index: 20)
        let expiresAtSec = columnNullableInt64(stmt, index: 21)
        let expiresAt = expiresAtSec.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let completedAtSec = columnNullableInt64(stmt, index: 22)
        let completedAt = completedAtSec.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let evicted = columnInt64(stmt, index: 23) != 0

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
            lastError: columnText(stmt, index: 18),
            custody: custody,
            ttlSeconds: ttlSeconds,
            expiresAt: expiresAt,
            completedAt: completedAt,
            evicted: evicted
        )
    }

    // MARK: Inventory

    /// Returns manifest_hash hex strings for transfers that are active
    /// (not evicted, not failed), respecting custody rules.
    public func listActiveManifestHashes() throws -> [String] {
        let sql = """
        SELECT DISTINCT manifest_hash FROM transfers
        WHERE manifest_hash IS NOT NULL
        AND evicted = 0
        AND status NOT IN ('failed', 'canceled')
        ORDER BY manifest_hash ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var hashes: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            if let hash = columnText(stmt, index: 0) {
                hashes.append(hash)
            }
        }
        return hashes
    }

    /// Returns manifest hashes suitable for advertising: not evicted, not expired,
    /// not failed/canceled, up to `limit` results.
    public func listAdvertisableManifestHashes(limit: Int, now: Date) throws -> [String] {
        let nowSec = Self.epochSeconds(now)
        let sql = """
        SELECT DISTINCT manifest_hash FROM transfers
        WHERE manifest_hash IS NOT NULL
        AND evicted = 0
        AND status NOT IN ('failed', 'canceled')
        AND (expires_at IS NULL OR expires_at > ?)
        ORDER BY manifest_hash ASC
        LIMIT ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindInt64(stmt, index: 1, value: nowSec)
        try bindInt32(stmt, index: 2, value: Int32(min(limit, Int(Int32.max))))

        var hashes: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            if let hash = columnText(stmt, index: 0) {
                hashes.append(hash)
            }
        }
        return hashes
    }

    /// Returns the total count of advertisable manifest hashes (for truncation detection).
    public func countAdvertisableManifestHashes(now: Date) throws -> Int {
        let nowSec = Self.epochSeconds(now)
        let sql = """
        SELECT COUNT(DISTINCT manifest_hash) FROM transfers
        WHERE manifest_hash IS NOT NULL
        AND evicted = 0
        AND status NOT IN ('failed', 'canceled')
        AND (expires_at IS NULL OR expires_at > ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindInt64(stmt, index: 1, value: nowSec)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqliteError() }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Returns true if the given manifest_hash hex exists in an active transfer.
    public func hasManifest(_ hash: String) throws -> Bool {
        let sql = """
        SELECT 1 FROM transfers
        WHERE manifest_hash = ?
        AND evicted = 0
        AND status NOT IN ('failed', 'canceled')
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: hash)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Look up active transfers matching any of the given manifest_hash hex strings.
    public func lookupTransfersByManifestHashes(_ hashes: [String]) throws -> [Transfer] {
        guard !hashes.isEmpty else { return [] }
        var transfers: [Transfer] = []
        let sql = """
        SELECT * FROM transfers
        WHERE manifest_hash = ?
        AND evicted = 0
        AND status NOT IN ('failed', 'canceled');
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for hash in hashes {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bindText(stmt, index: 1, text: hash)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                if rc != SQLITE_ROW { throw sqliteError() }
                transfers.append(try readTransferRow(stmt))
            }
        }
        return transfers
    }

    // MARK: Custody + Eviction

    /// Total bytes held for relay transfers (not yet evicted or completed).
    public func relayCacheBytes() throws -> Int64 {
        let sql = """
        SELECT COALESCE(SUM(bytes_total), 0) FROM transfers
        WHERE custody = 'relay' AND evicted = 0 AND status NOT IN ('complete', 'failed', 'canceled');
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqliteError() }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Evict transfers whose TTL has expired. Marks them evicted but does not
    /// remove chunk/outbox data (caller should use the returned IDs to clean up).
    /// Inbound transfers are never TTL-evicted.
    public func evictExpiredTransfers(now: Date) throws -> [String] {
        let nowSec = Self.epochSeconds(now)
        let selectSQL = """
        SELECT transfer_id FROM transfers
        WHERE evicted = 0 AND expires_at IS NOT NULL AND expires_at <= ?
        AND custody != 'inbound';
        """
        let selectStmt = try prepare(selectSQL)
        defer { sqlite3_finalize(selectStmt) }
        try bindInt64(selectStmt, index: 1, value: nowSec)

        var ids: [String] = []
        while true {
            let rc = sqlite3_step(selectStmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            if let tid = columnText(selectStmt, index: 0) {
                ids.append(tid)
            }
        }

        if !ids.isEmpty {
            try markTransfersEvicted(ids: ids, now: now)
        }
        return ids
    }

    /// Evict relay transfers under cache pressure. Evicts oldest relay transfers
    /// first until total relay cache bytes <= maxCacheBytes.
    /// Returns IDs of evicted transfers.
    public func evictRelayTransfers(maxCacheBytes: Int64, now: Date) throws -> [String] {
        let currentBytes = try relayCacheBytes()
        guard currentBytes > maxCacheBytes else { return [] }

        // Select active relay transfers ordered by oldest first.
        let sql = """
        SELECT transfer_id, bytes_total FROM transfers
        WHERE custody = 'relay' AND evicted = 0 AND status NOT IN ('complete', 'failed', 'canceled')
        ORDER BY created_at ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var evictIds: [String] = []
        var remaining = currentBytes
        while remaining > maxCacheBytes {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            guard let tid = columnText(stmt, index: 0) else { continue }
            let bytes = sqlite3_column_int64(stmt, 1)
            evictIds.append(tid)
            remaining -= bytes
        }

        if !evictIds.isEmpty {
            try markTransfersEvicted(ids: evictIds, now: now)
        }
        return evictIds
    }

    /// GC completed outbound (origin) transfers after a grace period.
    /// Returns IDs of GC'd transfers.
    public func gcCompletedTransfers(graceSeconds: Int64, now: Date) throws -> [String] {
        let nowSec = Self.epochSeconds(now)
        let cutoff = nowSec - graceSeconds
        let sql = """
        SELECT transfer_id FROM transfers
        WHERE custody = 'origin' AND status = 'complete' AND evicted = 0
        AND completed_at IS NOT NULL AND completed_at <= ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindInt64(stmt, index: 1, value: cutoff)

        var ids: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            if let tid = columnText(stmt, index: 0) {
                ids.append(tid)
            }
        }

        if !ids.isEmpty {
            try markTransfersEvicted(ids: ids, now: now)
        }
        return ids
    }

    /// Get manifest hashes for a list of transfer IDs (for cleanup).
    public func getManifestHashes(transferIds: [String]) throws -> [String] {
        guard !transferIds.isEmpty else { return [] }
        var hashes: [String] = []
        let sql = "SELECT manifest_hash FROM transfers WHERE transfer_id = ? AND manifest_hash IS NOT NULL;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for tid in transferIds {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bindText(stmt, index: 1, text: tid)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW, let hash = columnText(stmt, index: 0) {
                hashes.append(hash)
            }
        }
        return hashes
    }

    private func markTransfersEvicted(ids: [String], now: Date) throws {
        let nowSec = Self.epochSeconds(now)
        let sql = "UPDATE transfers SET evicted = 1, status = 'canceled', updated_at = ? WHERE transfer_id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for tid in ids {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bindInt64(stmt, index: 1, value: nowSec)
            try bindText(stmt, index: 2, text: tid)
            try stepDone(stmt)
        }
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
            try migrateV2toV3()
            try exec("PRAGMA user_version = 3;")
        case 1:
            try migrateV1toV2()
            try migrateV2toV3()
            try exec("PRAGMA user_version = 3;")
        case 2:
            try migrateV2toV3()
            try exec("PRAGMA user_version = 3;")
        case 3:
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

    private func migrateV2toV3() throws {
        // Add custody, TTL, and eviction columns to the transfers table.
        // Default custody is 'origin' for existing rows (all existing are outbound-created).
        try exec("ALTER TABLE transfers ADD COLUMN custody TEXT NOT NULL DEFAULT 'origin';")
        try exec("ALTER TABLE transfers ADD COLUMN ttl_seconds INTEGER;")
        try exec("ALTER TABLE transfers ADD COLUMN expires_at INTEGER;")
        try exec("ALTER TABLE transfers ADD COLUMN completed_at INTEGER;")
        try exec("ALTER TABLE transfers ADD COLUMN evicted INTEGER NOT NULL DEFAULT 0;")

        // Index for eviction queries.
        try exec("CREATE INDEX IF NOT EXISTS transfers_custody_idx ON transfers(custody);")
        try exec("CREATE INDEX IF NOT EXISTS transfers_evicted_idx ON transfers(evicted);")
        try exec("CREATE INDEX IF NOT EXISTS transfers_expires_at_idx ON transfers(expires_at);")

        // Backfill: set custody based on direction for existing rows.
        try exec("UPDATE transfers SET custody = 'inbound' WHERE direction = 'inbound' AND custody = 'origin';")
    }

    private func userVersion() throws -> Int {
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqliteError() }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: Helpers

    static func epochSeconds(_ date: Date) -> Int64 {
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

    func __debugUserVersion() throws -> Int {
        try userVersion()
    }
}
