import Foundation

public final class Router {
    public enum RouterError: Swift.Error, Equatable {
        case invalidCanonicalType
        case missingChunkBytes(id: Data)
    }

    private struct PendingTransfer {
        let manifestId: Data
        let enqueuedAt: Date
        var manifestBytes: Data?
        var envelopeBytes: Data?
        var envelopeDestination: Data?
        var chunkOrder: [Data]
        var nextChunkIndex: Int
    }

    private struct EncounterCandidate {
        let itemId: Data
        let item: CargoItem
        let tier: EncounterTier
        let enqueuedAt: Date
        let expiresAt: Date?
        let destinationRelevant: Bool
        let transitForwardingCandidate: Bool
        let resumeCapable: Bool
    }

    private let store: AethosStore

    public init(store: AethosStore) {
        self.store = store
    }

    public func planNextSession(budget: SessionBudget, now: Date) throws -> [CargoItem] {
        let context = EncounterSchedulingContext(
            budget: EncounterBudgetProfile(maxBytes: budget.maxBytes, maxItems: budget.maxItems)
        )
        return try planNextEncounter(context: context, now: now).items
    }

    public func planNextEncounter(context: EncounterSchedulingContext, now: Date) throws -> EncounterPlan {
        let outbox = try store.peekQueuedOutbox(limit: 10_000)
        let activeOutbox = outbox.filter { $0.expiresAt.map { $0 > now } ?? true }
        let encounterClass = classifyEncounter(context: context)

        var candidates: [EncounterCandidate] = []
        candidates.reserveCapacity(activeOutbox.count * 2)

        for item in activeOutbox where item.kind == .receipt {
            candidates.append(makeCandidate(from: item, as: .receipt, tier: .tier0Control, context: context))
        }
        for item in activeOutbox where item.kind == .inventoryRequest {
            candidates.append(makeCandidate(from: item, as: .inventoryRequest, tier: .tier0Control, context: context))
        }

        for item in activeOutbox where item.kind == .inventory {
            candidates.append(makeCandidate(from: item, as: .inventory, tier: .tier3Metadata, context: context))
        }

        for item in activeOutbox where item.kind == .message {
            let tier: EncounterTier = classifyMessageTier(item: item, context: context, now: now)
            candidates.append(makeCandidate(from: item, as: .message, tier: tier, context: context))
        }

        let transferCandidates = try buildTransferCandidates(from: activeOutbox, now: now, context: context)
        candidates.append(contentsOf: transferCandidates)

        return buildPlan(
            candidates: candidates,
            encounterClass: encounterClass,
            context: context,
            now: now
        )
    }

    private func chunkRotationOffset(nowMs: Int64, manifestId: Data, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let seed = Int((nowMs % Int64(Int.max)) + Int64(manifestId.first ?? 0))
        let m = seed % count
        return m >= 0 ? m : (m + count)
    }

    private func rotate(_ items: [Data], by offset: Int) -> [Data] {
        guard !items.isEmpty else { return [] }
        let o = offset % items.count
        if o == 0 { return items }
        return Array(items[o...]) + Array(items[..<o])
    }

    private func classifyEncounter(context: EncounterSchedulingContext) -> EncounterClass {
        guard let estimatedDurationSeconds = context.budget.estimatedDurationSeconds else {
            return .short
        }
        if estimatedDurationSeconds <= 12 { return .blink }
        if estimatedDurationSeconds <= 90 { return .short }
        return .durable
    }

    private func classifyMessageTier(item: OutboxItem, context: EncounterSchedulingContext, now: Date) -> EncounterTier {
        guard item.payload.count <= 1024 else { return .tier4BodyAndSmallAttachment }
        let isUrgent = expiryUrgency(expiresAt: item.expiresAt, now: now) >= 0.8
        if isUrgent { return .tier1TinyEndangeredDestination }
        return .tier4BodyAndSmallAttachment
    }

    private func makeCandidate(
        from item: OutboxItem,
        as cargoItem: CargoItem,
        tier: EncounterTier,
        context: EncounterSchedulingContext,
        destinationOverride: Data? = nil,
        resumeCapable: Bool = false
    ) -> EncounterCandidate {
        let destination = destinationOverride
        let destinationRelevant = isDestinationRelevant(destination: destination, context: context)
        let transitForwardingCandidate = isTransitForwardingCandidate(destination: destination, context: context)
        return EncounterCandidate(
            itemId: item.id,
            item: cargoItem,
            tier: tier,
            enqueuedAt: item.enqueuedAt,
            expiresAt: item.expiresAt,
            destinationRelevant: destinationRelevant,
            transitForwardingCandidate: transitForwardingCandidate,
            resumeCapable: resumeCapable
        )
    }

    private func buildTransferCandidates(
        from activeOutbox: [OutboxItem],
        now: Date,
        context: EncounterSchedulingContext
    ) throws -> [EncounterCandidate] {
        var candidates: [EncounterCandidate] = []
        var transfers: [Data: PendingTransfer] = [:]
        var manifestOutboxItemByManifestId: [Data: OutboxItem] = [:]
        var envelopeOutboxItemByManifestId: [Data: OutboxItem] = [:]

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        for item in activeOutbox where item.kind == .manifest {
            let manifestId = AethosIDs.manifestId(canonicalBytes: item.payload)
            let parsed = try CanonicalParserV1.parseManifest(canonical: item.payload)
            let rotation = chunkRotationOffset(nowMs: nowMs, manifestId: manifestId, count: parsed.chunkIds.count)
            let chunkOrder = rotate(parsed.chunkIds, by: rotation)
            transfers[manifestId] = PendingTransfer(
                manifestId: manifestId,
                enqueuedAt: item.enqueuedAt,
                manifestBytes: item.payload,
                envelopeBytes: nil,
                envelopeDestination: nil,
                chunkOrder: chunkOrder,
                nextChunkIndex: 0
            )
            manifestOutboxItemByManifestId[manifestId] = item
        }

        for item in activeOutbox where item.kind == .envelope {
            let parsed = try CanonicalParserV1.parseEnvelope(canonical: item.payload)
            let manifestId = parsed.manifestId
            if var existing = transfers[manifestId] {
                if existing.envelopeBytes == nil {
                    existing.envelopeBytes = item.payload
                    existing.envelopeDestination = parsed.toWayfarerId
                }
                transfers[manifestId] = existing
            } else {
                transfers[manifestId] = PendingTransfer(
                    manifestId: manifestId,
                    enqueuedAt: item.enqueuedAt,
                    manifestBytes: nil,
                    envelopeBytes: item.payload,
                    envelopeDestination: parsed.toWayfarerId,
                    chunkOrder: [],
                    nextChunkIndex: 0
                )
            }
            envelopeOutboxItemByManifestId[manifestId] = item
        }

        var orderedTransfers = transfers.values.sorted { lhs, rhs in
            if lhs.enqueuedAt == rhs.enqueuedAt {
                return lhs.manifestId.lexicographicallyPrecedes(rhs.manifestId)
            }
            return lhs.enqueuedAt < rhs.enqueuedAt
        }

        for transfer in orderedTransfers {
            let destination = transfer.envelopeDestination
            if let manifestBytes = transfer.manifestBytes,
               let manifestItem = manifestOutboxItemByManifestId[transfer.manifestId] {
                candidates.append(makeCandidate(
                    from: manifestItem,
                    as: .manifest(manifestBytes),
                    tier: .tier3Metadata,
                    context: context,
                    destinationOverride: destination,
                    resumeCapable: true
                ))
            }
            if let envelopeBytes = transfer.envelopeBytes,
               let envelopeItem = envelopeOutboxItemByManifestId[transfer.manifestId] {
                let envelopeTier: EncounterTier = isTransitForwardingCandidate(destination: destination, context: context)
                    ? .tier2TinyEndangeredTransit
                    : .tier3Metadata
                candidates.append(makeCandidate(
                    from: envelopeItem,
                    as: .envelope(envelopeBytes),
                    tier: envelopeTier,
                    context: context,
                    destinationOverride: destination,
                    resumeCapable: true
                ))
            }
        }

        orderedTransfers = orderedTransfers.filter { !$0.chunkOrder.isEmpty }
        var idx = 0
        while !orderedTransfers.isEmpty {
            if idx >= orderedTransfers.count { idx = 0 }
            var transfer = orderedTransfers[idx]
            if transfer.nextChunkIndex >= transfer.chunkOrder.count {
                orderedTransfers.remove(at: idx)
                continue
            }

            let chunkId = transfer.chunkOrder[transfer.nextChunkIndex]
            guard let chunkBytes = try store.getChunk(id: chunkId) else {
                throw RouterError.missingChunkBytes(id: chunkId)
            }

            candidates.append(EncounterCandidate(
                itemId: chunkId,
                item: .chunk(id: chunkId, bytes: chunkBytes),
                tier: .tier5LargeMediaChunk,
                enqueuedAt: transfer.enqueuedAt,
                expiresAt: nil,
                destinationRelevant: isDestinationRelevant(destination: transfer.envelopeDestination, context: context),
                transitForwardingCandidate: isTransitForwardingCandidate(destination: transfer.envelopeDestination, context: context),
                resumeCapable: true
            ))

            transfer.nextChunkIndex += 1
            orderedTransfers[idx] = transfer
            idx += 1
        }

        return candidates
    }

    private func buildPlan(
        candidates: [EncounterCandidate],
        encounterClass: EncounterClass,
        context: EncounterSchedulingContext,
        now: Date
    ) -> EncounterPlan {
        let countsByTier = EncounterTier.allCases.reduce(into: [EncounterTier: Int]()) { result, tier in
            result[tier] = 0
        }
        var candidateCountsByTier = countsByTier
        for candidate in candidates {
            candidateCountsByTier[candidate.tier, default: 0] += 1
        }

        var selected: [CargoItem] = []
        selected.reserveCapacity(min(context.budget.maxItems, 128))

        var decisionLogs: [EncounterDecisionLog] = []
        decisionLogs.reserveCapacity(min(context.budget.maxItems + 1, 256))

        var usedBytes = 0
        var usedDurableCargoBytes = 0
        var estimatedSecondsUsed: TimeInterval = 0
        let durableRatioCap = durableCargoRatioCap(encounterClass: encounterClass, context: context)
        let durableByteCap = Int(Double(context.budget.maxBytes) * durableRatioCap)
        let estimatedThroughputBytesPerSecond = 48_000.0

        for tier in EncounterTier.allCases.sorted() {
            let tierCandidates = candidates
                .filter { $0.tier == tier }
                .sorted { lhs, rhs in
                    let lhsScore = score(candidate: lhs, now: now, context: context)
                    let rhsScore = score(candidate: rhs, now: now, context: context)
                    if lhsScore.total == rhsScore.total {
                        return lhs.itemId.lexicographicallyPrecedes(rhs.itemId)
                    }
                    return lhsScore.total > rhsScore.total
                }

            for candidate in tierCandidates {
                if selected.count >= context.budget.maxItems {
                    decisionLogs.append(EncounterDecisionLog(
                        encounterClass: encounterClass,
                        selectedBearer: context.selectedBearer,
                        estimatedTimeBudgetSeconds: context.budget.estimatedDurationSeconds,
                        estimatedByteBudget: context.budget.maxBytes,
                        candidateCountsByTier: candidateCountsByTier,
                        chosenItemIdHex: nil,
                        scoreBreakdown: nil,
                        stopReason: .maxItemsReached,
                        interruptionMarker: .interruptionDetected
                    ))
                    return EncounterPlan(encounterClass: encounterClass, items: selected, decisionLogs: decisionLogs)
                }

                let itemBytes = candidate.item.sizeBytes
                let projectedSecondsUsed = estimatedSecondsUsed + (Double(itemBytes) / estimatedThroughputBytesPerSecond)
                if let timeBudget = context.budget.estimatedDurationSeconds,
                   projectedSecondsUsed > timeBudget {
                    decisionLogs.append(EncounterDecisionLog(
                        encounterClass: encounterClass,
                        selectedBearer: context.selectedBearer,
                        estimatedTimeBudgetSeconds: context.budget.estimatedDurationSeconds,
                        estimatedByteBudget: context.budget.maxBytes,
                        candidateCountsByTier: candidateCountsByTier,
                        chosenItemIdHex: nil,
                        scoreBreakdown: nil,
                        stopReason: .estimatedTimeBudgetReached,
                        interruptionMarker: .interruptionDetected
                    ))
                    return EncounterPlan(encounterClass: encounterClass, items: selected, decisionLogs: decisionLogs)
                }
                if usedBytes + itemBytes > context.budget.maxBytes {
                    decisionLogs.append(EncounterDecisionLog(
                        encounterClass: encounterClass,
                        selectedBearer: context.selectedBearer,
                        estimatedTimeBudgetSeconds: context.budget.estimatedDurationSeconds,
                        estimatedByteBudget: context.budget.maxBytes,
                        candidateCountsByTier: candidateCountsByTier,
                        chosenItemIdHex: nil,
                        scoreBreakdown: nil,
                        stopReason: .maxBytesReached,
                        interruptionMarker: .interruptionDetected
                    ))
                    return EncounterPlan(encounterClass: encounterClass, items: selected, decisionLogs: decisionLogs)
                }

                let isDurableCargoTier = candidate.tier == .tier4BodyAndSmallAttachment || candidate.tier == .tier5LargeMediaChunk
                if isDurableCargoTier && usedDurableCargoBytes + itemBytes > durableByteCap {
                    decisionLogs.append(EncounterDecisionLog(
                        encounterClass: encounterClass,
                        selectedBearer: context.selectedBearer,
                        estimatedTimeBudgetSeconds: context.budget.estimatedDurationSeconds,
                        estimatedByteBudget: context.budget.maxBytes,
                        candidateCountsByTier: candidateCountsByTier,
                        chosenItemIdHex: nil,
                        scoreBreakdown: nil,
                        stopReason: .durableCargoCapReached,
                        interruptionMarker: .interruptionDetected
                    ))
                    continue
                }

                let scoreBreakdown = score(candidate: candidate, now: now, context: context)
                selected.append(candidate.item)
                usedBytes += itemBytes
                estimatedSecondsUsed = projectedSecondsUsed
                if isDurableCargoTier { usedDurableCargoBytes += itemBytes }

                decisionLogs.append(EncounterDecisionLog(
                    encounterClass: encounterClass,
                    selectedBearer: context.selectedBearer,
                    estimatedTimeBudgetSeconds: context.budget.estimatedDurationSeconds,
                    estimatedByteBudget: context.budget.maxBytes,
                    candidateCountsByTier: candidateCountsByTier,
                    chosenItemIdHex: Hex.encode(candidate.itemId),
                    scoreBreakdown: scoreBreakdown,
                    stopReason: nil,
                    interruptionMarker: candidate.resumeCapable ? .resumeReady : .none
                ))
            }
        }

        decisionLogs.append(EncounterDecisionLog(
            encounterClass: encounterClass,
            selectedBearer: context.selectedBearer,
            estimatedTimeBudgetSeconds: context.budget.estimatedDurationSeconds,
            estimatedByteBudget: context.budget.maxBytes,
            candidateCountsByTier: candidateCountsByTier,
            chosenItemIdHex: nil,
            scoreBreakdown: nil,
            stopReason: .completedCandidates,
            interruptionMarker: .none
        ))

        return EncounterPlan(encounterClass: encounterClass, items: selected, decisionLogs: decisionLogs)
    }

    private func score(
        candidate: EncounterCandidate,
        now: Date,
        context: EncounterSchedulingContext
    ) -> EncounterScoreBreakdown {
        let scarcity = replicationScarcity(candidate: candidate)
        let proximity = deliveryProximity(candidate: candidate)
        let urgency = expiryUrgency(expiresAt: candidate.expiresAt, now: now)
        let sizePenalty = sizeCost(sizeBytes: candidate.item.sizeBytes)
        let stagnation = stagnationLackOfProgress(enqueuedAt: candidate.enqueuedAt, now: now)
        let safety = relaySafety(context: context)
        let userIntent = context.userIntentBoostItemIDs.contains(candidate.itemId) ? 1.0 : 0.0
        let contentClass = contentClassWeight(candidate: candidate)

        let total = (scarcity * 2.0)
            + (proximity * 1.8)
            + (urgency * 2.0)
            + (sizePenalty * 1.3)
            + (stagnation * 1.2)
            + (safety * 0.8)
            + (userIntent * 1.6)
            + (contentClass * 1.5)

        return EncounterScoreBreakdown(
            replicationScarcity: scarcity,
            deliveryProximity: proximity,
            expiryUrgency: urgency,
            sizeCost: sizePenalty,
            stagnationLackOfProgress: stagnation,
            relayIngestOrDurableStorageSafety: safety,
            userIntentBoost: userIntent,
            contentClass: contentClass,
            total: total
        )
    }

    private func replicationScarcity(candidate: EncounterCandidate) -> Double {
        switch candidate.tier {
        case .tier0Control:
            return 1.0
        case .tier1TinyEndangeredDestination, .tier2TinyEndangeredTransit:
            return 0.95
        case .tier3Metadata:
            return 0.7
        case .tier4BodyAndSmallAttachment:
            return 0.45
        case .tier5LargeMediaChunk:
            return 0.25
        }
    }

    private func deliveryProximity(candidate: EncounterCandidate) -> Double {
        if candidate.destinationRelevant { return 1.0 }
        if candidate.transitForwardingCandidate { return 0.75 }
        return 0.4
    }

    private func expiryUrgency(expiresAt: Date?, now: Date) -> Double {
        guard let expiresAt else { return 0.25 }
        let secondsLeft = expiresAt.timeIntervalSince(now)
        if secondsLeft <= 0 { return 1.0 }
        if secondsLeft <= 20 { return 1.0 }
        if secondsLeft <= 120 { return 0.85 }
        if secondsLeft <= 600 { return 0.6 }
        return 0.2
    }

    private func sizeCost(sizeBytes: Int) -> Double {
        let normalized = min(max(Double(sizeBytes) / Double(Chunking.chunkSize), 0.0), 1.0)
        return 1.0 - normalized
    }

    private func stagnationLackOfProgress(enqueuedAt: Date, now: Date) -> Double {
        let ageSeconds = max(0, now.timeIntervalSince(enqueuedAt))
        if ageSeconds >= 900 { return 1.0 }
        return min(ageSeconds / 900.0, 1.0)
    }

    private func relaySafety(context: EncounterSchedulingContext) -> Double {
        context.relayIngestSafetyAvailable ? 1.0 : 0.0
    }

    private func contentClassWeight(candidate: EncounterCandidate) -> Double {
        switch candidate.item {
        case .receipt, .inventoryRequest:
            return 1.0
        case .message:
            return 0.95
        case .inventory, .manifest, .envelope:
            return 0.7
        case .chunk:
            return 0.35
        }
    }

    private func durableCargoRatioCap(encounterClass: EncounterClass, context: EncounterSchedulingContext) -> Double {
        if let explicitCap = context.budget.durableCargoRatioCap {
            return min(max(explicitCap, 0.0), 1.0)
        }
        switch encounterClass {
        case .blink:
            return 0.10
        case .short:
            return 0.40
        case .durable:
            return 0.80
        }
    }

    private func isDestinationRelevant(destination: Data?, context: EncounterSchedulingContext) -> Bool {
        guard let remote = context.remoteWayfarerId else { return true }
        guard let destination else { return true }
        return destination == remote
    }

    private func isTransitForwardingCandidate(destination: Data?, context: EncounterSchedulingContext) -> Bool {
        guard let remote = context.remoteWayfarerId else { return false }
        guard let destination else { return false }
        return destination != remote
    }
}

private enum CanonicalParserV1 {
    struct ParsedManifest {
        let chunkIds: [Data]
    }

    struct ParsedEnvelope {
        let toWayfarerId: Data
        let manifestId: Data
    }

    static func parseManifest(canonical: Data) throws -> ParsedManifest {
        let fields = try parseFields(expectedType: CanonicalEncoderV1.TypeDiscriminator.manifest.rawValue, canonical: canonical)
        guard let raw = fields[CanonicalEncoderV1.ManifestField.chunkIds.rawValue] else {
            return ParsedManifest(chunkIds: [])
        }
        return ParsedManifest(chunkIds: try parseArrayOfBytes(raw))
    }

    static func parseEnvelope(canonical: Data) throws -> ParsedEnvelope {
        let fields = try parseFields(expectedType: CanonicalEncoderV1.TypeDiscriminator.envelope.rawValue, canonical: canonical)
        let toWayfarerId = fields[CanonicalEncoderV1.EnvelopeField.toWayfarerId.rawValue] ?? Data()
        guard let raw = fields[CanonicalEncoderV1.EnvelopeField.manifestId.rawValue] else {
            return ParsedEnvelope(toWayfarerId: toWayfarerId, manifestId: Data())
        }
        return ParsedEnvelope(toWayfarerId: toWayfarerId, manifestId: raw)
    }

    private static func parseFields(expectedType: UInt8, canonical: Data) throws -> [UInt8: Data] {
        var r = Reader(canonical)
        guard r.readUInt8() != nil else { throw Router.RouterError.invalidCanonicalType }
        guard let type = r.readUInt8(), type == expectedType else { throw Router.RouterError.invalidCanonicalType }

        var map: [UInt8: Data] = [:]
        while !r.isAtEnd {
            guard let fieldId = r.readUInt8() else { break }
            guard let len = r.readUInt32() else { throw Router.RouterError.invalidCanonicalType }
            guard let bytes = r.readData(count: Int(len)) else { throw Router.RouterError.invalidCanonicalType }
            map[fieldId] = bytes
        }
        return map
    }

    private static func parseArrayOfBytes(_ raw: Data) throws -> [Data] {
        var r = Reader(raw)
        guard let count = r.readUInt32() else { throw Router.RouterError.invalidCanonicalType }
        var out: [Data] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let len = r.readUInt32() else { throw Router.RouterError.invalidCanonicalType }
            guard let bytes = r.readData(count: Int(len)) else { throw Router.RouterError.invalidCanonicalType }
            out.append(bytes)
        }
        return out
    }

    private struct Reader {
        private let data: Data
        private var offset: Int = 0

        init(_ data: Data) {
            self.data = data
        }

        var isAtEnd: Bool { offset >= data.count }

        mutating func readUInt8() -> UInt8? {
            guard offset + 1 <= data.count else { return nil }
            let v = data[offset]
            offset += 1
            return v
        }

        mutating func readUInt32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let slice = data[offset..<offset + 4]
            offset += 4
            // Avoid alignment traps by decoding manually.
            var v: UInt32 = 0
            for b in slice {
                v = (v << 8) | UInt32(b)
            }
            return v
        }

        mutating func readData(count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            let slice = data[offset..<offset + count]
            offset += count
            return Data(slice)
        }
    }
}
