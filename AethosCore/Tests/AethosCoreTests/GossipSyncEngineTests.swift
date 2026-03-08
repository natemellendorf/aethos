import Foundation
import Testing
@testable import AethosCore

@Test
func gossipSyncFixtureHappyPathConvergesAndIsIdempotent() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000

    let transportA = CapturingTransportSender()
    let transportB = CapturingTransportSender()
    let receiptsA = CapturingReceiptRecorder()
    let receiptsB = CapturingReceiptRecorder()

    let inventoryA = StaticInventoryProvider(
        inventoryByPeer: [fixtures.peerBId: fixtures.inventorySummary.inventory],
        localItemIds: Set(fixtures.inventorySummary.inventory.map(\.itemId))
    )
    let inventoryB = MutableInventoryProvider(
        inventoryByPeer: [fixtures.peerAId: []],
        localItemIds: [fixtures.inventorySummary.inventory[0].itemId]
    )

    let requestedTransfer = fixtures.transfer.items[0]
    let payloadA = StaticMessageLoader(itemsById: [
        requestedTransfer.itemId: GossipTransferPayload(
            itemId: requestedTransfer.itemId,
            manifestId: requestedTransfer.manifestId,
            toWayfarerId: requestedTransfer.toWayfarerId,
            expiresAtUnixMs: requestedTransfer.expiresAtUnixMs,
            totalSizeBytes: requestedTransfer.totalSizeBytes,
            chunkSizeBytes: requestedTransfer.chunkSizeBytes,
            chunkCount: requestedTransfer.chunkCount,
            envelopeBytes: try #require(decodeBase64URL(requestedTransfer.envelopeB64))
        )
    ])

    let applyInboundA = ApplyingInboundTransferHandler()
    let applyInboundB = ApplyingInboundTransferHandler(onAcceptedItemId: { inventoryB.markLocalItem($0) })

    var requestIdsB = [fixtures.missingRequest.requestId, fixtures.emptyMissingRequest.requestId]

    let engineA = try GossipSyncEngine(
        localWayfarerId: fixtures.peerAId,
        inventoryProvider: inventoryA,
        messageLoader: payloadA,
        receiptRecorder: receiptsA,
        transportSender: transportA,
        inboundTransferHandler: applyInboundA,
        knobs: GossipSyncExecutionKnobs(
            maxInventoryItemsPerSession: 500,
            maxTransfersPerSession: 64,
            maxTransferItemsPerFrame: fixtures.missingRequest.maxTransferItems,
            maxTransferBytesPerFrame: fixtures.missingRequest.maxTransferBytes
        ),
        sessionIdFactory: { fixtures.sessionId },
        transferIdFactory: { fixtures.transfer.transferId }
    )

    let engineB = try GossipSyncEngine(
        localWayfarerId: fixtures.peerBId,
        inventoryProvider: inventoryB,
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: receiptsB,
        transportSender: transportB,
        inboundTransferHandler: applyInboundB,
        knobs: GossipSyncExecutionKnobs(
            maxInventoryItemsPerSession: 500,
            maxTransfersPerSession: 64,
            maxTransferItemsPerFrame: fixtures.missingRequest.maxTransferItems,
            maxTransferBytesPerFrame: fixtures.missingRequest.maxTransferBytes
        ),
        requestIdFactory: {
            let next = requestIdsB.removeFirst()
            return next
        },
        receiptIdFactory: { fixtures.receipt.receiptId }
    )

    let startedSession = try engineA.startSession(with: fixtures.peerBId, nowUnixMs: nowUnixMs)
    #expect(startedSession == fixtures.sessionId)

    let sentByA0 = transportA.takeAll()
    #expect(sentByA0.count == 1)
    #expect(sentByA0[0].peerWayfarerId == fixtures.peerBId)
    #expect(sentByA0[0].frame == .inventorySummary(fixtures.inventorySummary))

    _ = try engineB.handleInboundSyncFrame(sentByA0[0].frame, from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    let sentByB0 = transportB.takeAll()
    #expect(sentByB0.count == 1)
    #expect(sentByB0[0].frame == .missingRequest(fixtures.missingRequest))

    _ = try engineA.handleInboundSyncFrame(sentByB0[0].frame, from: fixtures.peerBId, nowUnixMs: nowUnixMs)
    let sentByA1 = transportA.takeAll()
    #expect(sentByA1.count == 1)
    #expect(sentByA1[0].frame == .transfer(fixtures.transfer))

    _ = try engineB.handleInboundSyncFrame(sentByA1[0].frame, from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    let sentByB1 = transportB.takeAll()
    #expect(sentByB1.count == 2)
    #expect(sentByB1[0].frame == .receipt(fixtures.receipt))
    #expect(sentByB1[1].frame == .missingRequest(fixtures.emptyMissingRequest))

    _ = try engineA.handleInboundSyncFrame(sentByB1[0].frame, from: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = try engineA.handleInboundSyncFrame(sentByB1[1].frame, from: fixtures.peerBId, nowUnixMs: nowUnixMs)

    #expect(engineA.currentState(for: fixtures.peerBId) == .converged)
    #expect(engineB.currentState(for: fixtures.peerAId) == .converged)
    #expect(receiptsA.records.count == 1)
    #expect(receiptsA.records[0].transferId == fixtures.transfer.transferId)

    let duplicateTransfer = try engineB.handleInboundSyncFrame(.transfer(fixtures.transfer), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    #expect(duplicateTransfer.disposition == .duplicate)
    #expect(duplicateTransfer.sentFrameCount == 0)
    #expect(transportB.takeAll().isEmpty)
}

@Test
func gossipSyncFixtureTransferEnvelopeHashMatchesItemId() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let entry = fixtures.transfer.items[0]
    let envelopeBytes = try #require(decodeBase64URL(entry.envelopeB64))
    let itemId = Hex.encode(AethosIDs.sha256(envelopeBytes))
    #expect(itemId == entry.itemId)
}

@Test
func gossipSyncIdempotencyMismatchMovesToRetryPending() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000

    let transport = CapturingTransportSender()
    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerAId,
        inventoryProvider: StaticInventoryProvider(
            inventoryByPeer: [fixtures.peerBId: fixtures.inventorySummary.inventory],
            localItemIds: Set(fixtures.inventorySummary.inventory.map(\.itemId))
        ),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        sessionIdFactory: { fixtures.sessionId }
    )

    _ = try engine.startSession(with: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    _ = try engine.handleInboundSyncFrame(.missingRequest(fixtures.missingRequest), from: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let tampered = GossipMissingRequestFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerBId,
        page: fixtures.missingRequest.page,
        hasMore: fixtures.missingRequest.hasMore,
        requestId: fixtures.missingRequest.requestId,
        inResponseToPage: fixtures.missingRequest.inResponseToPage,
        missingItemIds: fixtures.inventorySummary.inventory.map(\.itemId),
        maxTransferItems: fixtures.missingRequest.maxTransferItems,
        maxTransferBytes: fixtures.missingRequest.maxTransferBytes
    )

    let result = try engine.handleInboundSyncFrame(.missingRequest(tampered), from: fixtures.peerBId, nowUnixMs: nowUnixMs)
    #expect(result.disposition == .retryPending)
    #expect(engine.currentState(for: fixtures.peerBId) == .retryPending)
}

@Test
func gossipSyncPageAndSessionViolationsMoveToRetryPending() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000

    let transport = CapturingTransportSender()
    var retryReasons: [String] = []

    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerBId,
        inventoryProvider: StaticInventoryProvider(inventoryByPeer: [:], localItemIds: []),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) })
    )

    let badInventoryPage = GossipInventorySummaryFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerAId,
        page: 2,
        hasMore: false,
        inventory: fixtures.inventorySummary.inventory
    )

    let result1 = try engine.handleInboundSyncFrame(.inventorySummary(badInventoryPage), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    #expect(result1.disposition == .retryPending)
    #expect(engine.currentState(for: fixtures.peerAId) == .retryPending)
    #expect(retryReasons.contains("inventory_pagination_violation"))

    engine.cancelSession(with: fixtures.peerAId)
    _ = try engine.startSession(with: fixtures.peerAId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let wrongSession = GossipMissingRequestFrame(
        sessionId: "sess-mismatch-1",
        senderWayfarerId: fixtures.peerAId,
        page: 1,
        hasMore: false,
        requestId: fixtures.missingRequest.requestId,
        inResponseToPage: 1,
        missingItemIds: fixtures.missingRequest.missingItemIds,
        maxTransferItems: fixtures.missingRequest.maxTransferItems,
        maxTransferBytes: fixtures.missingRequest.maxTransferBytes
    )

    let result2 = try engine.handleInboundSyncFrame(.missingRequest(wrongSession), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    #expect(result2.disposition == .retryPending)
    #expect(engine.currentState(for: fixtures.peerAId) == .retryPending)
    #expect(retryReasons.contains("session_mismatch"))
}

@Test
func gossipSyncRejectsSenderSpoofingWithRetryPending() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000

    var retryReasons: [String] = []
    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerBId,
        inventoryProvider: StaticInventoryProvider(inventoryByPeer: [:], localItemIds: []),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: CapturingTransportSender(),
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) })
    )

    let spoofedSender = GossipInventorySummaryFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerBId,
        page: 1,
        hasMore: false,
        inventory: fixtures.inventorySummary.inventory
    )

    let result = try engine.handleInboundSyncFrame(.inventorySummary(spoofedSender), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    #expect(result.disposition == .retryPending)
    #expect(engine.currentState(for: fixtures.peerAId) == .retryPending)
    #expect(retryReasons.contains("sender_peer_mismatch"))
}

@Test
func gossipSyncRejectsInventoryPageAfterTerminalPage() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000

    var retryReasons: [String] = []
    let transport = CapturingTransportSender()
    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerBId,
        inventoryProvider: StaticInventoryProvider(inventoryByPeer: [:], localItemIds: []),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) })
    )

    _ = try engine.handleInboundSyncFrame(.inventorySummary(fixtures.inventorySummary), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let pageTwo = GossipInventorySummaryFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerAId,
        page: 2,
        hasMore: false,
        inventory: []
    )
    let result = try engine.handleInboundSyncFrame(.inventorySummary(pageTwo), from: fixtures.peerAId, nowUnixMs: nowUnixMs)

    #expect(result.disposition == .retryPending)
    #expect(engine.currentState(for: fixtures.peerAId) == .retryPending)
    #expect(retryReasons.contains("inventory_pagination_violation"))
}

@Test
func gossipSyncRejectsMultiPageMissingRequestInMVP0Mode() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000

    var retryReasons: [String] = []
    let transport = CapturingTransportSender()
    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerAId,
        inventoryProvider: StaticInventoryProvider(
            inventoryByPeer: [fixtures.peerBId: fixtures.inventorySummary.inventory],
            localItemIds: Set(fixtures.inventorySummary.inventory.map(\.itemId))
        ),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) }),
        sessionIdFactory: { fixtures.sessionId }
    )

    _ = try engine.startSession(with: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let multiPage = GossipMissingRequestFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerBId,
        page: 2,
        hasMore: false,
        requestId: fixtures.missingRequest.requestId,
        inResponseToPage: 1,
        missingItemIds: fixtures.missingRequest.missingItemIds,
        maxTransferItems: fixtures.missingRequest.maxTransferItems,
        maxTransferBytes: fixtures.missingRequest.maxTransferBytes
    )
    let result = try engine.handleInboundSyncFrame(.missingRequest(multiPage), from: fixtures.peerBId, nowUnixMs: nowUnixMs)

    #expect(result.disposition == .retryPending)
    #expect(engine.currentState(for: fixtures.peerBId) == .retryPending)
    #expect(retryReasons.contains("missing_request_pagination_violation"))
}

@Test
func gossipSyncAppliesInboundCapsToMissingAndTransferFrames() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000

    var retryReasons: [String] = []
    let transport = CapturingTransportSender()
    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerAId,
        inventoryProvider: StaticInventoryProvider(
            inventoryByPeer: [fixtures.peerBId: fixtures.inventorySummary.inventory],
            localItemIds: Set(fixtures.inventorySummary.inventory.map(\.itemId))
        ),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        knobs: GossipSyncExecutionKnobs(
            maxInventoryItemsPerSession: 500,
            maxTransfersPerSession: 64,
            maxTransferItemsPerFrame: 8,
            maxTransferBytesPerFrame: 262_144,
            maxInboundInventoryItemsPerFrame: 500,
            maxInboundMissingItemIdsPerFrame: 2,
            maxInboundTransferItemsPerFrame: 1,
            maxDecodedEnvelopeBytes: 64,
            maxTrackedFramesPerSession: 64,
            maxAnnouncedInventoryItemsPerSession: 500
        ),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) }),
        sessionIdFactory: { fixtures.sessionId }
    )

    _ = try engine.startSession(with: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let tooManyMissing = GossipMissingRequestFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerBId,
        page: 1,
        hasMore: false,
        requestId: "req-over-cap",
        inResponseToPage: 1,
        missingItemIds: [
            fixtures.transfer.items[0].itemId,
            fixtures.inventorySummary.inventory[0].itemId,
            fixtures.inventorySummary.inventory[1].itemId
        ],
        maxTransferItems: fixtures.missingRequest.maxTransferItems,
        maxTransferBytes: fixtures.missingRequest.maxTransferBytes
    )
    let missingResult = try engine.handleInboundSyncFrame(.missingRequest(tooManyMissing), from: fixtures.peerBId, nowUnixMs: nowUnixMs)

    #expect(missingResult.disposition == .retryPending)
    #expect(retryReasons.contains("missing_request_items_exceeded"))

    engine.cancelSession(with: fixtures.peerBId)
    _ = try engine.startSession(with: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let tooManyTransferItems = GossipTransferFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerBId,
        page: 1,
        hasMore: false,
        transferId: "xfer-count-cap",
        inResponseToRequestId: "req-any",
        items: [fixtures.transfer.items[0], fixtures.transfer.items[0]]
    )
    let transferCountResult = try engine.handleInboundSyncFrame(.transfer(tooManyTransferItems), from: fixtures.peerBId, nowUnixMs: nowUnixMs)
    #expect(transferCountResult.disposition == .retryPending)
    #expect(retryReasons.contains("transfer_items_exceeded"))
}

@Test
func gossipSyncRejectsOversizedTransferEnvelopeBeforeDecode() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000
    let requestId = "req-envelope-cap"

    var retryReasons: [String] = []
    let transport = CapturingTransportSender()
    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerBId,
        inventoryProvider: StaticInventoryProvider(
            inventoryByPeer: [:],
            localItemIds: []
        ),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        knobs: GossipSyncExecutionKnobs(
            maxInventoryItemsPerSession: 500,
            maxTransfersPerSession: 64,
            maxTransferItemsPerFrame: 8,
            maxTransferBytesPerFrame: 262_144,
            maxInboundInventoryItemsPerFrame: 500,
            maxInboundMissingItemIdsPerFrame: 500,
            maxInboundTransferItemsPerFrame: 4,
            maxDecodedEnvelopeBytes: 64,
            maxTrackedFramesPerSession: 64,
            maxAnnouncedInventoryItemsPerSession: 500
        ),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) }),
        requestIdFactory: { requestId }
    )

    _ = try engine.handleInboundSyncFrame(.inventorySummary(fixtures.inventorySummary), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let statsBeforeTransfer = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerAId))

    let hugeEnvelope = String(repeating: "A", count: 250_000)
    let oversizedEnvelopeTransfer = GossipTransferFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerAId,
        page: 1,
        hasMore: false,
        transferId: "xfer-envelope-cap",
        inResponseToRequestId: requestId,
        items: [
            GossipTransferEntry(
                itemId: fixtures.transfer.items[0].itemId,
                manifestId: fixtures.transfer.items[0].manifestId,
                toWayfarerId: fixtures.transfer.items[0].toWayfarerId,
                expiresAtUnixMs: fixtures.transfer.items[0].expiresAtUnixMs,
                totalSizeBytes: fixtures.transfer.items[0].totalSizeBytes,
                chunkSizeBytes: fixtures.transfer.items[0].chunkSizeBytes,
                chunkCount: fixtures.transfer.items[0].chunkCount,
                envelopeB64: hugeEnvelope
            )
        ]
    )

    let transferResult = try engine.handleInboundSyncFrame(.transfer(oversizedEnvelopeTransfer), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    #expect(transferResult.disposition == .retryPending)
    #expect(retryReasons.contains("transfer_envelope_bytes_exceeded"))

    let statsAfterTransfer = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerAId))
    #expect(statsAfterTransfer.trackedFrameCount == statsBeforeTransfer.trackedFrameCount)
}

@Test
func gossipSyncRejectsOversizedSessionIdBeforeTracking() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000

    var retryReasons: [String] = []
    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerBId,
        inventoryProvider: StaticInventoryProvider(inventoryByPeer: [:], localItemIds: []),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: CapturingTransportSender(),
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) })
    )

    let oversizedSessionId = String(repeating: "a", count: 100_000)
    let frame = GossipInventorySummaryFrame(
        sessionId: oversizedSessionId,
        senderWayfarerId: fixtures.peerAId,
        page: 1,
        hasMore: false,
        inventory: fixtures.inventorySummary.inventory
    )

    let result = try engine.handleInboundSyncFrame(.inventorySummary(frame), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    #expect(result.disposition == .retryPending)
    #expect(retryReasons.contains("invalid_session_id"))

    let stats = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerAId))
    #expect(stats.trackedFrameCount == 0)
}

@Test
func gossipSyncRejectsOversizedReceiptMessageBeforeTracking() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000
    let requestId = "req-large-receipt-message"
    let transferId = "xfer-large-receipt-message"

    var retryReasons: [String] = []
    let transport = CapturingTransportSender()
    let requestedTransfer = fixtures.transfer.items[0]
    let payload = GossipTransferPayload(
        itemId: requestedTransfer.itemId,
        manifestId: requestedTransfer.manifestId,
        toWayfarerId: requestedTransfer.toWayfarerId,
        expiresAtUnixMs: requestedTransfer.expiresAtUnixMs,
        totalSizeBytes: requestedTransfer.totalSizeBytes,
        chunkSizeBytes: requestedTransfer.chunkSizeBytes,
        chunkCount: requestedTransfer.chunkCount,
        envelopeBytes: try #require(decodeBase64URL(requestedTransfer.envelopeB64))
    )

    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerAId,
        inventoryProvider: StaticInventoryProvider(
            inventoryByPeer: [fixtures.peerBId: fixtures.inventorySummary.inventory],
            localItemIds: Set(fixtures.inventorySummary.inventory.map(\.itemId))
        ),
        messageLoader: StaticMessageLoader(itemsById: [requestedTransfer.itemId: payload]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) }),
        sessionIdFactory: { fixtures.sessionId },
        transferIdFactory: { transferId }
    )

    _ = try engine.startSession(with: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let missingRequest = GossipMissingRequestFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerBId,
        page: 1,
        hasMore: false,
        requestId: requestId,
        inResponseToPage: 1,
        missingItemIds: [requestedTransfer.itemId],
        maxTransferItems: fixtures.missingRequest.maxTransferItems,
        maxTransferBytes: fixtures.missingRequest.maxTransferBytes
    )

    _ = try engine.handleInboundSyncFrame(.missingRequest(missingRequest), from: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let statsBeforeReceipt = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerBId))

    let receipt = GossipReceiptFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerBId,
        page: 1,
        hasMore: false,
        receiptId: "rcpt-large-message",
        inResponseToTransferId: transferId,
        status: .rejected,
        acceptedItemIds: [],
        rejectedItems: [
            GossipRejectedItem(
                itemId: requestedTransfer.itemId,
                code: "ITEM_REJECTED",
                message: String(repeating: "m", count: 100_000)
            )
        ]
    )

    let receiptResult = try engine.handleInboundSyncFrame(.receipt(receipt), from: fixtures.peerBId, nowUnixMs: nowUnixMs)
    #expect(receiptResult.disposition == .retryPending)
    #expect(retryReasons.contains("receipt_rejected_message_bytes_exceeded"))

    let statsAfterReceipt = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerBId))
    #expect(statsAfterReceipt.trackedFrameCount == statsBeforeReceipt.trackedFrameCount)
}

@Test
func gossipSyncRejectsReceiptDuplicateAcceptedItemIdsBeforeTracking() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000
    let requestId = "req-duplicate-accepted"
    let transferId = "xfer-duplicate-accepted"

    var retryReasons: [String] = []
    let transport = CapturingTransportSender()
    let requestedTransfer = fixtures.transfer.items[0]
    let payload = GossipTransferPayload(
        itemId: requestedTransfer.itemId,
        manifestId: requestedTransfer.manifestId,
        toWayfarerId: requestedTransfer.toWayfarerId,
        expiresAtUnixMs: requestedTransfer.expiresAtUnixMs,
        totalSizeBytes: requestedTransfer.totalSizeBytes,
        chunkSizeBytes: requestedTransfer.chunkSizeBytes,
        chunkCount: requestedTransfer.chunkCount,
        envelopeBytes: try #require(decodeBase64URL(requestedTransfer.envelopeB64))
    )

    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerAId,
        inventoryProvider: StaticInventoryProvider(
            inventoryByPeer: [fixtures.peerBId: fixtures.inventorySummary.inventory],
            localItemIds: Set(fixtures.inventorySummary.inventory.map(\.itemId))
        ),
        messageLoader: StaticMessageLoader(itemsById: [requestedTransfer.itemId: payload]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) }),
        sessionIdFactory: { fixtures.sessionId },
        transferIdFactory: { transferId }
    )

    _ = try engine.startSession(with: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let missingRequest = GossipMissingRequestFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerBId,
        page: 1,
        hasMore: false,
        requestId: requestId,
        inResponseToPage: 1,
        missingItemIds: [requestedTransfer.itemId],
        maxTransferItems: fixtures.missingRequest.maxTransferItems,
        maxTransferBytes: fixtures.missingRequest.maxTransferBytes
    )

    _ = try engine.handleInboundSyncFrame(.missingRequest(missingRequest), from: fixtures.peerBId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let statsBeforeReceipt = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerBId))

    let duplicateAccepted = GossipReceiptFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerBId,
        page: 1,
        hasMore: false,
        receiptId: "rcpt-duplicate-accepted",
        inResponseToTransferId: transferId,
        status: .accepted,
        acceptedItemIds: [requestedTransfer.itemId, requestedTransfer.itemId],
        rejectedItems: []
    )

    let receiptResult = try engine.handleInboundSyncFrame(.receipt(duplicateAccepted), from: fixtures.peerBId, nowUnixMs: nowUnixMs)
    #expect(receiptResult.disposition == .retryPending)
    #expect(retryReasons.contains("receipt_duplicate_item_ids"))

    let statsAfterReceipt = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerBId))
    #expect(statsAfterReceipt.trackedFrameCount == statsBeforeReceipt.trackedFrameCount)
}

@Test
func gossipSyncRejectsTransferWithInvalidBase64URLBeforeTracking() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000
    let requestId = "req-base64-strict"

    var retryReasons: [String] = []
    let transport = CapturingTransportSender()
    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerBId,
        inventoryProvider: StaticInventoryProvider(inventoryByPeer: [:], localItemIds: []),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) }),
        requestIdFactory: { requestId }
    )

    _ = try engine.handleInboundSyncFrame(.inventorySummary(fixtures.inventorySummary), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let statsBeforeTransfer = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerAId))

    let invalidBase64 = fixtures.transfer.items[0].envelopeB64 + "="
    let invalidTransfer = GossipTransferFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerAId,
        page: 1,
        hasMore: false,
        transferId: "xfer-invalid-base64",
        inResponseToRequestId: requestId,
        items: [
            GossipTransferEntry(
                itemId: fixtures.transfer.items[0].itemId,
                manifestId: fixtures.transfer.items[0].manifestId,
                toWayfarerId: fixtures.transfer.items[0].toWayfarerId,
                expiresAtUnixMs: fixtures.transfer.items[0].expiresAtUnixMs,
                totalSizeBytes: fixtures.transfer.items[0].totalSizeBytes,
                chunkSizeBytes: fixtures.transfer.items[0].chunkSizeBytes,
                chunkCount: fixtures.transfer.items[0].chunkCount,
                envelopeB64: invalidBase64
            )
        ]
    )

    let transferResult = try engine.handleInboundSyncFrame(.transfer(invalidTransfer), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    #expect(transferResult.disposition == .retryPending)
    #expect(retryReasons.contains("invalid_envelope_b64"))

    let statsAfterTransfer = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerAId))
    #expect(statsAfterTransfer.trackedFrameCount == statsBeforeTransfer.trackedFrameCount)
}

@Test
func gossipSyncRejectsTransferWithNonURLBase64AlphabetBeforeTracking() throws {
    let fixtures = try GossipFixtureCatalog.load()
    let nowUnixMs: UInt64 = 1_767_000_000_000
    let requestId = "req-base64-plus"

    var retryReasons: [String] = []
    let transport = CapturingTransportSender()
    let engine = try GossipSyncEngine(
        localWayfarerId: fixtures.peerBId,
        inventoryProvider: StaticInventoryProvider(inventoryByPeer: [:], localItemIds: []),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        hooks: GossipSyncHooks(onRetryPending: { retryReasons.append($0.reason) }),
        requestIdFactory: { requestId }
    )

    _ = try engine.handleInboundSyncFrame(.inventorySummary(fixtures.inventorySummary), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let statsBeforeTransfer = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerAId))

    let invalidBase64 = "+" + fixtures.transfer.items[0].envelopeB64
    let invalidTransfer = GossipTransferFrame(
        sessionId: fixtures.sessionId,
        senderWayfarerId: fixtures.peerAId,
        page: 1,
        hasMore: false,
        transferId: "xfer-invalid-base64-plus",
        inResponseToRequestId: requestId,
        items: [
            GossipTransferEntry(
                itemId: fixtures.transfer.items[0].itemId,
                manifestId: fixtures.transfer.items[0].manifestId,
                toWayfarerId: fixtures.transfer.items[0].toWayfarerId,
                expiresAtUnixMs: fixtures.transfer.items[0].expiresAtUnixMs,
                totalSizeBytes: fixtures.transfer.items[0].totalSizeBytes,
                chunkSizeBytes: fixtures.transfer.items[0].chunkSizeBytes,
                chunkCount: fixtures.transfer.items[0].chunkCount,
                envelopeB64: invalidBase64
            )
        ]
    )

    let transferResult = try engine.handleInboundSyncFrame(.transfer(invalidTransfer), from: fixtures.peerAId, nowUnixMs: nowUnixMs)
    #expect(transferResult.disposition == .retryPending)
    #expect(retryReasons.contains("invalid_envelope_b64"))

    let statsAfterTransfer = try #require(engine.debugSessionStats(peerWayfarerId: fixtures.peerAId))
    #expect(statsAfterTransfer.trackedFrameCount == statsBeforeTransfer.trackedFrameCount)
}

@Test
func gossipSyncEvictsOldTrackedFramesWhenPerSessionCapExceeded() throws {
    let nowUnixMs: UInt64 = 1_767_000_000_000
    let localWayfarerId = makeHex64(0x11)
    let peerWayfarerId = makeHex64(0x22)
    let sessionId = "sess-evict-tracked"

    let transport = CapturingTransportSender()
    let engine = try GossipSyncEngine(
        localWayfarerId: localWayfarerId,
        inventoryProvider: StaticInventoryProvider(inventoryByPeer: [:], localItemIds: []),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        knobs: GossipSyncExecutionKnobs(
            maxInventoryItemsPerSession: 500,
            maxTransfersPerSession: 64,
            maxTransferItemsPerFrame: 8,
            maxTransferBytesPerFrame: 262_144,
            maxInboundInventoryItemsPerFrame: 500,
            maxInboundMissingItemIdsPerFrame: 500,
            maxInboundTransferItemsPerFrame: 64,
            maxDecodedEnvelopeBytes: 262_144,
            maxTrackedFramesPerSession: 2,
            maxAnnouncedInventoryItemsPerSession: 500
        ),
        sessionIdFactory: { sessionId }
    )

    _ = try engine.startSession(with: peerWayfarerId, nowUnixMs: nowUnixMs)
    _ = transport.takeAll()

    let requestIds = ["req-evict-1", "req-evict-2", "req-evict-3"]
    for requestId in requestIds {
        let frame = GossipMissingRequestFrame(
            sessionId: sessionId,
            senderWayfarerId: peerWayfarerId,
            page: 1,
            hasMore: false,
            requestId: requestId,
            inResponseToPage: 1,
            missingItemIds: [makeHex64(0x33)],
            maxTransferItems: 8,
            maxTransferBytes: 262_144
        )

        let result = try engine.handleInboundSyncFrame(.missingRequest(frame), from: peerWayfarerId, nowUnixMs: nowUnixMs)
        #expect(result.disposition == .handled)
        _ = transport.takeAll()
    }

    let stats = try #require(engine.debugSessionStats(peerWayfarerId: peerWayfarerId))
    #expect(stats.trackedFrameCount == 2)
    #expect(stats.trackedFrameKeysInOrder == [
        "missing|\(sessionId)|req-evict-2|1",
        "missing|\(sessionId)|req-evict-3|1"
    ])
    #expect(stats.trackedFrameFingerprintByteCountMax == 32)
}

@Test
func gossipSyncEvictsOldAnnouncedInventoryItemsWhenPerSessionCapExceeded() throws {
    let nowUnixMs: UInt64 = 1_767_000_000_000
    let localWayfarerId = makeHex64(0x44)
    let peerWayfarerId = makeHex64(0x55)
    let sessionId = "sess-evict-announced"

    let transport = CapturingTransportSender()
    let engine = try GossipSyncEngine(
        localWayfarerId: localWayfarerId,
        inventoryProvider: StaticInventoryProvider(inventoryByPeer: [:], localItemIds: []),
        messageLoader: StaticMessageLoader(itemsById: [:]),
        receiptRecorder: CapturingReceiptRecorder(),
        transportSender: transport,
        inboundTransferHandler: ApplyingInboundTransferHandler(),
        knobs: GossipSyncExecutionKnobs(
            maxInventoryItemsPerSession: 500,
            maxTransfersPerSession: 64,
            maxTransferItemsPerFrame: 8,
            maxTransferBytesPerFrame: 262_144,
            maxInboundInventoryItemsPerFrame: 500,
            maxInboundMissingItemIdsPerFrame: 500,
            maxInboundTransferItemsPerFrame: 64,
            maxDecodedEnvelopeBytes: 262_144,
            maxTrackedFramesPerSession: 64,
            maxAnnouncedInventoryItemsPerSession: 2
        )
    )

    let inventory = [
        makeInventoryEntry(seed: 0x01, nowUnixMs: nowUnixMs),
        makeInventoryEntry(seed: 0x02, nowUnixMs: nowUnixMs),
        makeInventoryEntry(seed: 0x03, nowUnixMs: nowUnixMs)
    ]

    let frame = GossipInventorySummaryFrame(
        sessionId: sessionId,
        senderWayfarerId: peerWayfarerId,
        page: 1,
        hasMore: false,
        inventory: inventory
    )

    let result = try engine.handleInboundSyncFrame(.inventorySummary(frame), from: peerWayfarerId, nowUnixMs: nowUnixMs)
    #expect(result.disposition == .handled)
    _ = transport.takeAll()

    let stats = try #require(engine.debugSessionStats(peerWayfarerId: peerWayfarerId))
    #expect(stats.announcedInventoryCount == 2)
    #expect(stats.announcedInventoryItemIdsInOrder == [inventory[1].itemId, inventory[2].itemId])
}

private struct GossipFixtureCatalog {
    let inventorySummary: GossipInventorySummaryFrame
    let missingRequest: GossipMissingRequestFrame
    let emptyMissingRequest: GossipMissingRequestFrame
    let transfer: GossipTransferFrame
    let receipt: GossipReceiptFrame
    let sessionId: String
    let peerAId: String
    let peerBId: String

    static func load() throws -> GossipFixtureCatalog {
        let inventorySummary = try loadFixture("inventory_summary.page1.json", as: GossipInventorySummaryFrame.self)
        let missingRequest = try loadFixture("missing_request.page1.json", as: GossipMissingRequestFrame.self)
        let emptyMissingRequest = try loadFixture("missing_request.empty.page1.json", as: GossipMissingRequestFrame.self)
        let transfer = try loadFixture("transfer.page1.json", as: GossipTransferFrame.self)
        let receipt = try loadFixture("receipt.page1.json", as: GossipReceiptFrame.self)

        return GossipFixtureCatalog(
            inventorySummary: inventorySummary,
            missingRequest: missingRequest,
            emptyMissingRequest: emptyMissingRequest,
            transfer: transfer,
            receipt: receipt,
            sessionId: inventorySummary.sessionId,
            peerAId: inventorySummary.senderWayfarerId,
            peerBId: missingRequest.senderWayfarerId
        )
    }

    private static func loadFixture<T: Decodable>(_ fileName: String, as type: T.Type) throws -> T {
        let data = try Data(contentsOf: fixtureRoot().appendingPathComponent(fileName))
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }

    private static func fixtureRoot(filePath: String = #filePath) -> URL {
        var cursor = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = cursor
                .appendingPathComponent("testdata", isDirectory: true)
                .appendingPathComponent("gossip_sync", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: filePath)
    }
}

private struct CapturedSyncFrame: Equatable {
    let frame: GossipSyncFrame
    let peerWayfarerId: String
}

private final class CapturingTransportSender: GossipTransportSending {
    private(set) var sent: [CapturedSyncFrame] = []

    func sendSyncFrame(_ frame: GossipSyncFrame, to peerWayfarerId: String) throws {
        sent.append(CapturedSyncFrame(frame: frame, peerWayfarerId: peerWayfarerId))
    }

    func takeAll() -> [CapturedSyncFrame] {
        let current = sent
        sent.removeAll(keepingCapacity: true)
        return current
    }
}

private final class StaticInventoryProvider: GossipInventoryProviding {
    private let inventoryByPeer: [String: [GossipInventoryEntry]]
    private let localItemIds: Set<String>

    init(inventoryByPeer: [String: [GossipInventoryEntry]], localItemIds: Set<String>) {
        self.inventoryByPeer = inventoryByPeer
        self.localItemIds = localItemIds
    }

    func localInventory(for peerWayfarerId: String, nowUnixMs _: UInt64, limit: Int) throws -> [GossipInventoryEntry] {
        Array((inventoryByPeer[peerWayfarerId] ?? []).prefix(limit))
    }

    func hasLocalItem(itemId: String) throws -> Bool {
        localItemIds.contains(itemId)
    }
}

private final class MutableInventoryProvider: GossipInventoryProviding {
    private let inventoryByPeer: [String: [GossipInventoryEntry]]
    private var localItemIds: Set<String>

    init(inventoryByPeer: [String: [GossipInventoryEntry]], localItemIds: Set<String>) {
        self.inventoryByPeer = inventoryByPeer
        self.localItemIds = localItemIds
    }

    func localInventory(for peerWayfarerId: String, nowUnixMs _: UInt64, limit: Int) throws -> [GossipInventoryEntry] {
        Array((inventoryByPeer[peerWayfarerId] ?? []).prefix(limit))
    }

    func hasLocalItem(itemId: String) throws -> Bool {
        localItemIds.contains(itemId)
    }

    func markLocalItem(_ itemId: String) {
        localItemIds.insert(itemId)
    }
}

private final class StaticMessageLoader: GossipMessageLoading {
    private let itemsById: [String: GossipTransferPayload]

    init(itemsById: [String: GossipTransferPayload]) {
        self.itemsById = itemsById
    }

    func loadTransferPayload(itemId: String) throws -> GossipTransferPayload? {
        itemsById[itemId]
    }
}

private final class CapturingReceiptRecorder: GossipReceiptRecording {
    private(set) var records: [GossipSyncReceiptRecord] = []

    func recordSyncReceipt(_ record: GossipSyncReceiptRecord) throws {
        records.append(record)
    }
}

private final class ApplyingInboundTransferHandler: GossipInboundTransferApplying {
    private var appliedItemIds: Set<String> = []
    private let onAcceptedItemId: ((String) -> Void)?

    init(onAcceptedItemId: ((String) -> Void)? = nil) {
        self.onAcceptedItemId = onAcceptedItemId
    }

    func applyInboundTransferItem(_ item: GossipTransferEntry, from _: String, sessionId _: String) throws -> GossipInboundApplyResult {
        if appliedItemIds.contains(item.itemId) {
            return .alreadyPresent
        }
        appliedItemIds.insert(item.itemId)
        onAcceptedItemId?(item.itemId)
        return .accepted
    }
}

private func makeHex64(_ byte: UInt8) -> String {
    String(repeating: String(format: "%02x", byte), count: 32)
}

private func makeInventoryEntry(seed: UInt8, nowUnixMs: UInt64) -> GossipInventoryEntry {
    GossipInventoryEntry(
        itemId: makeHex64(seed),
        manifestId: makeHex64(seed &+ 1),
        toWayfarerId: makeHex64(seed &+ 2),
        expiresAtUnixMs: nowUnixMs + 60_000,
        totalSizeBytes: 1024,
        chunkSizeBytes: GossipSyncEngine.fixedChunkSizeBytes,
        chunkCount: 1
    )
}

private func decodeBase64URL(_ text: String) -> Data? {
    var normalized = text
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder != 0 {
        normalized += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: normalized)
}
