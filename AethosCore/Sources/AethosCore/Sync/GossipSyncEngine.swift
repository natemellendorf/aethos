import Foundation

public enum GossipSyncState: String, Equatable, Sendable {
    case idle
    case inventoryExchanged = "inventory_exchanged"
    case missingRequested = "missing_requested"
    case transferInProgress = "transfer_in_progress"
    case converged
    case retryPending = "retry_pending"

    var isActive: Bool {
        switch self {
        case .inventoryExchanged, .missingRequested, .transferInProgress, .converged:
            return true
        case .idle, .retryPending:
            return false
        }
    }
}

public enum GossipSyncHandleDisposition: Equatable, Sendable {
    case handled
    case ignored
    case duplicate
    case retryPending
}

public struct GossipSyncHandleResult: Equatable, Sendable {
    public let peerWayfarerId: String
    public let state: GossipSyncState
    public let disposition: GossipSyncHandleDisposition
    public let sentFrameCount: Int

    public init(
        peerWayfarerId: String,
        state: GossipSyncState,
        disposition: GossipSyncHandleDisposition,
        sentFrameCount: Int
    ) {
        self.peerWayfarerId = peerWayfarerId
        self.state = state
        self.disposition = disposition
        self.sentFrameCount = sentFrameCount
    }
}

public struct GossipSyncExecutionKnobs: Equatable, Sendable {
    public let maxInventoryItemsPerSession: Int
    /// Maximum number of transfer frames this engine will send per session.
    public let maxTransfersPerSession: Int
    public let maxTransferItemsPerFrame: Int
    public let maxTransferBytesPerFrame: Int
    public let maxInboundInventoryItemsPerFrame: Int
    public let maxInboundMissingItemIdsPerFrame: Int
    public let maxInboundTransferItemsPerFrame: Int
    public let maxInboundReceiptAcceptedItemIdsPerFrame: Int
    public let maxInboundReceiptRejectedItemsPerFrame: Int
    public let maxDecodedEnvelopeBytes: Int
    public let maxTrackedFramesPerSession: Int
    public let maxAnnouncedInventoryItemsPerSession: Int

    public init(
        maxInventoryItemsPerSession: Int = 500,
        maxTransfersPerSession: Int = 64,
        maxTransferItemsPerFrame: Int = 8,
        maxTransferBytesPerFrame: Int = 262_144,
        maxInboundInventoryItemsPerFrame: Int = 500,
        maxInboundMissingItemIdsPerFrame: Int = 500,
        maxInboundTransferItemsPerFrame: Int = 64,
        maxInboundReceiptAcceptedItemIdsPerFrame: Int = 256,
        maxInboundReceiptRejectedItemsPerFrame: Int = 256,
        maxDecodedEnvelopeBytes: Int = 262_144,
        maxTrackedFramesPerSession: Int = 2_048,
        maxAnnouncedInventoryItemsPerSession: Int = 500
    ) {
        self.maxInventoryItemsPerSession = max(1, maxInventoryItemsPerSession)
        self.maxTransfersPerSession = max(1, maxTransfersPerSession)
        self.maxTransferItemsPerFrame = max(1, maxTransferItemsPerFrame)
        self.maxTransferBytesPerFrame = max(1, maxTransferBytesPerFrame)
        self.maxInboundInventoryItemsPerFrame = max(1, maxInboundInventoryItemsPerFrame)
        self.maxInboundMissingItemIdsPerFrame = max(1, maxInboundMissingItemIdsPerFrame)
        self.maxInboundTransferItemsPerFrame = max(1, maxInboundTransferItemsPerFrame)
        self.maxInboundReceiptAcceptedItemIdsPerFrame = max(1, maxInboundReceiptAcceptedItemIdsPerFrame)
        self.maxInboundReceiptRejectedItemsPerFrame = max(1, maxInboundReceiptRejectedItemsPerFrame)
        self.maxDecodedEnvelopeBytes = max(1, maxDecodedEnvelopeBytes)
        self.maxTrackedFramesPerSession = max(1, maxTrackedFramesPerSession)
        self.maxAnnouncedInventoryItemsPerSession = max(1, maxAnnouncedInventoryItemsPerSession)
    }
}

public struct GossipSyncRetryContext: Equatable, Sendable {
    public let peerWayfarerId: String
    public let sessionId: String?
    public let reason: String

    public init(peerWayfarerId: String, sessionId: String?, reason: String) {
        self.peerWayfarerId = peerWayfarerId
        self.sessionId = sessionId
        self.reason = reason
    }
}

public struct GossipSyncResumeHint: Equatable, Sendable {
    public let peerWayfarerId: String
    public let lastSessionId: String?

    public init(peerWayfarerId: String, lastSessionId: String?) {
        self.peerWayfarerId = peerWayfarerId
        self.lastSessionId = lastSessionId
    }
}

struct GossipSyncSessionDebugStats: Equatable, Sendable {
    let sessionId: String?
    let state: GossipSyncState
    let trackedFrameCount: Int
    let trackedFrameFingerprintByteCountMax: Int
    let trackedFrameKeysInOrder: [String]
    let announcedInventoryCount: Int
    let announcedInventoryItemIdsInOrder: [String]
}

public struct GossipSyncHooks {
    public let onRetryPending: ((GossipSyncRetryContext) -> Void)?
    public let onResumeAvailable: ((GossipSyncResumeHint) -> Void)?

    public init(
        onRetryPending: ((GossipSyncRetryContext) -> Void)? = nil,
        onResumeAvailable: ((GossipSyncResumeHint) -> Void)? = nil
    ) {
        self.onRetryPending = onRetryPending
        self.onResumeAvailable = onResumeAvailable
    }
}

public enum GossipSyncEngineError: Swift.Error, Equatable {
    case invalidWayfarerId(String)
    case sessionNotActive(String)
}

/// Transport-neutral gossip sync engine implementing `docs/spec/GOSSIP_SYNC_V1.md`.
///
/// Wiring model:
/// 1. On connection established/authenticated, create engine with runtime interfaces.
/// 2. Call `startSession(with:nowUnixMs:)` to emit `inventory_summary`.
/// 3. Route every inbound sync frame to `handleInboundSyncFrame(_:from:nowUnixMs:)`.
/// 4. Persist sync receipts through `GossipReceiptRecording` implementation.
/// 5. On disconnect/cancel, call `connectionDidClose(with:)` or `cancelSession(with:)`.
public final class GossipSyncEngine: GossipSyncInboundFrameHandling {
    public static let supportedSyncVersion: Int = 1
    public static let fixedChunkSizeBytes: Int = 32_768

    private struct TrackedFrame: Equatable {
        let idempotencyKey: String
        let fingerprint: Data
    }

    private struct PeerSession {
        struct RequestedItemSet {
            let itemIds: Set<String>
            let inventoryPage: Int
        }

        var sessionId: String?
        var state: GossipSyncState = .idle
        var announcedInventoryByItemId: [String: GossipInventoryEntry] = [:]
        var announcedInventoryOrder: [String] = []
        var localAdvertisedByItemId: [String: GossipInventoryEntry] = [:]
        var requestedItemSetByRequestId: [String: RequestedItemSet] = [:]
        var transferItemIdsByTransferId: [String: Set<String>] = [:]
        var trackedFrameByIdempotencyKey: [String: Data] = [:]
        var trackedFrameOrder: [String] = []
        var transferFramesSentCount: Int = 0
        var canceled: Bool = false
    }

    private enum FrameTrackingVerdict {
        case accept
        case duplicate
        case violation(String)
    }

    private let localWayfarerId: String
    private let inventoryProvider: GossipInventoryProviding
    private let messageLoader: GossipMessageLoading
    private let receiptRecorder: GossipReceiptRecording
    private let transportSender: GossipTransportSending
    private let inboundTransferHandler: GossipInboundTransferApplying
    private let knobs: GossipSyncExecutionKnobs
    private let hooks: GossipSyncHooks
    private let sessionIdFactory: () -> String
    private let requestIdFactory: () -> String
    private let transferIdFactory: () -> String
    private let receiptIdFactory: () -> String

    private var sessionsByPeerId: [String: PeerSession] = [:]

    public init(
        localWayfarerId: String,
        inventoryProvider: GossipInventoryProviding,
        messageLoader: GossipMessageLoading,
        receiptRecorder: GossipReceiptRecording,
        transportSender: GossipTransportSending,
        inboundTransferHandler: GossipInboundTransferApplying,
        knobs: GossipSyncExecutionKnobs = GossipSyncExecutionKnobs(),
        hooks: GossipSyncHooks = GossipSyncHooks(),
        sessionIdFactory: @escaping () -> String = { "sess-\(UUID().uuidString.lowercased())" },
        requestIdFactory: @escaping () -> String = { "req-\(UUID().uuidString.lowercased())" },
        transferIdFactory: @escaping () -> String = { "xfer-\(UUID().uuidString.lowercased())" },
        receiptIdFactory: @escaping () -> String = { "rcpt-\(UUID().uuidString.lowercased())" }
    ) throws {
        guard Self.isLowerHex64(localWayfarerId) else {
            throw GossipSyncEngineError.invalidWayfarerId(localWayfarerId)
        }
        self.localWayfarerId = localWayfarerId
        self.inventoryProvider = inventoryProvider
        self.messageLoader = messageLoader
        self.receiptRecorder = receiptRecorder
        self.transportSender = transportSender
        self.inboundTransferHandler = inboundTransferHandler
        self.knobs = knobs
        self.hooks = hooks
        self.sessionIdFactory = sessionIdFactory
        self.requestIdFactory = requestIdFactory
        self.transferIdFactory = transferIdFactory
        self.receiptIdFactory = receiptIdFactory
    }

    public func currentState(for peerWayfarerId: String) -> GossipSyncState {
        sessionsByPeerId[peerWayfarerId]?.state ?? .idle
    }

    func debugSessionStats(peerWayfarerId: String) -> GossipSyncSessionDebugStats? {
        guard let session = sessionsByPeerId[peerWayfarerId] else { return nil }
        return GossipSyncSessionDebugStats(
            sessionId: session.sessionId,
            state: session.state,
            trackedFrameCount: session.trackedFrameByIdempotencyKey.count,
            trackedFrameFingerprintByteCountMax: session.trackedFrameByIdempotencyKey.values.map(\.count).max() ?? 0,
            trackedFrameKeysInOrder: session.trackedFrameOrder,
            announcedInventoryCount: session.announcedInventoryByItemId.count,
            announcedInventoryItemIdsInOrder: session.announcedInventoryOrder
        )
    }

    public func startSession(with peerWayfarerId: String, nowUnixMs: UInt64) throws -> String {
        guard Self.isLowerHex64(peerWayfarerId) else {
            throw GossipSyncEngineError.invalidWayfarerId(peerWayfarerId)
        }

        var session = sessionsByPeerId[peerWayfarerId] ?? PeerSession()
        if session.state.isActive, let existing = session.sessionId {
            return existing
        }

        session = PeerSession()
        session.sessionId = sessionIdFactory()
        session.state = .inventoryExchanged
        try sendInventorySummary(for: peerWayfarerId, session: &session, nowUnixMs: nowUnixMs)
        sessionsByPeerId[peerWayfarerId] = session
        return session.sessionId ?? ""
    }

    public func resumeSession(using hint: GossipSyncResumeHint, nowUnixMs: UInt64) throws -> String {
        try startSession(with: hint.peerWayfarerId, nowUnixMs: nowUnixMs)
    }

    public func cancelSession(with peerWayfarerId: String) {
        guard var session = sessionsByPeerId[peerWayfarerId] else { return }
        session.canceled = true
        session.state = .idle
        session.sessionId = nil
        session.requestedItemSetByRequestId.removeAll()
        session.transferItemIdsByTransferId.removeAll()
        session.trackedFrameByIdempotencyKey.removeAll()
        session.trackedFrameOrder.removeAll()
        session.announcedInventoryByItemId.removeAll()
        session.announcedInventoryOrder.removeAll()
        sessionsByPeerId[peerWayfarerId] = session
    }

    public func connectionDidClose(with peerWayfarerId: String) {
        guard var session = sessionsByPeerId[peerWayfarerId], session.state.isActive else { return }
        moveToRetryPending(
            peerWayfarerId: peerWayfarerId,
            session: &session,
            reason: "transport_closed"
        )
        sessionsByPeerId[peerWayfarerId] = session
    }

    @discardableResult
    public func handleInboundSyncFrame(
        _ frame: GossipSyncFrame,
        from peerWayfarerId: String,
        nowUnixMs: UInt64
    ) throws -> GossipSyncHandleResult {
        guard Self.isLowerHex64(peerWayfarerId) else {
            throw GossipSyncEngineError.invalidWayfarerId(peerWayfarerId)
        }

        var session = sessionsByPeerId[peerWayfarerId] ?? PeerSession()
        if session.canceled {
            sessionsByPeerId[peerWayfarerId] = session
            return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: .idle, disposition: .ignored, sentFrameCount: 0)
        }

        if frame.syncVersion != Self.supportedSyncVersion {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "unsupported_sync_version")
            sessionsByPeerId[peerWayfarerId] = session
            return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: session.state, disposition: .retryPending, sentFrameCount: 0)
        }

        if case .inventorySummary = frame {
            // Allowed to establish a new session while idle.
        } else if session.sessionId == nil {
            sessionsByPeerId[peerWayfarerId] = session
            return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: .idle, disposition: .ignored, sentFrameCount: 0)
        }

        if let activeSessionId = session.sessionId {
            if frame.sessionId != activeSessionId {
                if session.state == .idle {
                    sessionsByPeerId[peerWayfarerId] = session
                    return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: .idle, disposition: .ignored, sentFrameCount: 0)
                }
                moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "session_mismatch")
                sessionsByPeerId[peerWayfarerId] = session
                return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: session.state, disposition: .retryPending, sentFrameCount: 0)
            }
        } else {
            session.sessionId = frame.sessionId
        }

        guard Self.validateCommonFrameFields(frame) else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "invalid_common_fields")
            sessionsByPeerId[peerWayfarerId] = session
            return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: session.state, disposition: .retryPending, sentFrameCount: 0)
        }

        guard frame.senderWayfarerId == peerWayfarerId else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "sender_peer_mismatch")
            sessionsByPeerId[peerWayfarerId] = session
            return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: session.state, disposition: .retryPending, sentFrameCount: 0)
        }

        if let preflightFailureReason = preflightInboundFrame(frame) {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: preflightFailureReason)
            sessionsByPeerId[peerWayfarerId] = session
            return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: session.state, disposition: .retryPending, sentFrameCount: 0)
        }

        switch trackFrame(frame, session: &session) {
        case .duplicate:
            sessionsByPeerId[peerWayfarerId] = session
            return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: session.state, disposition: .duplicate, sentFrameCount: 0)
        case .violation(let reason):
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: reason)
            sessionsByPeerId[peerWayfarerId] = session
            return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: session.state, disposition: .retryPending, sentFrameCount: 0)
        case .accept:
            break
        }

        let sentCount: Int
        switch frame {
        case .inventorySummary(let inventoryFrame):
            sentCount = try handleInventorySummary(inventoryFrame, peerWayfarerId: peerWayfarerId, session: &session, nowUnixMs: nowUnixMs)
        case .missingRequest(let missingRequestFrame):
            sentCount = try handleMissingRequest(missingRequestFrame, peerWayfarerId: peerWayfarerId, session: &session, nowUnixMs: nowUnixMs)
        case .transfer(let transferFrame):
            sentCount = try handleTransfer(transferFrame, peerWayfarerId: peerWayfarerId, session: &session, nowUnixMs: nowUnixMs)
        case .receipt(let receiptFrame):
            sentCount = try handleReceipt(receiptFrame, peerWayfarerId: peerWayfarerId, session: &session)
        }

        let disposition: GossipSyncHandleDisposition = session.state == .retryPending ? .retryPending : .handled
        sessionsByPeerId[peerWayfarerId] = session
        return GossipSyncHandleResult(peerWayfarerId: peerWayfarerId, state: session.state, disposition: disposition, sentFrameCount: sentCount)
    }

    private func handleInventorySummary(
        _ frame: GossipInventorySummaryFrame,
        peerWayfarerId: String,
        session: inout PeerSession,
        nowUnixMs: UInt64
    ) throws -> Int {
        guard frame.page == 1, frame.hasMore == false else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "inventory_pagination_violation")
            return 0
        }

        guard frame.inventory.count <= knobs.maxInboundInventoryItemsPerFrame else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "inventory_items_exceeded")
            return 0
        }

        for entry in frame.inventory {
            guard Self.validateInventoryEntry(entry) else {
                moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "invalid_inventory_entry")
                return 0
            }
            if nowUnixMs >= entry.expiresAtUnixMs { continue }
            upsertAnnouncedInventory(entry, session: &session)
        }

        session.state = .inventoryExchanged

        let missing = try computeMissingItemIds(announcedByPeer: session.announcedInventoryByItemId, nowUnixMs: nowUnixMs)
        let requestId = requestIdFactory()
        let capped = Array(missing.prefix(knobs.maxTransferItemsPerFrame))
        let missingFrame = GossipMissingRequestFrame(
            sessionId: frame.sessionId,
            senderWayfarerId: localWayfarerId,
            page: 1,
            hasMore: false,
            requestId: requestId,
            inResponseToPage: frame.page,
            missingItemIds: capped,
            maxTransferItems: knobs.maxTransferItemsPerFrame,
            maxTransferBytes: knobs.maxTransferBytesPerFrame
        )
        try transportSender.sendSyncFrame(.missingRequest(missingFrame), to: peerWayfarerId)

        if capped.isEmpty {
            session.state = .converged
        } else {
            session.state = .missingRequested
            session.requestedItemSetByRequestId[requestId] = PeerSession.RequestedItemSet(
                itemIds: Set(capped),
                inventoryPage: frame.page
            )
        }
        return 1
    }

    private func handleMissingRequest(
        _ frame: GossipMissingRequestFrame,
        peerWayfarerId: String,
        session: inout PeerSession,
        nowUnixMs: UInt64
    ) throws -> Int {
        guard frame.page == 1, frame.hasMore == false else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "missing_request_pagination_violation")
            return 0
        }

        guard frame.inResponseToPage == 1 else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "missing_request_in_response_to_page_invalid")
            return 0
        }

        guard frame.missingItemIds.count <= knobs.maxInboundMissingItemIdsPerFrame else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "missing_request_items_exceeded")
            return 0
        }

        guard frame.maxTransferItems > 0, frame.maxTransferBytes > 0 else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "missing_request_budget_invalid")
            return 0
        }

        if frame.missingItemIds.isEmpty, frame.page == 1, frame.hasMore == false {
            session.state = .converged
            return 0
        }

        let remainingSessionTransferBudget = knobs.maxTransfersPerSession - session.transferFramesSentCount
        guard remainingSessionTransferBudget > 0 else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "transfer_budget_exhausted")
            return 0
        }

        let allowedItemCount = min(
            knobs.maxTransferItemsPerFrame,
            frame.maxTransferItems
        )
        let allowedBytes = min(knobs.maxTransferBytesPerFrame, frame.maxTransferBytes)

        var transferItems: [GossipTransferEntry] = []
        transferItems.reserveCapacity(allowedItemCount)
        var totalEnvelopeBytes = 0

        for itemId in frame.missingItemIds {
            guard transferItems.count < allowedItemCount else { break }
            guard let advertised = session.localAdvertisedByItemId[itemId] else { continue }
            if nowUnixMs >= advertised.expiresAtUnixMs { continue }

            guard let payload = try messageLoader.loadTransferPayload(itemId: itemId) else { continue }
            if nowUnixMs >= payload.expiresAtUnixMs { continue }

            let envelopeBytes = payload.envelopeBytes.count
            if totalEnvelopeBytes + envelopeBytes > allowedBytes {
                break
            }

            let entry = GossipTransferEntry(
                itemId: payload.itemId,
                manifestId: payload.manifestId,
                toWayfarerId: payload.toWayfarerId,
                expiresAtUnixMs: payload.expiresAtUnixMs,
                totalSizeBytes: payload.totalSizeBytes,
                chunkSizeBytes: payload.chunkSizeBytes,
                chunkCount: payload.chunkCount,
                envelopeB64: Base64URL.encode(payload.envelopeBytes)
            )
            transferItems.append(entry)
            totalEnvelopeBytes += envelopeBytes
        }

        let transferId = transferIdFactory()
        let transferFrame = GossipTransferFrame(
            sessionId: frame.sessionId,
            senderWayfarerId: localWayfarerId,
            page: 1,
            hasMore: false,
            transferId: transferId,
            inResponseToRequestId: frame.requestId,
            items: transferItems
        )
        try transportSender.sendSyncFrame(.transfer(transferFrame), to: peerWayfarerId)

        session.transferItemIdsByTransferId[transferId] = Set(transferItems.map(\.itemId))
        session.transferFramesSentCount += 1
        session.state = .transferInProgress
        return 1
    }

    private func handleTransfer(
        _ frame: GossipTransferFrame,
        peerWayfarerId: String,
        session: inout PeerSession,
        nowUnixMs: UInt64
    ) throws -> Int {
        guard frame.page == 1, frame.hasMore == false else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "transfer_pagination_violation")
            return 0
        }

        guard frame.items.count <= knobs.maxInboundTransferItemsPerFrame else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "transfer_items_exceeded")
            return 0
        }

        guard let requestedSet = session.requestedItemSetByRequestId[frame.inResponseToRequestId] else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "unknown_request_for_transfer")
            return 0
        }

        let requestedIds = requestedSet.itemIds

        var accepted: [String] = []
        var rejected: [GossipRejectedItem] = []

        for item in frame.items {
            if Base64URL.estimatedDecodedByteCount(for: item.envelopeB64) > knobs.maxDecodedEnvelopeBytes {
                moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "transfer_envelope_bytes_exceeded")
                return 0
            }

            if !requestedIds.contains(item.itemId) {
                rejected.append(GossipRejectedItem(itemId: item.itemId, code: "UNREQUESTED_ITEM", message: "Item was not requested in active session."))
                continue
            }

            let validation = Self.validateTransferEntry(
                item,
                nowUnixMs: nowUnixMs,
                maxDecodedEnvelopeBytes: knobs.maxDecodedEnvelopeBytes
            )
            switch validation {
            case .invalid(let code, let message):
                rejected.append(GossipRejectedItem(itemId: item.itemId, code: code, message: message))
                continue
            case .valid(let envelopeBytes):
                let parsed = Self.parseEnvelope(canonicalBytes: envelopeBytes)
                guard parsed.manifestIdHex == item.manifestId else {
                    rejected.append(GossipRejectedItem(itemId: item.itemId, code: "MANIFEST_ID_MISMATCH", message: "Envelope manifest_id mismatch."))
                    continue
                }
                guard parsed.toWayfarerIdHex == item.toWayfarerId else {
                    rejected.append(GossipRejectedItem(itemId: item.itemId, code: "TO_WAYFARER_ID_MISMATCH", message: "Envelope to_wayfarer_id mismatch."))
                    continue
                }

                switch try inboundTransferHandler.applyInboundTransferItem(item, from: peerWayfarerId, sessionId: frame.sessionId) {
                case .accepted, .alreadyPresent:
                    accepted.append(item.itemId)
                case .rejected(let code, let message):
                    rejected.append(GossipRejectedItem(itemId: item.itemId, code: code, message: message))
                }
            }
        }

        let status: GossipReceiptStatus
        if rejected.isEmpty {
            status = .accepted
        } else if accepted.isEmpty {
            status = .rejected
        } else {
            status = .partial
        }

        let receiptFrame = GossipReceiptFrame(
            sessionId: frame.sessionId,
            senderWayfarerId: localWayfarerId,
            page: 1,
            hasMore: false,
            receiptId: receiptIdFactory(),
            inResponseToTransferId: frame.transferId,
            status: status,
            acceptedItemIds: accepted,
            rejectedItems: rejected
        )

        try transportSender.sendSyncFrame(.receipt(receiptFrame), to: peerWayfarerId)

        session.requestedItemSetByRequestId.removeValue(forKey: frame.inResponseToRequestId)
        session.state = .inventoryExchanged

        let missing = try computeMissingItemIds(announcedByPeer: session.announcedInventoryByItemId, nowUnixMs: nowUnixMs)
        let nextRequestId = requestIdFactory()
        let capped = Array(missing.prefix(knobs.maxTransferItemsPerFrame))
        let followUp = GossipMissingRequestFrame(
            sessionId: frame.sessionId,
            senderWayfarerId: localWayfarerId,
            page: 1,
            hasMore: false,
            requestId: nextRequestId,
            inResponseToPage: requestedSet.inventoryPage,
            missingItemIds: capped,
            maxTransferItems: knobs.maxTransferItemsPerFrame,
            maxTransferBytes: knobs.maxTransferBytesPerFrame
        )
        try transportSender.sendSyncFrame(.missingRequest(followUp), to: peerWayfarerId)
        if capped.isEmpty {
            session.state = .converged
        } else {
            session.state = .missingRequested
            session.requestedItemSetByRequestId[nextRequestId] = PeerSession.RequestedItemSet(
                itemIds: Set(capped),
                inventoryPage: requestedSet.inventoryPage
            )
        }

        return 2
    }

    private func handleReceipt(
        _ frame: GossipReceiptFrame,
        peerWayfarerId: String,
        session: inout PeerSession
    ) throws -> Int {
        guard frame.page == 1, frame.hasMore == false else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "receipt_pagination_violation")
            return 0
        }

        guard let transferItemIds = session.transferItemIdsByTransferId[frame.inResponseToTransferId] else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "receipt_for_unknown_transfer")
            return 0
        }

        guard Self.validateReceiptSets(
            status: frame.status,
            transferItemIds: transferItemIds,
            acceptedItemIds: Set(frame.acceptedItemIds),
            rejectedItemIds: Set(frame.rejectedItems.map(\.itemId))
        ) else {
            moveToRetryPending(peerWayfarerId: peerWayfarerId, session: &session, reason: "receipt_set_violation")
            return 0
        }

        let record = GossipSyncReceiptRecord(
            peerWayfarerId: peerWayfarerId,
            sessionId: frame.sessionId,
            transferId: frame.inResponseToTransferId,
            status: frame.status,
            acceptedItemIds: frame.acceptedItemIds,
            rejectedItems: frame.rejectedItems
        )
        try receiptRecorder.recordSyncReceipt(record)

        session.transferItemIdsByTransferId.removeValue(forKey: frame.inResponseToTransferId)
        session.state = .inventoryExchanged
        return 0
    }

    private func computeMissingItemIds(
        announcedByPeer: [String: GossipInventoryEntry],
        nowUnixMs: UInt64
    ) throws -> [String] {
        var missing: [String] = []
        missing.reserveCapacity(announcedByPeer.count)
        for entry in announcedByPeer.values {
            if nowUnixMs >= entry.expiresAtUnixMs { continue }
            if try inventoryProvider.hasLocalItem(itemId: entry.itemId) {
                continue
            }
            missing.append(entry.itemId)
        }
        return missing.sorted()
    }

    private func sendInventorySummary(
        for peerWayfarerId: String,
        session: inout PeerSession,
        nowUnixMs: UInt64
    ) throws {
        guard let sessionId = session.sessionId else {
            throw GossipSyncEngineError.sessionNotActive(peerWayfarerId)
        }
        let localInventory = try inventoryProvider.localInventory(
            for: peerWayfarerId,
            nowUnixMs: nowUnixMs,
            limit: knobs.maxInventoryItemsPerSession
        )
        let sorted = localInventory
            .filter { nowUnixMs < $0.expiresAtUnixMs }
            .sorted { $0.itemId < $1.itemId }
            .prefix(knobs.maxInventoryItemsPerSession)
        let inventory = Array(sorted)
        session.localAdvertisedByItemId = Dictionary(uniqueKeysWithValues: inventory.map { ($0.itemId, $0) })
        let frame = GossipInventorySummaryFrame(
            sessionId: sessionId,
            senderWayfarerId: localWayfarerId,
            page: 1,
            hasMore: false,
            inventory: inventory
        )
        try transportSender.sendSyncFrame(.inventorySummary(frame), to: peerWayfarerId)
    }

    private func moveToRetryPending(
        peerWayfarerId: String,
        session: inout PeerSession,
        reason: String
    ) {
        session.state = .retryPending
        let context = GossipSyncRetryContext(
            peerWayfarerId: peerWayfarerId,
            sessionId: session.sessionId,
            reason: reason
        )
        hooks.onRetryPending?(context)
        hooks.onResumeAvailable?(GossipSyncResumeHint(peerWayfarerId: peerWayfarerId, lastSessionId: session.sessionId))
    }

    private func preflightInboundFrame(_ frame: GossipSyncFrame) -> String? {
        switch frame {
        case .inventorySummary(let inventoryFrame):
            guard inventoryFrame.page == 1, inventoryFrame.hasMore == false else {
                return "inventory_pagination_violation"
            }
            guard inventoryFrame.inventory.count <= knobs.maxInboundInventoryItemsPerFrame else {
                return "inventory_items_exceeded"
            }
            return nil
        case .missingRequest(let missingFrame):
            guard missingFrame.page == 1, missingFrame.hasMore == false else {
                return "missing_request_pagination_violation"
            }
            guard missingFrame.missingItemIds.count <= knobs.maxInboundMissingItemIdsPerFrame else {
                return "missing_request_items_exceeded"
            }
            return nil
        case .transfer(let transferFrame):
            guard transferFrame.page == 1, transferFrame.hasMore == false else {
                return "transfer_pagination_violation"
            }
            guard transferFrame.items.count <= knobs.maxInboundTransferItemsPerFrame else {
                return "transfer_items_exceeded"
            }
            for item in transferFrame.items {
                if Base64URL.estimatedDecodedByteCount(for: item.envelopeB64) > knobs.maxDecodedEnvelopeBytes {
                    return "transfer_envelope_bytes_exceeded"
                }
            }
            return nil
        case .receipt(let receiptFrame):
            guard receiptFrame.page == 1, receiptFrame.hasMore == false else {
                return "receipt_pagination_violation"
            }
            guard receiptFrame.acceptedItemIds.count <= knobs.maxInboundReceiptAcceptedItemIdsPerFrame else {
                return "receipt_accepted_items_exceeded"
            }
            guard receiptFrame.rejectedItems.count <= knobs.maxInboundReceiptRejectedItemsPerFrame else {
                return "receipt_rejected_items_exceeded"
            }
            return nil
        }
    }

    private func trackFrame(_ frame: GossipSyncFrame, session: inout PeerSession) -> FrameTrackingVerdict {
        let idempotencyKey = Self.idempotencyKey(for: frame)
        let fingerprint = Self.frameFingerprint(frame)

        if let existing = session.trackedFrameByIdempotencyKey[idempotencyKey] {
            if existing == fingerprint {
                return .duplicate
            }
            return .violation("idempotency_mismatch")
        }

        session.trackedFrameByIdempotencyKey[idempotencyKey] = fingerprint
        session.trackedFrameOrder.append(idempotencyKey)
        evictOldTrackedFrames(session: &session)
        return .accept
    }

    private static func idempotencyKey(for frame: GossipSyncFrame) -> String {
        switch frame {
        case .inventorySummary(let summary):
            return "inventory|\(summary.sessionId)|\(summary.senderWayfarerId)|\(summary.page)"
        case .missingRequest(let request):
            return "missing|\(request.sessionId)|\(request.requestId)|\(request.page)"
        case .transfer(let transfer):
            return "transfer|\(transfer.sessionId)|\(transfer.transferId)|\(transfer.page)"
        case .receipt(let receipt):
            return "receipt|\(receipt.sessionId)|\(receipt.receiptId)|\(receipt.page)"
        }
    }

    private static func frameFingerprint(_ frame: GossipSyncFrame) -> Data {
        var input = Data()

        switch frame {
        case .inventorySummary(let summary):
            appendFingerprintField(summary.type.rawValue, to: &input)
            appendFingerprintField(String(summary.syncVersion), to: &input)
            appendFingerprintField(summary.sessionId, to: &input)
            appendFingerprintField(summary.senderWayfarerId, to: &input)
            appendFingerprintField(String(summary.page), to: &input)
            appendFingerprintField(summary.hasMore ? "1" : "0", to: &input)

            let normalizedEntries = summary.inventory
                .map { entry in
                    "\(entry.itemId)|\(entry.manifestId)|\(entry.toWayfarerId)|\(entry.expiresAtUnixMs)|\(entry.totalSizeBytes)|\(entry.chunkSizeBytes)|\(entry.chunkCount)"
                }
                .sorted()
            appendFingerprintField(String(normalizedEntries.count), to: &input)
            for entry in normalizedEntries {
                appendFingerprintField(entry, to: &input)
            }

        case .missingRequest(let request):
            appendFingerprintField(request.type.rawValue, to: &input)
            appendFingerprintField(String(request.syncVersion), to: &input)
            appendFingerprintField(request.sessionId, to: &input)
            appendFingerprintField(request.senderWayfarerId, to: &input)
            appendFingerprintField(String(request.page), to: &input)
            appendFingerprintField(request.hasMore ? "1" : "0", to: &input)
            appendFingerprintField(request.requestId, to: &input)
            appendFingerprintField(String(request.inResponseToPage), to: &input)
            appendFingerprintField(String(request.maxTransferItems), to: &input)
            appendFingerprintField(String(request.maxTransferBytes), to: &input)

            let normalizedMissingItemIds = request.missingItemIds.sorted()
            appendFingerprintField(String(normalizedMissingItemIds.count), to: &input)
            for itemId in normalizedMissingItemIds {
                appendFingerprintField(itemId, to: &input)
            }

        case .transfer(let transfer):
            appendFingerprintField(transfer.type.rawValue, to: &input)
            appendFingerprintField(String(transfer.syncVersion), to: &input)
            appendFingerprintField(transfer.sessionId, to: &input)
            appendFingerprintField(transfer.senderWayfarerId, to: &input)
            appendFingerprintField(String(transfer.page), to: &input)
            appendFingerprintField(transfer.hasMore ? "1" : "0", to: &input)
            appendFingerprintField(transfer.transferId, to: &input)
            appendFingerprintField(transfer.inResponseToRequestId, to: &input)

            let normalizedEntries = transfer.items
                .map { entry in
                    let envelopeDigestHex = Hex.encode(AethosIDs.sha256(Data(entry.envelopeB64.utf8)))
                    return "\(entry.itemId)|\(entry.manifestId)|\(entry.toWayfarerId)|\(entry.expiresAtUnixMs)|\(entry.totalSizeBytes)|\(entry.chunkSizeBytes)|\(entry.chunkCount)|\(entry.envelopeB64.count)|\(envelopeDigestHex)"
                }
                .sorted()
            appendFingerprintField(String(normalizedEntries.count), to: &input)
            for entry in normalizedEntries {
                appendFingerprintField(entry, to: &input)
            }

        case .receipt(let receipt):
            appendFingerprintField(receipt.type.rawValue, to: &input)
            appendFingerprintField(String(receipt.syncVersion), to: &input)
            appendFingerprintField(receipt.sessionId, to: &input)
            appendFingerprintField(receipt.senderWayfarerId, to: &input)
            appendFingerprintField(String(receipt.page), to: &input)
            appendFingerprintField(receipt.hasMore ? "1" : "0", to: &input)
            appendFingerprintField(receipt.receiptId, to: &input)
            appendFingerprintField(receipt.inResponseToTransferId, to: &input)
            appendFingerprintField(receipt.status.rawValue, to: &input)

            let normalizedAcceptedItemIds = receipt.acceptedItemIds.sorted()
            appendFingerprintField(String(normalizedAcceptedItemIds.count), to: &input)
            for itemId in normalizedAcceptedItemIds {
                appendFingerprintField(itemId, to: &input)
            }

            let normalizedRejectedItems = receipt.rejectedItems
                .map { entry in
                    let messageDigestHex = Hex.encode(AethosIDs.sha256(Data(entry.message.utf8)))
                    return "\(entry.itemId)|\(entry.code)|\(entry.message.count)|\(messageDigestHex)"
                }
                .sorted()
            appendFingerprintField(String(normalizedRejectedItems.count), to: &input)
            for item in normalizedRejectedItems {
                appendFingerprintField(item, to: &input)
            }
        }

        return AethosIDs.sha256(input)
    }

    private static func appendFingerprintField(_ value: String, to buffer: inout Data) {
        let data = Data(value.utf8)
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }
        buffer.append(data)
    }

    private static func validateCommonFrameFields(_ frame: GossipSyncFrame) -> Bool {
        guard frame.page >= 1 else { return false }
        guard !frame.sessionId.isEmpty else { return false }
        guard isLowerHex64(frame.senderWayfarerId) else { return false }
        return true
    }

    private static func validateInventoryEntry(_ entry: GossipInventoryEntry) -> Bool {
        guard isLowerHex64(entry.itemId) else { return false }
        guard isLowerHex64(entry.manifestId) else { return false }
        guard isLowerHex64(entry.toWayfarerId) else { return false }
        guard entry.chunkSizeBytes == fixedChunkSizeBytes else { return false }
        guard entry.totalSizeBytes >= 0 else { return false }
        guard entry.chunkCount >= 0 else { return false }
        return true
    }

    private enum TransferValidation {
        case valid(envelopeBytes: Data)
        case invalid(code: String, message: String)
    }

    private static func validateTransferEntry(
        _ entry: GossipTransferEntry,
        nowUnixMs: UInt64,
        maxDecodedEnvelopeBytes: Int
    ) -> TransferValidation {
        guard isLowerHex64(entry.itemId) else {
            return .invalid(code: "INVALID_ITEM_ID", message: "item_id must be lowercase 64-char hex.")
        }
        guard isLowerHex64(entry.manifestId) else {
            return .invalid(code: "INVALID_MANIFEST_ID", message: "manifest_id must be lowercase 64-char hex.")
        }
        guard isLowerHex64(entry.toWayfarerId) else {
            return .invalid(code: "INVALID_TO_WAYFARER_ID", message: "to_wayfarer_id must be lowercase 64-char hex.")
        }
        guard entry.chunkSizeBytes == fixedChunkSizeBytes else {
            return .invalid(code: "INVALID_CHUNK_SIZE", message: "chunk_size_bytes must be 32768 for v1.")
        }
        if nowUnixMs >= entry.expiresAtUnixMs {
            return .invalid(code: "ITEM_EXPIRED", message: "Transfer item is expired.")
        }

        guard let envelopeBytes = Base64URL.decode(entry.envelopeB64, maxDecodedBytes: maxDecodedEnvelopeBytes) else {
            return .invalid(code: "INVALID_ENVELOPE_BASE64", message: "envelope_b64 is not valid base64url.")
        }

        let computedItemId = Hex.encode(AethosIDs.sha256(envelopeBytes))
        guard computedItemId == entry.itemId else {
            return .invalid(code: "ITEM_ID_MISMATCH", message: "item_id does not match SHA-256(envelope_b64).")
        }

        return .valid(envelopeBytes: envelopeBytes)
    }

    private struct ParsedEnvelope {
        let toWayfarerIdHex: String
        let manifestIdHex: String
    }

    private static func parseEnvelope(canonicalBytes: Data) -> ParsedEnvelope {
        var reader = CanonicalReader(canonicalBytes)
        guard let _ = reader.readUInt8(),
              let type = reader.readUInt8(),
              type == CanonicalEncoderV1.TypeDiscriminator.envelope.rawValue
        else {
            return ParsedEnvelope(toWayfarerIdHex: "", manifestIdHex: "")
        }

        var toWayfarer = Data()
        var manifestId = Data()

        while !reader.isAtEnd {
            guard let field = reader.readUInt8(),
                  let length = reader.readUInt32(),
                  let raw = reader.readData(count: Int(length))
            else {
                break
            }

            switch field {
            case CanonicalEncoderV1.EnvelopeField.toWayfarerId.rawValue:
                toWayfarer = raw
            case CanonicalEncoderV1.EnvelopeField.manifestId.rawValue:
                manifestId = raw
            default:
                break
            }
        }

        return ParsedEnvelope(toWayfarerIdHex: Hex.encode(toWayfarer), manifestIdHex: Hex.encode(manifestId))
    }

    private static func validateReceiptSets(
        status: GossipReceiptStatus,
        transferItemIds: Set<String>,
        acceptedItemIds: Set<String>,
        rejectedItemIds: Set<String>
    ) -> Bool {
        guard acceptedItemIds.isSubset(of: transferItemIds) else { return false }
        guard rejectedItemIds.isSubset(of: transferItemIds) else { return false }
        guard acceptedItemIds.isDisjoint(with: rejectedItemIds) else { return false }
        let union = acceptedItemIds.union(rejectedItemIds)

        switch status {
        case .accepted:
            return acceptedItemIds == transferItemIds && rejectedItemIds.isEmpty
        case .rejected:
            return acceptedItemIds.isEmpty && rejectedItemIds == transferItemIds
        case .partial:
            return !acceptedItemIds.isEmpty && !rejectedItemIds.isEmpty && union == transferItemIds
        }
    }

    private static func isLowerHex64(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 48 ... 57, 97 ... 102:
                continue
            default:
                return false
            }
        }
        return true
    }

    private func upsertAnnouncedInventory(_ entry: GossipInventoryEntry, session: inout PeerSession) {
        if session.announcedInventoryByItemId[entry.itemId] == nil {
            session.announcedInventoryOrder.append(entry.itemId)
        }
        session.announcedInventoryByItemId[entry.itemId] = entry

        while session.announcedInventoryOrder.count > knobs.maxAnnouncedInventoryItemsPerSession {
            let evictedItemId = session.announcedInventoryOrder.removeFirst()
            session.announcedInventoryByItemId.removeValue(forKey: evictedItemId)
        }
    }

    private func evictOldTrackedFrames(session: inout PeerSession) {
        while session.trackedFrameOrder.count > knobs.maxTrackedFramesPerSession {
            let evictedKey = session.trackedFrameOrder.removeFirst()
            session.trackedFrameByIdempotencyKey.removeValue(forKey: evictedKey)
        }
    }
}

public enum GossipSyncFrameCodec {
    public enum CodecError: Swift.Error, Equatable {
        case invalidUTF8
        case invalidJSON
    }

    public static func encodeJSONData(_ frame: GossipSyncFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(frame)
    }

    public static func encodeJSONString(_ frame: GossipSyncFrame) throws -> String {
        let data = try encodeJSONData(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return text
    }

    public static func decodeJSONData(_ data: Data) throws -> GossipSyncFrame {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(GossipSyncFrame.self, from: data)
        } catch {
            throw CodecError.invalidJSON
        }
    }

    public static func decodeJSONString(_ text: String) throws -> GossipSyncFrame {
        guard let data = text.data(using: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return try decodeJSONData(data)
    }
}

private enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    static func decode(_ text: String, maxDecodedBytes: Int = Int.max) -> Data? {
        let estimatedDecodedBytes = estimatedDecodedByteCount(for: text)
        if estimatedDecodedBytes > maxDecodedBytes {
            return nil
        }

        var normalized = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        guard let decoded = Data(base64Encoded: normalized) else {
            return nil
        }
        guard decoded.count <= maxDecodedBytes else {
            return nil
        }
        return decoded
    }

    static func estimatedDecodedByteCount(for text: String) -> Int {
        ((text.count + 3) / 4) * 3
    }
}

private struct CanonicalReader {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        offset >= data.count
    }

    mutating func readUInt8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        let value = data[offset]
        offset += 1
        return value
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[offset + index])
        }
        offset += 4
        return value
    }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let slice = data[offset..<offset + count]
        offset += count
        return Data(slice)
    }
}
