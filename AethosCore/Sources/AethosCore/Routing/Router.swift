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

    private struct ShadowCandidate {
        let canonicalItemIDHex: String
        let legacyItemIDHex: String
        let tier: EncounterTier
        let destinationRelevant: Bool
        let transitForwardingCandidate: Bool
        let schedulerItem: EncounterSchedulerV1.CargoItem
    }

    private let store: AethosStore

    public init(store: AethosStore) {
        self.store = store
    }

    public func planNextSession(budget: SessionBudget, now: Date) throws -> [CargoItem] {
        try planNextSessionLegacy(budget: budget, now: now)
    }

    public func planNextEncounter(context: EncounterSchedulingContext, now: Date) throws -> EncounterPlan {
        let outbox = try store.peekQueuedOutbox(limit: 10_000)
        let activeOutbox = outbox.filter { $0.expiresAt.map { $0 > now } ?? true }
        let encounterClass = classifyEncounter(context: context)

        var candidates: [EncounterCandidate] = []
        candidates.reserveCapacity(activeOutbox.count * 2)

        for item in activeOutbox where item.kind == .receipt {
            candidates.append(makeCandidate(from: item, as: .receipt(item.payload), tier: .tier0Control, context: context))
        }
        for item in activeOutbox where item.kind == .inventoryRequest {
            candidates.append(makeCandidate(from: item, as: .inventoryRequest(item.payload), tier: .tier0Control, context: context))
        }

        for item in activeOutbox where item.kind == .inventory {
            candidates.append(makeCandidate(from: item, as: .inventory(item.payload), tier: .tier3Metadata, context: context))
        }

        for item in activeOutbox where item.kind == .message {
            let tier: EncounterTier = classifyMessageTier(item: item, context: context, now: now)
            candidates.append(makeCandidate(from: item, as: .message(item.payload), tier: tier, context: context))
        }

        let transferCandidates = try buildTransferCandidates(from: activeOutbox, now: now, context: context)
        candidates.append(contentsOf: transferCandidates)

        let legacyPlan = buildPlan(
            candidates: candidates,
            encounterClass: encounterClass,
            context: context,
            now: now
        )

        let shadowComparison = buildShadowComparison(
            mode: context.shadowMode,
            topN: context.shadowTopN,
            candidates: candidates,
            legacyPlan: legacyPlan,
            encounterClass: encounterClass,
            context: context,
            now: now
        )

        return EncounterPlan(
            encounterClass: legacyPlan.encounterClass,
            items: legacyPlan.items,
            decisionLogs: legacyPlan.decisionLogs,
            shadowComparison: shadowComparison
        )
    }

    private func buildShadowComparison(
        mode: EncounterShadowMode,
        topN: Int,
        candidates: [EncounterCandidate],
        legacyPlan: EncounterPlan,
        encounterClass: EncounterClass,
        context: EncounterSchedulingContext,
        now: Date
    ) -> EncounterShadowComparison? {
        guard isShadowComparisonEnabled(mode: mode) else { return nil }

        let selectedLegacyItemIDs = legacyPlan.decisionLogs.compactMap(\.chosenItemIdHex)
        let legacyCandidateByID = candidates.reduce(into: [String: EncounterCandidate]()) { result, candidate in
            result[Hex.encode(candidate.itemId)] = candidate
        }
        let legacyStopReason = normalizedStopReason(legacyPlan: legacyPlan)

        let normalizedTopN = max(topN, 1)
        let legacyTopN = Array(selectedLegacyItemIDs.prefix(normalizedTopN))
        let legacyTierDistribution = tierDistribution(itemIDsHex: selectedLegacyItemIDs, candidatesByID: legacyCandidateByID)
        let legacyTransitDirectBalance = transitDirectBalance(itemIDsHex: selectedLegacyItemIDs, candidatesByID: legacyCandidateByID)

        let nowUnixMs = unixMilliseconds(date: now)
        let canonicalBudget = canonicalBudgetProfile(encounterClass: encounterClass, context: context)
        let shadowCandidates = makeShadowCandidates(candidates: candidates, context: context)
        let canonicalScheduler = EncounterSchedulerV1()

        do {
            let result = try canonicalScheduler.schedule(
                encounterClass: encounterClass,
                budget: canonicalBudget,
                nowUnixMs: nowUnixMs,
                cargoItems: shadowCandidates.map(\.schedulerItem)
            )

            let shadowByCanonicalID = shadowCandidates.reduce(into: [String: ShadowCandidate]()) { result, candidate in
                result[candidate.canonicalItemIDHex] = candidate
            }
            let selectedCanonical = result.selectedPrefix.compactMap { shadowByCanonicalID[$0.cargoItem.itemID] }
            let selectedCanonicalLegacyIDs = selectedCanonical.map(\.legacyItemIDHex)
            let canonicalTopN = Array(selectedCanonicalLegacyIDs.prefix(normalizedTopN))
            let canonicalTierDistribution = tierDistribution(selectedCandidates: selectedCanonical)
            let canonicalTransitDirectBalance = transitDirectBalance(selectedCandidates: selectedCanonical)

            var differences: [EncounterShadowComparison.Difference] = []
            if legacyTopN != canonicalTopN { differences.append(.topNChanged) }
            if selectedLegacyItemIDs.first != selectedCanonicalLegacyIDs.first { differences.append(.firstSelectedChanged) }
            if legacyStopReason != result.stopReason.rawValue { differences.append(.stopReasonChanged) }
            if legacyTierDistribution != canonicalTierDistribution { differences.append(.tierDistributionChanged) }
            if legacyTransitDirectBalance != canonicalTransitDirectBalance { differences.append(.transitDirectBalanceChanged) }

            return EncounterShadowComparison(
                topN: normalizedTopN,
                legacyTopNItemIDsHex: legacyTopN,
                canonicalTopNItemIDsHex: canonicalTopN,
                legacyFirstSelectedItemIDHex: selectedLegacyItemIDs.first,
                canonicalFirstSelectedItemIDHex: selectedCanonicalLegacyIDs.first,
                legacyStopReason: legacyStopReason,
                canonicalStopReason: result.stopReason.rawValue,
                legacyTierDistribution: legacyTierDistribution,
                canonicalTierDistribution: canonicalTierDistribution,
                legacyTransitDirectBalance: legacyTransitDirectBalance,
                canonicalTransitDirectBalance: canonicalTransitDirectBalance,
                schedulerErrorDescription: nil,
                differences: differences
            )
        } catch {
            return EncounterShadowComparison(
                topN: normalizedTopN,
                legacyTopNItemIDsHex: legacyTopN,
                canonicalTopNItemIDsHex: [],
                legacyFirstSelectedItemIDHex: selectedLegacyItemIDs.first,
                canonicalFirstSelectedItemIDHex: nil,
                legacyStopReason: legacyStopReason,
                canonicalStopReason: nil,
                legacyTierDistribution: legacyTierDistribution,
                canonicalTierDistribution: nil,
                legacyTransitDirectBalance: legacyTransitDirectBalance,
                canonicalTransitDirectBalance: nil,
                schedulerErrorDescription: String(describing: error),
                differences: [.schedulerError]
            )
        }
    }

    private func canonicalBudgetProfile(
        encounterClass: EncounterClass,
        context: EncounterSchedulingContext
    ) -> EncounterSchedulerV1.BudgetProfile {
        let maxDurationMs = context.budget.estimatedDurationSeconds.map { seconds -> Int in
            let milliseconds = Int((seconds * 1000).rounded(.toNearestOrEven))
            return max(milliseconds, 0)
        }
        return EncounterSchedulerV1.BudgetProfile(
            maxItems: context.budget.maxItems,
            maxBytes: context.budget.maxBytes,
            maxDurationMs: maxDurationMs,
            durableCargoRatioCap: durableCargoRatioCap(encounterClass: encounterClass, context: context)
        )
    }

    private func isShadowComparisonEnabled(mode: EncounterShadowMode) -> Bool {
        guard mode == .compareCanonicalV1 else { return false }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private func normalizedStopReason(legacyPlan: EncounterPlan) -> String {
        let legacyStop = legacyPlan.decisionLogs.compactMap(\.stopReason).last ?? .completedCandidates
        switch legacyStop {
        case .completedCandidates:
            return EncounterSelectionStopReason.completed.rawValue
        case .maxItemsReached:
            return EncounterSelectionStopReason.budgetItemsExhausted.rawValue
        case .maxBytesReached:
            return EncounterSelectionStopReason.budgetBytesExhausted.rawValue
        case .estimatedTimeBudgetReached:
            return EncounterSelectionStopReason.encounterTimeExhausted.rawValue
        case .durableCargoCapReached:
            return EncounterSelectionStopReason.durableRatioCapReached.rawValue
        }
    }

    private func makeShadowCandidates(
        candidates: [EncounterCandidate],
        context: EncounterSchedulingContext
    ) -> [ShadowCandidate] {
        let throughputBytesPerSecond = 48_000.0
        return candidates.enumerated().map { index, candidate in
            let canonicalItemIDHex = shadowCanonicalItemIDHex(candidate: candidate, index: index)
            let legacyItemIDHex = Hex.encode(candidate.itemId)
            let estimatedDurationMs = Int((Double(candidate.item.sizeBytes) / throughputBytesPerSecond * 1000).rounded(.toNearestOrEven))

            let schedulerItem = EncounterSchedulerV1.CargoItem(
                itemID: canonicalItemIDHex,
                tier: candidate.tier.rawValue,
                sizeBytes: max(1, candidate.item.sizeBytes),
                expiryAtUnixMs: expiryUnixMilliseconds(candidate.expiresAt),
                knownReplicaCount: nil,
                targetReplicaCount: nil,
                durablyStored: context.relayIngestSafetyAvailable,
                relayIngested: context.relayIngestSafetyAvailable,
                receiptCoverage: receiptCoverage(candidate: candidate),
                lastForwardedAtUnixMs: unixMilliseconds(date: candidate.enqueuedAt),
                proximityClass: proximityClass(candidate: candidate),
                explicitUserInitiated: context.userIntentBoostItemIDs.contains(candidate.itemId),
                contentClassScore: contentClassWeight(candidate: candidate),
                destinationRank: destinationRank(candidate: candidate),
                estimatedDurationMs: max(estimatedDurationMs, 0)
            )

            return ShadowCandidate(
                canonicalItemIDHex: canonicalItemIDHex,
                legacyItemIDHex: legacyItemIDHex,
                tier: candidate.tier,
                destinationRelevant: candidate.destinationRelevant,
                transitForwardingCandidate: candidate.transitForwardingCandidate,
                schedulerItem: schedulerItem
            )
        }
    }

    private func tierDistribution(
        itemIDsHex: [String],
        candidatesByID: [String: EncounterCandidate]
    ) -> [Int] {
        var distribution = Array(repeating: 0, count: EncounterTier.allCases.count)
        for itemIDHex in itemIDsHex {
            guard let candidate = candidatesByID[itemIDHex] else { continue }
            distribution[candidate.tier.rawValue] += 1
        }
        return distribution
    }

    private func tierDistribution(selectedCandidates: [ShadowCandidate]) -> [Int] {
        var distribution = Array(repeating: 0, count: EncounterTier.allCases.count)
        for candidate in selectedCandidates {
            distribution[candidate.tier.rawValue] += 1
        }
        return distribution
    }

    private func transitDirectBalance(
        itemIDsHex: [String],
        candidatesByID: [String: EncounterCandidate]
    ) -> EncounterShadowTransitDirectBalance {
        var directCount = 0
        var transitCount = 0
        for itemIDHex in itemIDsHex {
            guard let candidate = candidatesByID[itemIDHex] else { continue }
            if candidate.destinationRelevant { directCount += 1 }
            if candidate.transitForwardingCandidate { transitCount += 1 }
        }
        return EncounterShadowTransitDirectBalance(directCount: directCount, transitCount: transitCount)
    }

    private func transitDirectBalance(selectedCandidates: [ShadowCandidate]) -> EncounterShadowTransitDirectBalance {
        let directCount = selectedCandidates.reduce(into: 0) { result, candidate in
            if candidate.destinationRelevant { result += 1 }
        }
        let transitCount = selectedCandidates.reduce(into: 0) { result, candidate in
            if candidate.transitForwardingCandidate { result += 1 }
        }
        return EncounterShadowTransitDirectBalance(directCount: directCount, transitCount: transitCount)
    }

    private func destinationRank(candidate: EncounterCandidate) -> Int {
        if candidate.destinationRelevant { return 2 }
        if candidate.transitForwardingCandidate { return 1 }
        return 0
    }

    private func proximityClass(candidate: EncounterCandidate) -> EncounterSchedulerV1.ProximityClass {
        if candidate.destinationRelevant { return .destinationPeer }
        if candidate.transitForwardingCandidate { return .likelyCloser }
        return .other
    }

    private func receiptCoverage(candidate: EncounterCandidate) -> Double {
        switch candidate.item {
        case .receipt, .inventoryRequest:
            return 1.0
        default:
            return 0.0
        }
    }

    private func shadowCanonicalItemIDHex(candidate: EncounterCandidate, index: Int) -> String {
        var material = Data("encounter-shadow-v1".utf8)
        material.append(candidate.itemId)
        material.append(UInt8(candidate.tier.rawValue))
        var indexBigEndian = UInt64(index).bigEndian
        withUnsafeBytes(of: &indexBigEndian) { material.append(contentsOf: $0) }
        return Hex.encode(AethosIDs.sha256(material))
    }

    private func unixMilliseconds(date: Date) -> UInt64 {
        let milliseconds = max(0, date.timeIntervalSince1970 * 1000)
        let rounded = milliseconds.rounded(.down)
        if rounded >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(rounded)
    }

    private func expiryUnixMilliseconds(_ date: Date?) -> UInt64 {
        guard let date else { return UInt64.max }
        return unixMilliseconds(date: date)
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
        let isTinyAndEndangered = isTinyAndEndangered(sizeBytes: item.payload.count, expiresAt: item.expiresAt, now: now)
        guard isTinyAndEndangered else { return .tier4BodyAndSmallAttachment }
        if isTransitForwardingCandidate(destination: nil, context: context) {
            return .tier2TinyEndangeredTransit
        }
        if isDestinationRelevant(destination: nil, context: context) {
            return .tier1TinyEndangeredDestination
        }
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
                    && isTinyAndEndangered(sizeBytes: envelopeBytes.count, expiresAt: envelopeItem.expiresAt, now: now)
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
        var finalStopReason: EncounterDecisionLog.StopReason = .completedCandidates

        for tier in EncounterTier.allCases.sorted() {
            let scoredTierCandidates = candidates
                .filter { $0.tier == tier }
                .map { candidate in
                    (candidate: candidate, score: score(candidate: candidate, now: now, context: context))
                }
                .sorted { lhs, rhs in
                    if lhs.score.total == rhs.score.total {
                        return lhs.candidate.itemId.lexicographicallyPrecedes(rhs.candidate.itemId)
                    }
                    return lhs.score.total > rhs.score.total
                }

            for scoredCandidate in scoredTierCandidates {
                let candidate = scoredCandidate.candidate
                if selected.count >= context.budget.maxItems {
                    finalStopReason = .maxItemsReached
                    decisionLogs.append(makeDecisionLog(
                        encounterClass: encounterClass,
                        context: context,
                        candidateCountsByTier: candidateCountsByTier,
                        stopReason: finalStopReason,
                        interruption: .interruptionDetected
                    ))
                    return EncounterPlan(encounterClass: encounterClass, items: selected, decisionLogs: decisionLogs)
                }

                let itemBytes = candidate.item.sizeBytes
                let projectedSecondsUsed = estimatedSecondsUsed + (Double(itemBytes) / estimatedThroughputBytesPerSecond)
                if let timeBudget = context.budget.estimatedDurationSeconds,
                   projectedSecondsUsed > timeBudget {
                    decisionLogs.append(makeDecisionLog(
                        encounterClass: encounterClass,
                        context: context,
                        candidateCountsByTier: candidateCountsByTier,
                        stopReason: .estimatedTimeBudgetReached,
                        interruption: .interruptionDetected
                    ))
                    finalStopReason = .estimatedTimeBudgetReached
                    continue
                }
                if usedBytes + itemBytes > context.budget.maxBytes {
                    decisionLogs.append(makeDecisionLog(
                        encounterClass: encounterClass,
                        context: context,
                        candidateCountsByTier: candidateCountsByTier,
                        stopReason: .maxBytesReached,
                        interruption: .interruptionDetected
                    ))
                    finalStopReason = .maxBytesReached
                    continue
                }

                let isDurableCargoTier = candidate.tier == .tier4BodyAndSmallAttachment || candidate.tier == .tier5LargeMediaChunk
                if isDurableCargoTier && usedDurableCargoBytes + itemBytes > durableByteCap {
                    decisionLogs.append(makeDecisionLog(
                        encounterClass: encounterClass,
                        context: context,
                        candidateCountsByTier: candidateCountsByTier,
                        stopReason: .durableCargoCapReached,
                        interruption: .interruptionDetected
                    ))
                    finalStopReason = .durableCargoCapReached
                    continue
                }

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
                    scoreBreakdown: scoredCandidate.score,
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
            stopReason: finalStopReason,
            interruptionMarker: .none
        ))

        return EncounterPlan(encounterClass: encounterClass, items: selected, decisionLogs: decisionLogs)
    }

    private func score(
        candidate: EncounterCandidate,
        now: Date,
        context: EncounterSchedulingContext
    ) -> EncounterDecisionScoreBreakdown {
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

        return EncounterDecisionScoreBreakdown(
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
        if candidate.transitForwardingCandidate { return 0.6 }
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

    private func isTinyAndEndangered(sizeBytes: Int, expiresAt: Date?, now: Date) -> Bool {
        guard sizeBytes <= 1024 else { return false }
        return expiryUrgency(expiresAt: expiresAt, now: now) >= 0.8
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
        if context.budget.estimatedDurationSeconds == nil {
            return 0.0
        }
        switch encounterClass {
        case .blink:
            return 1.0
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

    private func makeDecisionLog(
        encounterClass: EncounterClass,
        context: EncounterSchedulingContext,
        candidateCountsByTier: [EncounterTier: Int],
        stopReason: EncounterDecisionLog.StopReason,
        interruption: EncounterDecisionLog.InterruptionMarker
    ) -> EncounterDecisionLog {
        EncounterDecisionLog(
            encounterClass: encounterClass,
            selectedBearer: context.selectedBearer,
            estimatedTimeBudgetSeconds: context.budget.estimatedDurationSeconds,
            estimatedByteBudget: context.budget.maxBytes,
            candidateCountsByTier: candidateCountsByTier,
            chosenItemIdHex: nil,
            scoreBreakdown: nil,
            stopReason: stopReason,
            interruptionMarker: interruption
        )
    }

    private func planNextSessionLegacy(budget: SessionBudget, now: Date) throws -> [CargoItem] {
        var plan: [CargoItem] = []
        plan.reserveCapacity(min(budget.maxItems, 64))

        var usedBytes = 0

        func canAdd(_ item: CargoItem) -> Bool {
            if plan.count + 1 > budget.maxItems { return false }
            if usedBytes + item.sizeBytes > budget.maxBytes { return false }
            return true
        }

        func addIfFits(_ item: CargoItem) {
            guard canAdd(item) else { return }
            plan.append(item)
            usedBytes += item.sizeBytes
        }

        let outbox = try store.peekQueuedOutbox(limit: 10_000)
        let activeOutbox = outbox.filter { $0.expiresAt.map { $0 > now } ?? true }

        for item in activeOutbox where item.kind == .receipt {
            let cargo = CargoItem.receipt(item.payload)
            if !canAdd(cargo) { return plan }
            addIfFits(cargo)
        }

        for item in activeOutbox where item.kind == .inventoryRequest {
            let cargo = CargoItem.inventoryRequest(item.payload)
            if !canAdd(cargo) { return plan }
            addIfFits(cargo)
        }

        for item in activeOutbox where item.kind == .inventory {
            let cargo = CargoItem.inventory(item.payload)
            if !canAdd(cargo) { return plan }
            addIfFits(cargo)
        }

        for item in activeOutbox where item.kind == .message {
            let cargo = CargoItem.message(item.payload)
            if !canAdd(cargo) { return plan }
            addIfFits(cargo)
        }

        var transfers: [Data: PendingTransfer] = [:]
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        for item in activeOutbox where item.kind == .manifest {
            let manifestId = AethosIDs.manifestId(canonicalBytes: item.payload)
            let parsed = try CanonicalParserV1.parseManifest(canonical: item.payload)

            let rotation = chunkRotationOffset(nowMs: nowMs, manifestId: manifestId, count: parsed.chunkIds.count)
            let chunkOrder = rotate(parsed.chunkIds, by: rotation)

            let transfer = PendingTransfer(
                manifestId: manifestId,
                enqueuedAt: item.enqueuedAt,
                manifestBytes: item.payload,
                envelopeBytes: nil,
                envelopeDestination: nil,
                chunkOrder: chunkOrder,
                nextChunkIndex: 0
            )
            transfers[manifestId] = transfer
        }

        for item in activeOutbox where item.kind == .envelope {
            let parsed = try CanonicalParserV1.parseEnvelope(canonical: item.payload)
            let manifestId = parsed.manifestId

            if var existing = transfers[manifestId] {
                if existing.envelopeBytes == nil {
                    existing.envelopeBytes = item.payload
                }
                transfers[manifestId] = existing
            } else {
                transfers[manifestId] = PendingTransfer(
                    manifestId: manifestId,
                    enqueuedAt: item.enqueuedAt,
                    manifestBytes: nil,
                    envelopeBytes: item.payload,
                    envelopeDestination: nil,
                    chunkOrder: [],
                    nextChunkIndex: 0
                )
            }
        }

        var orderedTransfers = transfers.values.sorted { $0.enqueuedAt < $1.enqueuedAt }
        for transfer in orderedTransfers {
            if let manifestBytes = transfer.manifestBytes {
                let cargo = CargoItem.manifest(manifestBytes)
                if !canAdd(cargo) { return plan }
                addIfFits(cargo)
            }
            if let envelopeBytes = transfer.envelopeBytes {
                let cargo = CargoItem.envelope(envelopeBytes)
                if !canAdd(cargo) { return plan }
                addIfFits(cargo)
            }
        }

        orderedTransfers = orderedTransfers.filter { !$0.chunkOrder.isEmpty }
        var index = 0
        while !orderedTransfers.isEmpty {
            if plan.count >= budget.maxItems { break }

            if index >= orderedTransfers.count { index = 0 }
            var transfer = orderedTransfers[index]
            if transfer.nextChunkIndex >= transfer.chunkOrder.count {
                orderedTransfers.remove(at: index)
                continue
            }

            let chunkId = transfer.chunkOrder[transfer.nextChunkIndex]
            guard let bytes = try store.getChunk(id: chunkId) else {
                throw RouterError.missingChunkBytes(id: chunkId)
            }

            let cargo = CargoItem.chunk(id: chunkId, bytes: bytes)
            if !canAdd(cargo) { break }
            addIfFits(cargo)

            transfer.nextChunkIndex += 1
            orderedTransfers[index] = transfer
            index += 1
        }

        return plan
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
