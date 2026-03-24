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
        case message
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
        case message
    }

    public let id: Data
    public let kind: Kind
    public let payload: Data
    public let receivedFromPeerId: String?
    public let receivedAt: Date
    public let expiresAt: Date?

    public init(
        id: Data,
        kind: Kind,
        payload: Data,
        receivedFromPeerId: String? = nil,
        receivedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.receivedFromPeerId = receivedFromPeerId
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

/// Snapshot of current Aethos status for iOS integration.
/// Provides a summary of peers, transfers, and custody for UI display.
public struct StatusSnapshot: Codable, Equatable, Sendable {
    public let peerIdentifiers: [String]
    public let transfersSummary: TransfersSummary
    public let custodySummary: CustodySummary

    public struct TransfersSummary: Codable, Equatable, Sendable {
        public let incoming: Int
        public let outgoing: Int
        public let pending: Int

        public init(incoming: Int, outgoing: Int, pending: Int) {
            self.incoming = incoming
            self.outgoing = outgoing
            self.pending = pending
        }
    }

    public struct CustodySummary: Codable, Equatable, Sendable {
        public let totalSize: Int64
        public let fileCount: Int

        public init(totalSize: Int64, fileCount: Int) {
            self.totalSize = totalSize
            self.fileCount = fileCount
        }
    }

    public init(
        peerIdentifiers: [String],
        transfersSummary: TransfersSummary,
        custodySummary: CustodySummary
    ) {
        self.peerIdentifiers = peerIdentifiers
        self.transfersSummary = transfersSummary
        self.custodySummary = custodySummary
    }
}

public final class AethosStore {
    public enum StoreError: Swift.Error, Equatable {
        case openFailed(String)
        case sqliteError(String)
        case unsupportedSchemaVersion(Int)
    }

    public struct MessageRow: Equatable, Sendable {
        public enum Direction: String, Sendable {
            case inbound
            case outbound
        }

        public let messageId: Data
        public let kind: String
        public let direction: Direction
        public let authorWayfarerId: String?
        public let receivedFromPeerId: String?
        public let peerTo: String?
        public let createdAt: Date
        public let canonical: Data

        public init(
            messageId: Data,
            kind: String,
            direction: Direction,
            authorWayfarerId: String?,
            receivedFromPeerId: String?,
            peerTo: String?,
            createdAt: Date,
            canonical: Data
        ) {
            self.messageId = messageId
            self.kind = kind
            self.direction = direction
            self.authorWayfarerId = authorWayfarerId
            self.receivedFromPeerId = receivedFromPeerId
            self.peerTo = peerTo
            self.createdAt = createdAt
            self.canonical = canonical
        }
    }

    private enum OutboxStatus: Int32 {
        case queued = 0
        case inFlight = 1
        case delivered = 2
        case acked = 3
    }

    struct QueuedOutboxEnvelopeRow: Equatable, Sendable {
        let payload: Data
        let expiryUnixMs: UInt64
    }

    struct GossipItemRow: Equatable, Sendable {
        let itemID: Data
        let envelopeBytes: Data
        let expiryUnixMs: Int64
        let hopCount: Int64
        let recordedAtUnixMs: Int64
    }

    private let db: OpaquePointer

    // MARK: Schema version

    private static let currentSchemaVersion: Int = 9
    private static let legacyGossipObjectsMigrationMarker = "legacy_gossip_objects_to_items_migrated_v1"

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
        _ = try? exec("PRAGMA synchronous = FULL;")
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
        let decodedMessage: MessageV1?
        if item.kind == .message {
            decodedMessage = try CanonicalEncoderV1.decodeMessage(canonical: item.payload)
        } else {
            decodedMessage = nil
        }

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

        // Messages are durable protocol objects; record them as outbound.
        if let message = decodedMessage {
            try recordMessage(MessageRow(
                messageId: item.id,
                kind: "message.v2",
                direction: .outbound,
                authorWayfarerId: Hex.encode(message.authorWayfarerId),
                receivedFromPeerId: nil,
                peerTo: nil,
                createdAt: item.enqueuedAt,
                canonical: item.payload
            ))
        }
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

    func getQueuedOutboxEnvelope(itemID: Data) throws -> QueuedOutboxEnvelopeRow? {
        let sql = """
        SELECT payload, expires_at
        FROM outbox
        WHERE id = ? AND kind = ? AND status = ?
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindData(stmt, index: 1, data: itemID)
        try bindText(stmt, index: 2, text: OutboxItem.Kind.envelope.rawValue)
        try bindInt32(stmt, index: 3, value: OutboxStatus.queued.rawValue)

        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            guard let payload = columnData(stmt, index: 0) else {
                throw StoreError.sqliteError("Unexpected NULL payload in outbox")
            }

            let expiryUnixMs: UInt64
            if let expirySeconds = columnNullableInt64(stmt, index: 1) {
                guard expirySeconds >= 0 else {
                    throw StoreError.sqliteError("Invalid negative expires_at in outbox")
                }
                let clampedSeconds = UInt64(expirySeconds)
                if clampedSeconds > (UInt64.max / 1000) {
                    expiryUnixMs = UInt64.max
                } else {
                    expiryUnixMs = clampedSeconds * 1000
                }
            } else {
                expiryUnixMs = UInt64.max
            }

            return QueuedOutboxEnvelopeRow(payload: payload, expiryUnixMs: expiryUnixMs)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    func listQueuedOutboxEnvelopeItemIDs(eligibleAfterUnixMs cutoffUnixMs: Int64) throws -> [GossipV1ItemID] {
        let sql = """
        SELECT id
        FROM outbox
        WHERE kind = ?
        AND status = ?
        AND (expires_at IS NULL OR (expires_at * 1000) > ?)
        ORDER BY id ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: OutboxItem.Kind.envelope.rawValue)
        try bindInt32(stmt, index: 2, value: OutboxStatus.queued.rawValue)
        try bindInt64(stmt, index: 3, value: cutoffUnixMs)

        var ids: [GossipV1ItemID] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            guard let itemBytes = columnData(stmt, index: 0) else {
                throw StoreError.sqliteError("Unexpected NULL id in outbox")
            }
            guard let itemID = try? GossipV1ItemID(bytes: itemBytes) else {
                throw StoreError.sqliteError("Invalid outbox envelope item_id length")
            }
            ids.append(itemID)
        }
        return ids
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
        let decodedMessage: MessageV1?
        if item.kind == .message {
            decodedMessage = try CanonicalEncoderV1.decodeMessage(canonical: item.payload)
        } else {
            decodedMessage = nil
        }

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

        // Messages are durable protocol objects; record them as inbound.
        if let message = decodedMessage {
            try recordMessage(MessageRow(
                messageId: item.id,
                kind: "message.v2",
                direction: .inbound,
                authorWayfarerId: Hex.encode(message.authorWayfarerId),
                receivedFromPeerId: item.receivedFromPeerId,
                peerTo: nil,
                createdAt: item.receivedAt,
                canonical: item.payload
            ))
        }
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
            peer_to = ?, status = ?, updated_at = ?, last_activity_at = ?,
            original_filename = ?, bytes_sent = ?, bytes_received = ?,
            parts_sent = ?, parts_received = ?,
            manifest_hash = ?, payload_hash = ?, verified = ?, last_error = ?,
            custody = ?, ttl_seconds = ?, expires_at = ?, completed_at = ?, evicted = ?
        WHERE transfer_id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindText(stmt, index: 1, text: t.peerTo)
        try bindText(stmt, index: 2, text: t.status.rawValue)
        try bindInt64(stmt, index: 3, value: Self.epochSeconds(t.updatedAt))
        try bindInt64(stmt, index: 4, value: Self.epochSeconds(t.lastActivityAt))
        try bindNullableText(stmt, index: 5, text: t.originalFilename)
        try bindInt64(stmt, index: 6, value: t.bytesSent)
        try bindInt64(stmt, index: 7, value: t.bytesReceived)
        try bindInt32(stmt, index: 8, value: t.partsSent)
        try bindInt32(stmt, index: 9, value: t.partsReceived)
        try bindNullableText(stmt, index: 10, text: t.manifestHash)
        try bindNullableText(stmt, index: 11, text: t.payloadHash)
        try bindInt32(stmt, index: 12, value: t.verified ? 1 : 0)
        try bindNullableText(stmt, index: 13, text: t.lastError)
        try bindText(stmt, index: 14, text: t.custody.rawValue)
        try bindNullableInt64(stmt, index: 15, value: t.ttlSeconds)
        try bindNullableInt64(stmt, index: 16, value: t.expiresAt.map(Self.epochSeconds))
        try bindNullableInt64(stmt, index: 17, value: t.completedAt.map(Self.epochSeconds))
        try bindInt32(stmt, index: 18, value: t.evicted ? 1 : 0)
        try bindText(stmt, index: 19, text: t.transferId)

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

    /// Returns counts of transfers by direction and pending status.
    /// Pending includes queued, sending, and receiving statuses.
    public func getTransferCounts() throws -> StatusSnapshot.TransfersSummary {
        let allTransfers = try listTransfers()
        var incoming = 0
        var outgoing = 0
        var pending = 0

        let pendingStatuses: Set<Transfer.Status> = [.queued, .sending, .receiving]

        for transfer in allTransfers {
            switch transfer.direction {
            case .inbound:
                incoming += 1
            case .outbound:
                outgoing += 1
            }
            if pendingStatuses.contains(transfer.status) && !transfer.evicted {
                pending += 1
            }
        }

        return StatusSnapshot.TransfersSummary(
            incoming: incoming,
            outgoing: outgoing,
            pending: pending
        )
    }

    /// Returns a snapshot of current Aethos status including peers, transfers, and custody.
    public func statusSnapshot() throws -> StatusSnapshot {
        let now = Int64(Date().timeIntervalSince1970)

        // Get peer identifiers
        let peers = try listPeers(limit: 1000, now: now)
        let peerIdentifiers = peers.map { $0.wayfarerId }

        // Get transfer counts
        let transfersSummary = try getTransferCounts()

        // Get custody summary
        let totalRelayBytes = try relayCacheBytes()
        let relayCount = try countForwardableRelayTransfers(now: Date())

        let custodySummary = StatusSnapshot.CustodySummary(
            totalSize: totalRelayBytes,
            fileCount: relayCount
        )

        return StatusSnapshot(
            peerIdentifiers: peerIdentifiers,
            transfersSummary: transfersSummary,
            custodySummary: custodySummary
        )
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

    /// Lists relay custody transfers, optionally filtering to active-only
    /// (not evicted, not expired, not failed/canceled).
    public func listRelayTransfers(activeOnly: Bool, now: Date) throws -> [Transfer] {
        let sql: String
        if activeOnly {
            let nowSec = Self.epochSeconds(now)
            sql = """
            SELECT * FROM transfers
            WHERE custody = 'relay' AND evicted = 0
            AND status NOT IN ('failed', 'canceled')
            AND (expires_at IS NULL OR expires_at > \(nowSec))
            ORDER BY created_at DESC;
            """
        } else {
            sql = "SELECT * FROM transfers WHERE custody = 'relay' ORDER BY created_at DESC;"
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var transfers: [Transfer] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            transfers.append(try readTransferRow(stmt))
        }
        return transfers
    }

    /// Count of relay transfers that are forwardable (not evicted, not expired, not failed/canceled).
    public func countForwardableRelayTransfers(now: Date) throws -> Int {
        let nowSec = Self.epochSeconds(now)
        let sql = """
        SELECT COUNT(*) FROM transfers
        WHERE custody = 'relay' AND evicted = 0
        AND status NOT IN ('failed', 'canceled')
        AND (expires_at IS NULL OR expires_at > ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindInt64(stmt, index: 1, value: nowSec)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqliteError() }
        return Int(sqlite3_column_int(stmt, 0))
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

    func upsertGossipItem(itemID: Data, envelopeBytes: Data, expiryUnixMs: Int64, hopCount: Int64, recordedAtUnixMs: Int64? = nil) throws {
        let effectiveRecordedAtUnixMs = recordedAtUnixMs ?? Self.epochMilliseconds(Date())

        guard itemID.count == 32 else {
            throw StoreError.sqliteError("gossip_items.item_id must be 32 bytes")
        }
        guard expiryUnixMs >= 0 else {
            throw StoreError.sqliteError("gossip_items.expiry_unix_ms must be >= 0")
        }
        guard (0...Int64(UInt16.max)).contains(hopCount) else {
            throw StoreError.sqliteError("gossip_items.hop_count must be in 0...65535")
        }
        guard effectiveRecordedAtUnixMs >= 0 else {
            throw StoreError.sqliteError("gossip_items.recorded_at_unix_ms must be >= 0")
        }

        let itemIDHex = Hex.encode(itemID)
        let envelopeB64 = GossipV1Base64URL.encode(envelopeBytes)

        let sql = """
        INSERT INTO gossip_items (item_id, envelope_b64, expiry_unix_ms, hop_count, recorded_at_unix_ms)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(item_id) DO UPDATE SET
            envelope_b64 = excluded.envelope_b64,
            expiry_unix_ms = excluded.expiry_unix_ms,
            hop_count = excluded.hop_count,
            recorded_at_unix_ms = excluded.recorded_at_unix_ms;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindText(stmt, index: 1, text: itemIDHex)
        try bindText(stmt, index: 2, text: envelopeB64)
        try bindInt64(stmt, index: 3, value: expiryUnixMs)
        try bindInt64(stmt, index: 4, value: hopCount)
        try bindInt64(stmt, index: 5, value: effectiveRecordedAtUnixMs)
        try stepDone(stmt)
    }

    func getGossipItem(itemID: Data) throws -> GossipItemRow? {
        guard itemID.count == 32 else {
            throw StoreError.sqliteError("gossip_items.item_id must be 32 bytes")
        }

        let sql = """
        SELECT item_id, envelope_b64, expiry_unix_ms, hop_count, recorded_at_unix_ms
        FROM gossip_items
        WHERE item_id = ?
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: Hex.encode(itemID))

        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            guard let rowItemIDHex = columnText(stmt, index: 0),
                  let envelopeB64 = columnText(stmt, index: 1)
            else {
                throw StoreError.sqliteError("Unexpected NULL column in gossip_items")
            }

            let rowItemID: Data
            do {
                rowItemID = try GossipV1ItemID(hex: rowItemIDHex).rawBytes()
            } catch {
                throw StoreError.sqliteError("Invalid gossip_items item_id encoding")
            }

            let envelopeBytes: Data
            do {
                envelopeBytes = try GossipV1Base64URL.decode(envelopeB64)
            } catch {
                throw StoreError.sqliteError("Invalid gossip_items envelope_b64 encoding")
            }

            let expiryUnixMs = columnInt64(stmt, index: 2)
            let hopCount = columnInt64(stmt, index: 3)
            let recordedAtUnixMs = columnInt64(stmt, index: 4)

            guard rowItemID.count == 32 else {
                throw StoreError.sqliteError("Invalid gossip_items item_id length")
            }
            guard expiryUnixMs >= 0 else {
                throw StoreError.sqliteError("Invalid negative gossip_items expiry_unix_ms")
            }
            guard (0...Int64(UInt16.max)).contains(hopCount) else {
                throw StoreError.sqliteError("Invalid gossip_items hop_count")
            }
            guard recordedAtUnixMs >= 0 else {
                throw StoreError.sqliteError("Invalid negative gossip_items recorded_at_unix_ms")
            }

            return GossipItemRow(
                itemID: rowItemID,
                envelopeBytes: envelopeBytes,
                expiryUnixMs: expiryUnixMs,
                hopCount: hopCount,
                recordedAtUnixMs: recordedAtUnixMs
            )
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    func listGossipItemIDs(eligibleAfterUnixMs cutoffUnixMs: Int64) throws -> [GossipV1ItemID] {
        let sql = """
        SELECT item_id
        FROM gossip_items
        WHERE expiry_unix_ms > ?
        ORDER BY hop_count ASC, recorded_at_unix_ms DESC, item_id ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindInt64(stmt, index: 1, value: cutoffUnixMs)

        var ids: [GossipV1ItemID] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            guard let itemHex = columnText(stmt, index: 0) else {
                throw StoreError.sqliteError("Unexpected NULL item_id in gossip_items")
            }

            let itemID: GossipV1ItemID
            do {
                itemID = try GossipV1ItemID(hex: itemHex)
            } catch {
                throw StoreError.sqliteError("Invalid gossip_items item_id encoding")
            }

            ids.append(itemID)
        }
        return ids
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
            try migrateV3toV4()
            try migrateV4toV5()
            try migrateV5toV6()
            try migrateV6toV7()
            try migrateV7toV8()
            try migrateV8toV9()
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        case 1:
            try migrateV1toV2()
            try migrateV2toV3()
            try migrateV3toV4()
            try migrateV4toV5()
            try migrateV5toV6()
            try migrateV6toV7()
            try migrateV7toV8()
            try migrateV8toV9()
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        case 2:
            try migrateV2toV3()
            try migrateV3toV4()
            try migrateV4toV5()
            try migrateV5toV6()
            try migrateV6toV7()
            try migrateV7toV8()
            try migrateV8toV9()
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        case 3:
            try migrateV3toV4()
            try migrateV4toV5()
            try migrateV5toV6()
            try migrateV6toV7()
            try migrateV7toV8()
            try migrateV8toV9()
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        case 4:
            try migrateV4toV5()
            try migrateV5toV6()
            try migrateV6toV7()
            try migrateV7toV8()
            try migrateV8toV9()
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        case 5:
            try migrateV5toV6()
            try migrateV6toV7()
            try migrateV7toV8()
            try migrateV8toV9()
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        case 6:
            try migrateV6toV7()
            try migrateV7toV8()
            try migrateV8toV9()
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        case 7:
            try migrateV7toV8()
            try migrateV8toV9()
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        case 8:
            try migrateV8toV9()
            try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
        case Self.currentSchemaVersion:
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
        try addColumnIfMissing(table: "transfers", column: "custody", definition: "TEXT NOT NULL DEFAULT 'origin'")
        try addColumnIfMissing(table: "transfers", column: "ttl_seconds", definition: "INTEGER")
        try addColumnIfMissing(table: "transfers", column: "expires_at", definition: "INTEGER")
        try addColumnIfMissing(table: "transfers", column: "completed_at", definition: "INTEGER")
        try addColumnIfMissing(table: "transfers", column: "evicted", definition: "INTEGER NOT NULL DEFAULT 0")

        // Index for eviction queries.
        try exec("CREATE INDEX IF NOT EXISTS transfers_custody_idx ON transfers(custody);")
        try exec("CREATE INDEX IF NOT EXISTS transfers_evicted_idx ON transfers(evicted);")
        try exec("CREATE INDEX IF NOT EXISTS transfers_expires_at_idx ON transfers(expires_at);")

        // Backfill: set custody based on direction for existing rows.
        try exec("UPDATE transfers SET custody = 'inbound' WHERE direction = 'inbound' AND custody = 'origin';")
    }

    private func migrateV3toV4() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS peers (
            wayfarer_id TEXT PRIMARY KEY NOT NULL,
            first_seen_at INTEGER NOT NULL,
            last_seen_at INTEGER NOT NULL,
            last_exchange_at INTEGER,
            notes TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_peers_last_seen_at ON peers(last_seen_at);
        CREATE INDEX IF NOT EXISTS idx_peers_last_exchange_at ON peers(last_exchange_at);
        """)
    }

    private func migrateV4toV5() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS messages (
            message_id BLOB PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            direction TEXT NOT NULL,
            peer_from TEXT,
            peer_to TEXT,
            created_at INTEGER NOT NULL,
            canonical BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
        CREATE INDEX IF NOT EXISTS idx_messages_direction_created_at ON messages(direction, created_at);
        CREATE INDEX IF NOT EXISTS idx_messages_kind_created_at ON messages(kind, created_at);
        """)
    }

    private func migrateV5toV6() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS delivery_receipts (
            message_id BLOB NOT NULL,
            destination_wayfarer_id TEXT NOT NULL,
            received_at INTEGER NOT NULL,
            signature BLOB NOT NULL,
            PRIMARY KEY (message_id, destination_wayfarer_id)
        );
        CREATE INDEX IF NOT EXISTS idx_delivery_receipts_received_at ON delivery_receipts(received_at);
        """)
    }

    private func migrateV6toV7() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS gossip_objects (
            item_id BLOB PRIMARY KEY NOT NULL,
            envelope_bytes BLOB NOT NULL,
            expiry_unix_ms INTEGER NOT NULL,
            hop_count INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_gossip_objects_expiry_item_id
        ON gossip_objects(expiry_unix_ms, item_id);
        """)
    }

    private func migrateV7toV8() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS messages (
            message_id BLOB PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            direction TEXT NOT NULL,
            author_wayfarer_id TEXT NOT NULL,
            received_from_peer_id TEXT,
            peer_to TEXT,
            created_at INTEGER NOT NULL,
            canonical BLOB NOT NULL
        );
        """)

        let hasLegacyPeerFrom = try tableHasColumn(table: "messages", column: "peer_from")

        try addColumnIfMissing(
            table: "messages",
            column: "author_wayfarer_id",
            definition: "TEXT"
        )
        try addColumnIfMissing(
            table: "messages",
            column: "received_from_peer_id",
            definition: "TEXT"
        )

        if hasLegacyPeerFrom {
            try exec("""
            UPDATE messages
            SET received_from_peer_id = peer_from
            WHERE received_from_peer_id IS NULL
              AND peer_from IS NOT NULL
              AND peer_from != '';
            """)
        }

        try exec("""
        CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
        CREATE INDEX IF NOT EXISTS idx_messages_direction_created_at ON messages(direction, created_at);
        CREATE INDEX IF NOT EXISTS idx_messages_kind_created_at ON messages(kind, created_at);
        CREATE INDEX IF NOT EXISTS idx_messages_author_created_at ON messages(author_wayfarer_id, created_at);
        """)
    }

    private func migrateV8toV9() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS gossip_items (
            item_id TEXT PRIMARY KEY NOT NULL,
            envelope_b64 TEXT NOT NULL,
            expiry_unix_ms INTEGER NOT NULL,
            hop_count INTEGER NOT NULL,
            recorded_at_unix_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_gossip_items_expiry ON gossip_items(expiry_unix_ms);
        CREATE INDEX IF NOT EXISTS idx_gossip_items_rank
        ON gossip_items(hop_count, recorded_at_unix_ms DESC, item_id);

        CREATE TABLE IF NOT EXISTS gossip_meta (
            meta_key TEXT PRIMARY KEY NOT NULL,
            meta_value INTEGER NOT NULL
        );
        """)

        let alreadyMigrated = try gossipMetaIntValue(forKey: Self.legacyGossipObjectsMigrationMarker) != nil
        guard !alreadyMigrated else { return }

        let hasLegacyGossipObjects = try tableExists(name: "gossip_objects")
        if hasLegacyGossipObjects {
            let nowUnixMs = Self.epochMilliseconds(Date())
            let stmt = try prepare("SELECT item_id, envelope_bytes, expiry_unix_ms, hop_count FROM gossip_objects;")
            defer { sqlite3_finalize(stmt) }

            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                if rc != SQLITE_ROW { throw sqliteError() }

                guard let legacyItemID = columnData(stmt, index: 0),
                      let legacyEnvelopeBytes = columnData(stmt, index: 1)
                else {
                    throw StoreError.sqliteError("Unexpected NULL column in gossip_objects migration")
                }

                let legacyExpiryUnixMs = columnInt64(stmt, index: 2)
                let legacyHopCount = columnInt64(stmt, index: 3)

                try upsertGossipItem(
                    itemID: legacyItemID,
                    envelopeBytes: legacyEnvelopeBytes,
                    expiryUnixMs: legacyExpiryUnixMs,
                    hopCount: legacyHopCount,
                    recordedAtUnixMs: nowUnixMs
                )
            }
        }

        try upsertGossipMetaIntValue(forKey: Self.legacyGossipObjectsMigrationMarker, value: 1)
    }

    // MARK: Delivery Receipts

    /// Record a delivery receipt. Deduplicates by (messageId, destinationWayfarerId).
    public func recordDeliveryReceipt(_ receipt: DeliveryReceipt) throws {
        guard let signature = receipt.signature else {
            throw StoreError.sqliteError("Cannot record unsigned delivery receipt")
        }

        let sql = """
        INSERT OR REPLACE INTO delivery_receipts (message_id, destination_wayfarer_id, received_at, signature)
        VALUES (?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindData(stmt, index: 1, data: receipt.messageId)
        try bindText(stmt, index: 2, text: receipt.destinationWayfarerId)
        try bindInt64(stmt, index: 3, value: Self.epochSeconds(receipt.receivedAt))
        try bindData(stmt, index: 4, data: signature)

        try stepDone(stmt)
    }

    /// Get a delivery receipt by messageId and destinationWayfarerId.
    public func getDeliveryReceipt(messageId: Data, destinationWayfarerId: String) throws -> DeliveryReceipt? {
        let sql = """
        SELECT message_id, destination_wayfarer_id, received_at, signature
        FROM delivery_receipts
        WHERE message_id = ? AND destination_wayfarer_id = ?
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindData(stmt, index: 1, data: messageId)
        try bindText(stmt, index: 2, text: destinationWayfarerId)

        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            guard let msgId = columnData(stmt, index: 0),
                  let wayfarerId = columnText(stmt, index: 1),
                  let sig = columnData(stmt, index: 3)
            else {
                throw StoreError.sqliteError("Unexpected NULL column in delivery_receipts")
            }
            let receivedAt = Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 2)))
            return DeliveryReceipt(
                messageId: msgId,
                destinationWayfarerId: wayfarerId,
                receivedAt: receivedAt,
                signature: sig
            )
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    /// List delivery receipts, optionally filtered by messageId or limited.
    public func listDeliveryReceipts(messageId: Data? = nil, limit: Int = 100) throws -> [DeliveryReceipt] {
        let sql: String
        if messageId != nil {
            sql = """
            SELECT message_id, destination_wayfarer_id, received_at, signature
            FROM delivery_receipts
            WHERE message_id = ?
            ORDER BY received_at DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT message_id, destination_wayfarer_id, received_at, signature
            FROM delivery_receipts
            ORDER BY received_at DESC
            LIMIT ?;
            """
        }

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        if let msgId = messageId {
            try bindData(stmt, index: 1, data: msgId)
            try bindInt32(stmt, index: 2, value: Int32(min(limit, Int(Int32.max))))
        } else {
            try bindInt32(stmt, index: 1, value: Int32(min(limit, Int(Int32.max))))
        }

        var receipts: [DeliveryReceipt] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }

            guard let msgId = columnData(stmt, index: 0),
                  let wayfarerId = columnText(stmt, index: 1),
                  let sig = columnData(stmt, index: 3)
            else {
                throw StoreError.sqliteError("Unexpected NULL column in delivery_receipts")
            }

            let receivedAt = Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 2)))
            receipts.append(DeliveryReceipt(
                messageId: msgId,
                destinationWayfarerId: wayfarerId,
                receivedAt: receivedAt,
                signature: sig
            ))
        }

        return receipts
    }

    // MARK: Messages

    public func recordMessage(_ row: MessageRow) throws {
        guard row.kind == "message.v2" else {
            throw StoreError.sqliteError("messages.kind must be message.v2")
        }

        let decoded = try CanonicalEncoderV1.decodeMessage(canonical: row.canonical)
        let canonicalAuthorWayfarerId = Hex.encode(decoded.authorWayfarerId)
        guard row.authorWayfarerId == canonicalAuthorWayfarerId else {
            throw StoreError.sqliteError("author_wayfarer_id must match canonical message author")
        }

        let sql = """
        INSERT OR IGNORE INTO messages (message_id, kind, direction, author_wayfarer_id, received_from_peer_id, peer_to, created_at, canonical)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindData(stmt, index: 1, data: row.messageId)
        try bindText(stmt, index: 2, text: row.kind)
        try bindText(stmt, index: 3, text: row.direction.rawValue)
        try bindNullableText(stmt, index: 4, text: row.authorWayfarerId)
        try bindNullableText(stmt, index: 5, text: row.receivedFromPeerId)
        try bindNullableText(stmt, index: 6, text: row.peerTo)
        try bindInt64(stmt, index: 7, value: Self.epochSeconds(row.createdAt))
        try bindData(stmt, index: 8, data: row.canonical)
        try stepDone(stmt)
    }

    public func listMessages(limit: Int = 100) throws -> [MessageRow] {
        let sql = """
        SELECT message_id, kind, direction, author_wayfarer_id, received_from_peer_id, peer_to, created_at, canonical
        FROM messages
        ORDER BY created_at DESC, rowid DESC
        LIMIT ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindInt32(stmt, index: 1, value: Int32(min(limit, Int(Int32.max))))

        var rows: [MessageRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }

            guard let id = columnData(stmt, index: 0),
                  let kind = columnText(stmt, index: 1),
                  let directionStr = columnText(stmt, index: 2),
                  let canonical = columnData(stmt, index: 7)
            else {
                throw StoreError.sqliteError("Unexpected NULL column in messages")
            }

            let authorWayfarerId = columnText(stmt, index: 3)
            let receivedFromPeerId = columnText(stmt, index: 4)
            let peerTo = columnText(stmt, index: 5)
            let createdAt = Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 6)))
            let direction = MessageRow.Direction(rawValue: directionStr) ?? .inbound
            rows.append(MessageRow(
                messageId: id,
                kind: kind,
                direction: direction,
                authorWayfarerId: authorWayfarerId,
                receivedFromPeerId: receivedFromPeerId,
                peerTo: peerTo,
                createdAt: createdAt,
                canonical: canonical
            ))
        }

        return rows
    }

    public func getMessage(id: Data) throws -> MessageRow? {
        let sql = """
        SELECT message_id, kind, direction, author_wayfarer_id, received_from_peer_id, peer_to, created_at, canonical
        FROM messages
        WHERE message_id = ?
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindData(stmt, index: 1, data: id)

        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            guard let msgId = columnData(stmt, index: 0),
                  let kind = columnText(stmt, index: 1),
                  let directionStr = columnText(stmt, index: 2),
                  let canonical = columnData(stmt, index: 7)
            else {
                throw StoreError.sqliteError("Unexpected NULL column in messages")
            }
            let authorWayfarerId = columnText(stmt, index: 3)
            let receivedFromPeerId = columnText(stmt, index: 4)
            let peerTo = columnText(stmt, index: 5)
            let createdAt = Date(timeIntervalSince1970: TimeInterval(columnInt64(stmt, index: 6)))
            let direction = MessageRow.Direction(rawValue: directionStr) ?? .inbound
            return MessageRow(
                messageId: msgId,
                kind: kind,
                direction: direction,
                authorWayfarerId: authorWayfarerId,
                receivedFromPeerId: receivedFromPeerId,
                peerTo: peerTo,
                createdAt: createdAt,
                canonical: canonical
            )
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    // MARK: Peers

    /// Sort order for listing peers.
    public enum PeerSort: Sendable {
        case lastSeenDesc
        case lastExchangeAsc
    }

    /// Insert a new peer or update last_seen_at for an existing peer.
    public func upsertPeerSeen(wayfarerId: String, now: Int64) throws {
        let sql = """
        INSERT INTO peers (wayfarer_id, first_seen_at, last_seen_at)
        VALUES (?, ?, ?)
        ON CONFLICT(wayfarer_id) DO UPDATE SET last_seen_at = excluded.last_seen_at;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: wayfarerId)
        try bindInt64(stmt, index: 2, value: now)
        try bindInt64(stmt, index: 3, value: now)
        try stepDone(stmt)
    }

    /// List peers with optional staleness filtering and sorting.
    ///
    /// - Parameters:
    ///   - limit: Maximum number of peers to return.
    ///   - sort: Sort order.
    ///   - includeStale: If false, excludes peers whose last_seen_at < now - staleAfterSeconds.
    ///   - staleAfterSeconds: Threshold for staleness (default: 86400 = 24 hours).
    ///   - now: Current epoch seconds.
    public func listPeers(
        limit: Int,
        sort: PeerSort = .lastSeenDesc,
        includeStale: Bool = true,
        staleAfterSeconds: Int64 = 86400,
        now: Int64
    ) throws -> [Peer] {
        let orderClause: String
        switch sort {
        case .lastSeenDesc:
            orderClause = "ORDER BY last_seen_at DESC"
        case .lastExchangeAsc:
            orderClause = "ORDER BY COALESCE(last_exchange_at, 0) ASC, last_seen_at DESC"
        }

        let whereClause: String
        if includeStale {
            whereClause = ""
        } else {
            let cutoff = now - staleAfterSeconds
            whereClause = "WHERE last_seen_at >= \(cutoff)"
        }

        let sql = """
        SELECT wayfarer_id, first_seen_at, last_seen_at, last_exchange_at, notes
        FROM peers
        \(whereClause)
        \(orderClause)
        LIMIT ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindInt32(stmt, index: 1, value: Int32(min(limit, Int(Int32.max))))

        var peers: [Peer] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw sqliteError() }
            peers.append(readPeerRow(stmt))
        }
        return peers
    }

    /// Mark a peer's last_exchange_at timestamp after a successful exchange.
    public func markPeerExchanged(wayfarerId: String, now: Int64) throws {
        let sql = "UPDATE peers SET last_exchange_at = ? WHERE wayfarer_id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindInt64(stmt, index: 1, value: now)
        try bindText(stmt, index: 2, text: wayfarerId)
        try stepDone(stmt)
    }

    /// Count peers with optional stale-peer inclusion.
    ///
    /// - Parameters:
    ///   - includeStale: When `true`, `total` counts all peers. When `false`, `total` counts only
    ///     peers whose `last_seen_at >= now - staleAfterSeconds`.
    ///   - staleAfterSeconds: Staleness threshold in seconds.
    ///   - now: Current Unix seconds used to compute staleness cutoff.
    /// - Returns: `(total, stale)` where `stale` always counts peers with
    ///   `last_seen_at < now - staleAfterSeconds`.
    public func countPeers(includeStale: Bool = true, staleAfterSeconds: Int64 = 86400, now: Int64) throws -> (total: Int, stale: Int) {
        let cutoff = now - staleAfterSeconds
        let totalSQL: String
        if includeStale {
            totalSQL = "SELECT COUNT(*) FROM peers;"
        } else {
            totalSQL = "SELECT COUNT(*) FROM peers WHERE last_seen_at >= ?;"
        }
        let totalStmt = try prepare(totalSQL)
        defer { sqlite3_finalize(totalStmt) }
        if !includeStale {
            try bindInt64(totalStmt, index: 1, value: cutoff)
        }
        guard sqlite3_step(totalStmt) == SQLITE_ROW else { throw sqliteError() }
        let total = Int(sqlite3_column_int(totalStmt, 0))

        let staleSQL = "SELECT COUNT(*) FROM peers WHERE last_seen_at < ?;"
        let staleStmt = try prepare(staleSQL)
        defer { sqlite3_finalize(staleStmt) }
        try bindInt64(staleStmt, index: 1, value: cutoff)
        guard sqlite3_step(staleStmt) == SQLITE_ROW else { throw sqliteError() }
        let stale = Int(sqlite3_column_int(staleStmt, 0))

        return (total, stale)
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        guard try !tableHasColumn(table: table, column: column) else { return }
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func tableExists(name: String) throws -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: name)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func gossipMetaIntValue(forKey key: String) throws -> Int64? {
        let sql = "SELECT meta_value FROM gossip_meta WHERE meta_key = ? LIMIT 1;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: key)

        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            return columnInt64(stmt, index: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw sqliteError()
        }
    }

    private func upsertGossipMetaIntValue(forKey key: String, value: Int64) throws {
        let sql = """
        INSERT INTO gossip_meta (meta_key, meta_value)
        VALUES (?, ?)
        ON CONFLICT(meta_key) DO UPDATE SET
            meta_value = excluded.meta_value;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, text: key)
        try bindInt64(stmt, index: 2, value: value)
        try stepDone(stmt)
    }

    private func tableHasColumn(table: String, column: String) throws -> Bool {
        let stmt = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return false }
            if rc != SQLITE_ROW { throw sqliteError() }
            if columnText(stmt, index: 1) == column {
                return true
            }
        }
    }

    private func readPeerRow(_ stmt: OpaquePointer) -> Peer {
        let wayfarerId = columnText(stmt, index: 0) ?? ""
        let firstSeenAt = columnInt64(stmt, index: 1)
        let lastSeenAt = columnInt64(stmt, index: 2)
        let lastExchangeAt = columnNullableInt64(stmt, index: 3)
        let notes = columnText(stmt, index: 4)
        return Peer(
            wayfarerId: wayfarerId,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            lastExchangeAt: lastExchangeAt,
            notes: notes
        )
    }

    private func userVersion() throws -> Int {
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqliteError() }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: Helpers

    public static func epochSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    public static func epochMilliseconds(_ date: Date) -> Int64 {
        let ms = (date.timeIntervalSince1970 * 1000.0).rounded(.down)
        if ms <= 0 {
            return 0
        }
        if ms >= Double(Int64.max) {
            return Int64.max
        }
        return Int64(ms)
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
