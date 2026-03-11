import Foundation

/// Transport-neutral encounter/session engine for Gossip v1.
///
/// Source of truth:
/// - `docs/protocol/encounter.md`
/// - `docs/protocol/frames.md`
/// - `docs/protocol/gossip.md`
public struct GossipV1EncounterEngine: Sendable {
    public enum State: Equatable, Sendable {
        case awaitingHello
        case active
        case terminated(reason: TerminationReason)
    }

    public enum TerminationReason: Equatable, Sendable {
        case helloVersionMismatch(expected: UInt64, actual: UInt64)
        case protocolViolation(String)
    }

    public enum ValidationError: Swift.Error, Equatable, Sendable {
        case encounterTerminated
        case helloRequiredFirst
        case invalidHelloVersion(expected: UInt64, actual: UInt64)

        /// Peer caps were not established, but outbound builders were used.
        case peerCapsUnknown

        case wantTooManyItems(max: Int, actual: Int)

        case transferTooManyObjects(max: Int, actual: Int)
        case transferOversize(maxBytes: Int, actualBytes: Int)
        case transferExpired(nowUnixMs: UInt64, expiryUnixMs: UInt64)
        case hopRegression(existing: UInt16, incoming: UInt16)
        case hopOverflow

        case receiptWithoutPrecedingTransfer
        case receiptNotSubsetOfLastTransfer
    }

    public struct PeerCaps: Equatable, Sendable {
        public let maxWant: Int
        public let maxTransfer: Int

        public init(maxWant: Int, maxTransfer: Int) {
            self.maxWant = maxWant
            self.maxTransfer = maxTransfer
        }
    }

    // MARK: - Test boundaries

    public protocol Clock: Sendable {
        func nowUnixMs() -> UInt64
    }

    public protocol Store: Sendable {
        func eligibleItemIDs(nowMs: UInt64) throws -> [GossipV1ItemID]
        func fetch(_ itemID: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)?
        func existingHopCount(_ itemID: GossipV1ItemID) throws -> UInt16?

        /// Ingest MUST enforce hop regression rule:
        /// - reject if incoming hop < existing hop
        /// - allow equal as idempotent
        func ingest(_ itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) throws
    }

    public protocol RelayIngestObserving: Sendable {
        func noteAuthenticatedRelayIngest(itemIDs: [GossipV1ItemID], nowMs: UInt64) throws
    }

    // MARK: - API

    public struct Config: Equatable, Sendable {
        public let localHello: GossipV1HelloFrame

        public init(localHello: GossipV1HelloFrame) {
            self.localHello = localHello
        }
    }

    public struct InboundResult: Equatable, Sendable {
        public let state: State
        public let outbound: [GossipV1Frame]
        public let acceptedTransferItemIDs: [GossipV1ItemID]
    }

    private(set) public var state: State = .awaitingHello
    private(set) public var peerCaps: PeerCaps?

    private var lastValidInboundTransferIDs: Set<GossipV1ItemID>?
    private var lastValidOutboundTransferIDs: Set<GossipV1ItemID>?

    private let config: Config

    public init(config: Config) {
        self.config = config
    }

    #if DEBUG
    /// Test-only initializer for constructing specific internal states.
    ///
    /// This is intentionally DEBUG-only so production builds cannot depend on it.
    internal init(_testing config: Config, state: State, peerCaps: PeerCaps?) {
        self.init(config: config)
        self.state = state
        self.peerCaps = peerCaps
    }
    #endif

    // MARK: - Outbound builders

    public func buildHello() -> GossipV1Frame {
        .hello(config.localHello)
    }

    public func buildSummary(clock: some Clock, store: some Store) throws -> GossipV1Frame {
        let nowMs = clock.nowUnixMs()
        let eligible = try store.eligibleItemIDs(nowMs: nowMs)
        let bloom = GossipV1BloomFilter.build(for: eligible)
        let frame = try GossipV1SummaryFrame(bloomFilter: bloom, itemCount: UInt64(eligible.count))
        return .summary(frame)
    }

    public func buildRequest(want: [GossipV1ItemID]) throws -> GossipV1Frame {
        switch state {
        case .terminated:
            throw ValidationError.encounterTerminated
        case .awaitingHello:
            throw ValidationError.helloRequiredFirst
        case .active:
            break
        }
        guard peerCaps != nil else { throw ValidationError.peerCapsUnknown }
        let validated = try validateOutboundWantAgainstPeer(want)
        return .request(try GossipV1RequestFrame(want: validated))
    }

    /// Builds an outbound TRANSFER and records it as the last outbound transfer.
    public mutating func buildTransfer(objects: [GossipV1TransferFrame.Object]) throws -> GossipV1Frame {
        switch state {
        case .terminated:
            throw ValidationError.encounterTerminated
        case .awaitingHello:
            throw ValidationError.helloRequiredFirst
        case .active:
            break
        }
        guard peerCaps != nil else { throw ValidationError.peerCapsUnknown }
        let maxObjects = maxOutboundTransferObjectsAllowed()
        guard objects.count <= maxObjects else {
            throw ValidationError.transferTooManyObjects(max: maxObjects, actual: objects.count)
        }
        let transfer = try GossipV1TransferFrame(objects: objects)
        lastValidOutboundTransferIDs = Set(objects.map { $0.itemID })
        return .transfer(transfer)
    }

    // MARK: - Inbound processing

    public mutating func ingestInboundFrame(
        _ frame: GossipV1Frame,
        clock: some Clock,
        store: some Store
    ) throws -> InboundResult {
        switch state {
        case .terminated:
            throw ValidationError.encounterTerminated
        case .awaitingHello:
            guard case .hello = frame else {
                throw ValidationError.helloRequiredFirst
            }
        case .active:
            break
        }

        switch frame {
        case .hello(let hello):
            try handleHello(hello)
            return InboundResult(state: state, outbound: [], acceptedTransferItemIDs: [])

        case .summary:
            return InboundResult(state: state, outbound: [], acceptedTransferItemIDs: [])

        case .request(let request):
            let transfer = try handleInboundRequest(request, clock: clock, store: store)
            return InboundResult(state: state, outbound: [transfer], acceptedTransferItemIDs: [])

        case .transfer(let transfer):
            let accepted = try handleInboundTransfer(transfer, clock: clock, store: store)
            let receipt = try buildReceiptForLastInboundTransfer(received: accepted)
            return InboundResult(state: state, outbound: [receipt], acceptedTransferItemIDs: accepted)

        case .receipt(let receipt):
            try handleInboundReceipt(receipt)
            return InboundResult(state: state, outbound: [], acceptedTransferItemIDs: [])

        case .relayIngest:
            return InboundResult(state: state, outbound: [], acceptedTransferItemIDs: [])
        }
    }

    /// Convenience boundary: decode + ingest a single datagram frame.
    public mutating func ingestInboundDatagram(
        _ datagram: Data,
        clock: some Clock,
        store: some Store
    ) throws -> InboundResult {
        let frame = try GossipV1Framing.decodeDatagram(datagram)
        return try ingestInboundFrame(frame, clock: clock, store: store)
    }

    // MARK: - Relay ingest trust boundary

    public func handleRelayIngest(
        _ frame: GossipV1RelayIngestFrame,
        isAuthenticatedRelayTransport: Bool,
        clock: some Clock,
        observer: (some RelayIngestObserving)?
    ) throws {
        guard isAuthenticatedRelayTransport else {
            // Unauthenticated MUST have zero effect.
            return
        }
        guard let observer else { return }

        // Observer non-cancellation errors are surfaced to the transport adapter as local application errors.
        // Cancellation is propagated by rethrowing.
        // Observer errors MUST NOT change encounter state.
        try observer.noteAuthenticatedRelayIngest(itemIDs: frame.itemIDs, nowMs: clock.nowUnixMs())
    }

    // MARK: - Hop forwarding helper

    public static func forwardingHopCount(storedHopCount: UInt16) -> UInt16? {
        guard storedHopCount < .max else { return nil }
        return storedHopCount &+ 1
    }

    // MARK: - Private handlers

    private mutating func handleHello(_ hello: GossipV1HelloFrame) throws {
        guard hello.version == GossipV1.GOSSIP_VERSION else {
            state = .terminated(reason: .helloVersionMismatch(expected: GossipV1.GOSSIP_VERSION, actual: hello.version))
            throw ValidationError.invalidHelloVersion(expected: GossipV1.GOSSIP_VERSION, actual: hello.version)
        }

        guard (1...GossipV1.MAX_WANT_ITEMS).contains(Int(hello.maxWant)) else {
            state = .terminated(reason: .protocolViolation("invalid max_want"))
            throw ValidationError.encounterTerminated
        }
        guard (1...GossipV1.MAX_TRANSFER_ITEMS).contains(Int(hello.maxTransfer)) else {
            state = .terminated(reason: .protocolViolation("invalid max_transfer"))
            throw ValidationError.encounterTerminated
        }

        peerCaps = PeerCaps(maxWant: Int(hello.maxWant), maxTransfer: Int(hello.maxTransfer))
        state = .active
    }

    private func validateOutboundWantAgainstPeer(_ want: [GossipV1ItemID]) throws -> [GossipV1ItemID] {
        let max = maxOutboundWantItemsAllowed()
        guard want.count <= max else {
            throw ValidationError.wantTooManyItems(max: max, actual: want.count)
        }
        return want
    }

    private func maxInboundWantItemsAllowed() -> Int {
        min(Int(config.localHello.maxWant), GossipV1.MAX_WANT_ITEMS)
    }

    private func maxOutboundWantItemsAllowed() -> Int {
        min(peerCaps?.maxWant ?? GossipV1.MAX_WANT_ITEMS, GossipV1.MAX_WANT_ITEMS)
    }

    private func maxOutboundTransferObjectsAllowed() -> Int {
        min(peerCaps?.maxTransfer ?? GossipV1.MAX_TRANSFER_ITEMS, GossipV1.MAX_TRANSFER_ITEMS)
    }

    private func maxInboundTransferObjectsAllowed() -> Int {
        min(Int(config.localHello.maxTransfer), GossipV1.MAX_TRANSFER_ITEMS)
    }

    private mutating func handleInboundRequest(
        _ request: GossipV1RequestFrame,
        clock: some Clock,
        store: some Store
    ) throws -> GossipV1Frame {
        let maxWant = maxInboundWantItemsAllowed()
        guard request.want.count <= maxWant else {
            throw ValidationError.wantTooManyItems(max: maxWant, actual: request.want.count)
        }

        let nowMs = clock.nowUnixMs()
        let cutoff = nowMsPlusSkewClamped(nowMs)

        let maxObjects = maxOutboundTransferObjectsAllowed()
        var objects: [GossipV1TransferFrame.Object] = []
        objects.reserveCapacity(min(maxObjects, request.want.count))

        var totalBytes = 0
        for itemID in request.want {
            guard objects.count < maxObjects else { break }
            guard let stored = try store.fetch(itemID) else { continue }
            guard cutoff < stored.expiryUnixMs else { continue }

            guard let forwardedHop = Self.forwardingHopCount(storedHopCount: stored.hopCount) else {
                // Must not forward overflowed hop counts.
                continue
            }

            let projectedBytes = totalBytes + stored.envelopeBytes.count
            guard projectedBytes <= GossipV1.MAX_TRANSFER_BYTES else { break }

            let obj = try GossipV1TransferFrame.Object(
                itemID: itemID,
                envelopeBytes: stored.envelopeBytes,
                expiryUnixMs: stored.expiryUnixMs,
                hopCount: forwardedHop
            )
            objects.append(obj)
            totalBytes = projectedBytes
        }

        return try buildTransfer(objects: objects)
    }

    private mutating func handleInboundTransfer(
        _ transfer: GossipV1TransferFrame,
        clock: some Clock,
        store: some Store
    ) throws -> [GossipV1ItemID] {
        let maxObjects = maxInboundTransferObjectsAllowed()
        guard transfer.objects.count <= maxObjects else {
            throw ValidationError.transferTooManyObjects(max: maxObjects, actual: transfer.objects.count)
        }

        var totalBytes = 0
        for obj in transfer.objects {
            totalBytes += obj.envelopeBytes.count
            if totalBytes > GossipV1.MAX_TRANSFER_BYTES {
                throw ValidationError.transferOversize(maxBytes: GossipV1.MAX_TRANSFER_BYTES, actualBytes: totalBytes)
            }
        }

        let nowMs = clock.nowUnixMs()
        let cutoff = nowMsPlusSkewClamped(nowMs)

        // Validate all objects first to avoid partial ingest on deterministic violations.
        for obj in transfer.objects {
            if cutoff >= obj.expiryUnixMs {
                throw ValidationError.transferExpired(nowUnixMs: nowMs, expiryUnixMs: obj.expiryUnixMs)
            }
            if let existing = try store.existingHopCount(obj.itemID), obj.hopCount < existing {
                throw ValidationError.hopRegression(existing: existing, incoming: obj.hopCount)
            }
        }

        var accepted: [GossipV1ItemID] = []
        accepted.reserveCapacity(transfer.objects.count)
        for obj in transfer.objects {
            try store.ingest(obj.itemID, envelopeBytes: obj.envelopeBytes, expiryUnixMs: obj.expiryUnixMs, hopCount: obj.hopCount)
            accepted.append(obj.itemID)
        }

        lastValidInboundTransferIDs = Set(transfer.objects.map { $0.itemID })
        return accepted
    }

    private mutating func buildReceiptForLastInboundTransfer(received: [GossipV1ItemID]) throws -> GossipV1Frame {
        guard let lastInbound = lastValidInboundTransferIDs else {
            throw ValidationError.receiptWithoutPrecedingTransfer
        }
        let receivedSet = Set(received)
        guard receivedSet.isSubset(of: lastInbound) else {
            throw ValidationError.receiptNotSubsetOfLastTransfer
        }
        let receipt = try GossipV1ReceiptFrame(received: received)
        // Enforce immediately-preceding semantics.
        lastValidInboundTransferIDs = nil
        return .receipt(receipt)
    }

    private mutating func handleInboundReceipt(_ receipt: GossipV1ReceiptFrame) throws {
        guard let lastOutbound = lastValidOutboundTransferIDs else {
            throw ValidationError.receiptWithoutPrecedingTransfer
        }
        let receivedSet = Set(receipt.received)
        guard receivedSet.isSubset(of: lastOutbound) else {
            throw ValidationError.receiptNotSubsetOfLastTransfer
        }
        // Enforce immediately-preceding semantics.
        lastValidOutboundTransferIDs = nil
    }

    private func nowMsPlusSkewClamped(_ nowMs: UInt64) -> UInt64 {
        let skew = GossipV1.CLOCK_SKEW_TOLERANCE_MS
        if nowMs > UInt64.max - skew { return UInt64.max }
        return nowMs + skew
    }
}
