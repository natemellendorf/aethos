import Foundation

public enum GossipSyncFrameType: String, Codable, Equatable, Sendable {
    case inventorySummary = "inventory_summary"
    case missingRequest = "missing_request"
    case transfer
    case receipt
}

public enum GossipReceiptStatus: String, Codable, Equatable, Sendable {
    case accepted
    case partial
    case rejected
}

public struct GossipInventoryEntry: Codable, Equatable, Sendable {
    public let itemId: String
    public let manifestId: String
    public let toWayfarerId: String
    public let expiresAtUnixMs: UInt64
    public let totalSizeBytes: Int
    public let chunkSizeBytes: Int
    public let chunkCount: Int

    public init(
        itemId: String,
        manifestId: String,
        toWayfarerId: String,
        expiresAtUnixMs: UInt64,
        totalSizeBytes: Int,
        chunkSizeBytes: Int,
        chunkCount: Int
    ) {
        self.itemId = itemId
        self.manifestId = manifestId
        self.toWayfarerId = toWayfarerId
        self.expiresAtUnixMs = expiresAtUnixMs
        self.totalSizeBytes = totalSizeBytes
        self.chunkSizeBytes = chunkSizeBytes
        self.chunkCount = chunkCount
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case manifestId = "manifest_id"
        case toWayfarerId = "to_wayfarer_id"
        case expiresAtUnixMs = "expires_at_unix_ms"
        case totalSizeBytes = "total_size_bytes"
        case chunkSizeBytes = "chunk_size_bytes"
        case chunkCount = "chunk_count"
    }
}

public struct GossipTransferEntry: Codable, Equatable, Sendable {
    public let itemId: String
    public let manifestId: String
    public let toWayfarerId: String
    public let expiresAtUnixMs: UInt64
    public let totalSizeBytes: Int
    public let chunkSizeBytes: Int
    public let chunkCount: Int
    public let envelopeB64: String

    public init(
        itemId: String,
        manifestId: String,
        toWayfarerId: String,
        expiresAtUnixMs: UInt64,
        totalSizeBytes: Int,
        chunkSizeBytes: Int,
        chunkCount: Int,
        envelopeB64: String
    ) {
        self.itemId = itemId
        self.manifestId = manifestId
        self.toWayfarerId = toWayfarerId
        self.expiresAtUnixMs = expiresAtUnixMs
        self.totalSizeBytes = totalSizeBytes
        self.chunkSizeBytes = chunkSizeBytes
        self.chunkCount = chunkCount
        self.envelopeB64 = envelopeB64
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case manifestId = "manifest_id"
        case toWayfarerId = "to_wayfarer_id"
        case expiresAtUnixMs = "expires_at_unix_ms"
        case totalSizeBytes = "total_size_bytes"
        case chunkSizeBytes = "chunk_size_bytes"
        case chunkCount = "chunk_count"
        case envelopeB64 = "envelope_b64"
    }
}

public struct GossipRejectedItem: Codable, Equatable, Sendable {
    public let itemId: String
    public let code: String
    public let message: String

    public init(itemId: String, code: String, message: String) {
        self.itemId = itemId
        self.code = code
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case code
        case message
    }
}

public struct GossipInventorySummaryFrame: Codable, Equatable, Sendable {
    public let type: GossipSyncFrameType
    public let syncVersion: Int
    public let sessionId: String
    public let senderWayfarerId: String
    public let page: Int
    public let hasMore: Bool
    public let inventory: [GossipInventoryEntry]

    public init(
        syncVersion: Int = 1,
        sessionId: String,
        senderWayfarerId: String,
        page: Int,
        hasMore: Bool,
        inventory: [GossipInventoryEntry]
    ) {
        self.type = .inventorySummary
        self.syncVersion = syncVersion
        self.sessionId = sessionId
        self.senderWayfarerId = senderWayfarerId
        self.page = page
        self.hasMore = hasMore
        self.inventory = inventory
    }

    enum CodingKeys: String, CodingKey {
        case type
        case syncVersion = "sync_version"
        case sessionId = "session_id"
        case senderWayfarerId = "sender_wayfarer_id"
        case page
        case hasMore = "has_more"
        case inventory
    }
}

public struct GossipMissingRequestFrame: Codable, Equatable, Sendable {
    public let type: GossipSyncFrameType
    public let syncVersion: Int
    public let sessionId: String
    public let senderWayfarerId: String
    public let page: Int
    public let hasMore: Bool
    public let requestId: String
    public let inResponseToPage: Int
    public let missingItemIds: [String]
    public let maxTransferItems: Int
    public let maxTransferBytes: Int

    public init(
        syncVersion: Int = 1,
        sessionId: String,
        senderWayfarerId: String,
        page: Int,
        hasMore: Bool,
        requestId: String,
        inResponseToPage: Int,
        missingItemIds: [String],
        maxTransferItems: Int,
        maxTransferBytes: Int
    ) {
        self.type = .missingRequest
        self.syncVersion = syncVersion
        self.sessionId = sessionId
        self.senderWayfarerId = senderWayfarerId
        self.page = page
        self.hasMore = hasMore
        self.requestId = requestId
        self.inResponseToPage = inResponseToPage
        self.missingItemIds = missingItemIds
        self.maxTransferItems = maxTransferItems
        self.maxTransferBytes = maxTransferBytes
    }

    enum CodingKeys: String, CodingKey {
        case type
        case syncVersion = "sync_version"
        case sessionId = "session_id"
        case senderWayfarerId = "sender_wayfarer_id"
        case page
        case hasMore = "has_more"
        case requestId = "request_id"
        case inResponseToPage = "in_response_to_page"
        case missingItemIds = "missing_item_ids"
        case maxTransferItems = "max_transfer_items"
        case maxTransferBytes = "max_transfer_bytes"
    }
}

public struct GossipTransferFrame: Codable, Equatable, Sendable {
    public let type: GossipSyncFrameType
    public let syncVersion: Int
    public let sessionId: String
    public let senderWayfarerId: String
    public let page: Int
    public let hasMore: Bool
    public let transferId: String
    public let inResponseToRequestId: String
    public let items: [GossipTransferEntry]

    public init(
        syncVersion: Int = 1,
        sessionId: String,
        senderWayfarerId: String,
        page: Int,
        hasMore: Bool,
        transferId: String,
        inResponseToRequestId: String,
        items: [GossipTransferEntry]
    ) {
        self.type = .transfer
        self.syncVersion = syncVersion
        self.sessionId = sessionId
        self.senderWayfarerId = senderWayfarerId
        self.page = page
        self.hasMore = hasMore
        self.transferId = transferId
        self.inResponseToRequestId = inResponseToRequestId
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case type
        case syncVersion = "sync_version"
        case sessionId = "session_id"
        case senderWayfarerId = "sender_wayfarer_id"
        case page
        case hasMore = "has_more"
        case transferId = "transfer_id"
        case inResponseToRequestId = "in_response_to_request_id"
        case items
    }
}

public struct GossipReceiptFrame: Codable, Equatable, Sendable {
    public let type: GossipSyncFrameType
    public let syncVersion: Int
    public let sessionId: String
    public let senderWayfarerId: String
    public let page: Int
    public let hasMore: Bool
    public let receiptId: String
    public let inResponseToTransferId: String
    public let status: GossipReceiptStatus
    public let acceptedItemIds: [String]
    public let rejectedItems: [GossipRejectedItem]

    public init(
        syncVersion: Int = 1,
        sessionId: String,
        senderWayfarerId: String,
        page: Int,
        hasMore: Bool,
        receiptId: String,
        inResponseToTransferId: String,
        status: GossipReceiptStatus,
        acceptedItemIds: [String],
        rejectedItems: [GossipRejectedItem]
    ) {
        self.type = .receipt
        self.syncVersion = syncVersion
        self.sessionId = sessionId
        self.senderWayfarerId = senderWayfarerId
        self.page = page
        self.hasMore = hasMore
        self.receiptId = receiptId
        self.inResponseToTransferId = inResponseToTransferId
        self.status = status
        self.acceptedItemIds = acceptedItemIds
        self.rejectedItems = rejectedItems
    }

    enum CodingKeys: String, CodingKey {
        case type
        case syncVersion = "sync_version"
        case sessionId = "session_id"
        case senderWayfarerId = "sender_wayfarer_id"
        case page
        case hasMore = "has_more"
        case receiptId = "receipt_id"
        case inResponseToTransferId = "in_response_to_transfer_id"
        case status
        case acceptedItemIds = "accepted_item_ids"
        case rejectedItems = "rejected_items"
    }
}

public enum GossipSyncFrame: Codable, Equatable, Sendable {
    case inventorySummary(GossipInventorySummaryFrame)
    case missingRequest(GossipMissingRequestFrame)
    case transfer(GossipTransferFrame)
    case receipt(GossipReceiptFrame)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(GossipSyncFrameType.self, forKey: .type)
        switch type {
        case .inventorySummary:
            self = .inventorySummary(try GossipInventorySummaryFrame(from: decoder))
        case .missingRequest:
            self = .missingRequest(try GossipMissingRequestFrame(from: decoder))
        case .transfer:
            self = .transfer(try GossipTransferFrame(from: decoder))
        case .receipt:
            self = .receipt(try GossipReceiptFrame(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .inventorySummary(let frame): try frame.encode(to: encoder)
        case .missingRequest(let frame): try frame.encode(to: encoder)
        case .transfer(let frame): try frame.encode(to: encoder)
        case .receipt(let frame): try frame.encode(to: encoder)
        }
    }

    public var frameType: GossipSyncFrameType {
        switch self {
        case .inventorySummary: return .inventorySummary
        case .missingRequest: return .missingRequest
        case .transfer: return .transfer
        case .receipt: return .receipt
        }
    }

    public var syncVersion: Int {
        switch self {
        case .inventorySummary(let frame): return frame.syncVersion
        case .missingRequest(let frame): return frame.syncVersion
        case .transfer(let frame): return frame.syncVersion
        case .receipt(let frame): return frame.syncVersion
        }
    }

    public var sessionId: String {
        switch self {
        case .inventorySummary(let frame): return frame.sessionId
        case .missingRequest(let frame): return frame.sessionId
        case .transfer(let frame): return frame.sessionId
        case .receipt(let frame): return frame.sessionId
        }
    }

    public var senderWayfarerId: String {
        switch self {
        case .inventorySummary(let frame): return frame.senderWayfarerId
        case .missingRequest(let frame): return frame.senderWayfarerId
        case .transfer(let frame): return frame.senderWayfarerId
        case .receipt(let frame): return frame.senderWayfarerId
        }
    }

    public var page: Int {
        switch self {
        case .inventorySummary(let frame): return frame.page
        case .missingRequest(let frame): return frame.page
        case .transfer(let frame): return frame.page
        case .receipt(let frame): return frame.page
        }
    }

    public var hasMore: Bool {
        switch self {
        case .inventorySummary(let frame): return frame.hasMore
        case .missingRequest(let frame): return frame.hasMore
        case .transfer(let frame): return frame.hasMore
        case .receipt(let frame): return frame.hasMore
        }
    }
}

public struct GossipTransferPayload: Equatable, Sendable {
    public let itemId: String
    public let manifestId: String
    public let toWayfarerId: String
    public let expiresAtUnixMs: UInt64
    public let totalSizeBytes: Int
    public let chunkSizeBytes: Int
    public let chunkCount: Int
    public let envelopeBytes: Data

    public init(
        itemId: String,
        manifestId: String,
        toWayfarerId: String,
        expiresAtUnixMs: UInt64,
        totalSizeBytes: Int,
        chunkSizeBytes: Int,
        chunkCount: Int,
        envelopeBytes: Data
    ) {
        self.itemId = itemId
        self.manifestId = manifestId
        self.toWayfarerId = toWayfarerId
        self.expiresAtUnixMs = expiresAtUnixMs
        self.totalSizeBytes = totalSizeBytes
        self.chunkSizeBytes = chunkSizeBytes
        self.chunkCount = chunkCount
        self.envelopeBytes = envelopeBytes
    }
}

public struct GossipSyncReceiptRecord: Equatable, Sendable {
    public let peerWayfarerId: String
    public let sessionId: String
    public let transferId: String
    public let status: GossipReceiptStatus
    public let acceptedItemIds: [String]
    public let rejectedItems: [GossipRejectedItem]

    public init(
        peerWayfarerId: String,
        sessionId: String,
        transferId: String,
        status: GossipReceiptStatus,
        acceptedItemIds: [String],
        rejectedItems: [GossipRejectedItem]
    ) {
        self.peerWayfarerId = peerWayfarerId
        self.sessionId = sessionId
        self.transferId = transferId
        self.status = status
        self.acceptedItemIds = acceptedItemIds
        self.rejectedItems = rejectedItems
    }
}

public enum GossipInboundApplyResult: Equatable, Sendable {
    case accepted
    case alreadyPresent
    case rejected(code: String, message: String)
}

public protocol GossipInventoryProviding {
    func localInventory(for peerWayfarerId: String, nowUnixMs: UInt64, limit: Int) throws -> [GossipInventoryEntry]
    func hasLocalItem(itemId: String) throws -> Bool
}

public protocol GossipMessageLoading {
    func loadTransferPayload(itemId: String) throws -> GossipTransferPayload?
}

public protocol GossipReceiptRecording {
    func recordSyncReceipt(_ record: GossipSyncReceiptRecord) throws
}

public protocol GossipTransportSending {
    func sendSyncFrame(_ frame: GossipSyncFrame, to peerWayfarerId: String) throws
}

public protocol GossipInboundTransferApplying {
    func applyInboundTransferItem(_ item: GossipTransferEntry, from peerWayfarerId: String, sessionId: String) throws -> GossipInboundApplyResult
}

public protocol GossipSyncInboundFrameHandling {
    @discardableResult
    func handleInboundSyncFrame(
        _ frame: GossipSyncFrame,
        from peerWayfarerId: String,
        nowUnixMs: UInt64
    ) throws -> GossipSyncHandleResult
}
