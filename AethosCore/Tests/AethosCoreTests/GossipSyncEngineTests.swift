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
    #expect(retryReasons.contains("inventory_page_order_violation"))

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
