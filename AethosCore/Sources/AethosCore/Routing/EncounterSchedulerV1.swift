import Foundation

public struct EncounterScoreWeights: Equatable, Sendable {
    public let scarcity: Int
    public let safety: Int
    public let expiry: Int
    public let stagnation: Int
    public let proximity: Int
    public let size: Int
    public let intent: Int
    public let contentClass: Int

    public init(
        scarcity: Int,
        safety: Int,
        expiry: Int,
        stagnation: Int,
        proximity: Int,
        size: Int,
        intent: Int,
        contentClass: Int
    ) {
        self.scarcity = scarcity
        self.safety = safety
        self.expiry = expiry
        self.stagnation = stagnation
        self.proximity = proximity
        self.size = size
        self.intent = intent
        self.contentClass = contentClass
    }

    public static let canonicalV1 = EncounterScoreWeights(
        scarcity: 26,
        safety: 22,
        expiry: 16,
        stagnation: 12,
        proximity: 10,
        size: 8,
        intent: 4,
        contentClass: 2
    )
}

public enum EncounterTieBreakReason: String, Equatable, Sendable {
    case none
    case sizeBytes
    case expiryAtUnixMs
    case knownReplicaCount
    case lastForwardedAtUnixMs
    case destinationRank
    case itemID
}

public enum EncounterSelectionReason: String, Equatable, Sendable {
    case selectedPrefix = "selected-prefix"
}

public enum EncounterSelectionStopReason: String, Equatable, Sendable {
    case completed
    case budgetItemsExhausted = "budget-items-exhausted"
    case budgetBytesExhausted = "budget-bytes-exhausted"
    case encounterTimeExhausted = "encounter-time-exhausted"
    case durableRatioCapReached = "durable-ratio-cap-reached"
    case noEligibleItems = "no-eligible-items"
}

public struct EncounterScoreBreakdown: Equatable, Sendable {
    public struct Components: Equatable, Sendable {
        public let scarcity: Double
        public let safety: Double
        public let expiry: Double
        public let stagnation: Double
        public let proximity: Double
        public let size: Double
        public let intent: Double
        public let contentClass: Double

        public init(
            scarcity: Double,
            safety: Double,
            expiry: Double,
            stagnation: Double,
            proximity: Double,
            size: Double,
            intent: Double,
            contentClass: Double
        ) {
            self.scarcity = scarcity
            self.safety = safety
            self.expiry = expiry
            self.stagnation = stagnation
            self.proximity = proximity
            self.size = size
            self.intent = intent
            self.contentClass = contentClass
        }
    }

    public let itemID: String
    public let components: Components
    public let scoreNumerator: Int
    public let score: Double

    public init(itemID: String, components: Components, scoreNumerator: Int, score: Double) {
        self.itemID = itemID
        self.components = components
        self.scoreNumerator = scoreNumerator
        self.score = score
    }
}

public struct RankedCargoItem: Equatable, Sendable {
    public let cargoItem: EncounterSchedulerV1.CargoItem
    public let scoreBreakdown: EncounterScoreBreakdown
    public let tieBreakReason: EncounterTieBreakReason
    public let selectionReason: EncounterSelectionReason?

    public init(
        cargoItem: EncounterSchedulerV1.CargoItem,
        scoreBreakdown: EncounterScoreBreakdown,
        tieBreakReason: EncounterTieBreakReason,
        selectionReason: EncounterSelectionReason?
    ) {
        self.cargoItem = cargoItem
        self.scoreBreakdown = scoreBreakdown
        self.tieBreakReason = tieBreakReason
        self.selectionReason = selectionReason
    }
}

public struct EncounterSchedulerV1: Sendable {
    public enum SchedulerError: Swift.Error, Equatable, Sendable {
        case invalidBudgetMaxItems(Int)
        case invalidBudgetMaxBytes(Int)
        case invalidBudgetMaxDurationMs(Int)
        case invalidBudgetPreferredTransferUnitBytes(Int)
        case invalidBudgetTargetReplicaCountDefault(Int)
        case invalidTier(itemID: String, value: Int)
        case invalidSizeBytes(itemID: String, value: Int)
        case invalidDestinationRank(itemID: String, value: Int)
        case invalidKnownReplicaCount(itemID: String, value: Int)
        case invalidTargetReplicaCount(itemID: String, value: Int)
        case invalidEstimatedDurationMs(itemID: String, value: Int)
        case invalidItemID(String)
        case duplicateItemID(String)
    }

    public enum ProximityClass: String, Codable, Equatable, Sendable {
        case destinationPeer = "destination-peer"
        case likelyCloser = "likely-closer"
        case other
    }

    public struct BudgetProfile: Equatable, Sendable {
        public let maxItems: Int
        public let maxBytes: Int
        public let maxDurationMs: Int?
        public let durableCargoRatioCap: Double?
        public let preferredTransferUnitBytes: Int
        public let expiryUrgencyHorizonMs: UInt64
        public let stagnationHorizonMs: UInt64
        public let targetReplicaCountDefault: Int

        public init(
            maxItems: Int,
            maxBytes: Int,
            maxDurationMs: Int? = nil,
            durableCargoRatioCap: Double? = nil,
            preferredTransferUnitBytes: Int = 32_768,
            expiryUrgencyHorizonMs: UInt64 = 900_000,
            stagnationHorizonMs: UInt64 = 3_600_000,
            targetReplicaCountDefault: Int = 6
        ) {
            self.maxItems = maxItems
            self.maxBytes = maxBytes
            self.maxDurationMs = maxDurationMs
            self.durableCargoRatioCap = durableCargoRatioCap
            self.preferredTransferUnitBytes = preferredTransferUnitBytes
            self.expiryUrgencyHorizonMs = expiryUrgencyHorizonMs
            self.stagnationHorizonMs = stagnationHorizonMs
            self.targetReplicaCountDefault = targetReplicaCountDefault
        }
    }

    public struct CargoItem: Equatable, Sendable {
        public let itemID: String
        public let tier: Int
        public let sizeBytes: Int
        public let expiryAtUnixMs: UInt64
        public let knownReplicaCount: Int?
        public let targetReplicaCount: Int?
        public let durablyStored: Bool?
        public let relayIngested: Bool?
        public let receiptCoverage: Double?
        public let lastForwardedAtUnixMs: UInt64?
        public let proximityClass: ProximityClass?
        public let explicitUserInitiated: Bool?
        public let contentClassScore: Double?
        public let destinationRank: Int
        public let estimatedDurationMs: Int?

        public init(
            itemID: String,
            tier: Int,
            sizeBytes: Int,
            expiryAtUnixMs: UInt64,
            knownReplicaCount: Int? = nil,
            targetReplicaCount: Int? = nil,
            durablyStored: Bool? = nil,
            relayIngested: Bool? = nil,
            receiptCoverage: Double? = nil,
            lastForwardedAtUnixMs: UInt64? = nil,
            proximityClass: ProximityClass? = nil,
            explicitUserInitiated: Bool? = nil,
            contentClassScore: Double? = nil,
            destinationRank: Int,
            estimatedDurationMs: Int? = nil
        ) {
            self.itemID = itemID
            self.tier = tier
            self.sizeBytes = sizeBytes
            self.expiryAtUnixMs = expiryAtUnixMs
            self.knownReplicaCount = knownReplicaCount
            self.targetReplicaCount = targetReplicaCount
            self.durablyStored = durablyStored
            self.relayIngested = relayIngested
            self.receiptCoverage = receiptCoverage
            self.lastForwardedAtUnixMs = lastForwardedAtUnixMs
            self.proximityClass = proximityClass
            self.explicitUserInitiated = explicitUserInitiated
            self.contentClassScore = contentClassScore
            self.destinationRank = destinationRank
            self.estimatedDurationMs = estimatedDurationMs
        }
    }

    public struct Result: Equatable, Sendable {
        public let rankedItems: [RankedCargoItem]
        public let selectedPrefix: [RankedCargoItem]
        public let scoreBreakdowns: [EncounterScoreBreakdown]
        public let stopReason: EncounterSelectionStopReason
        public let tieBreakReason: EncounterTieBreakReason

        public var rankingOrder: [String] {
            rankedItems.map(\.cargoItem.itemID)
        }

        public var selectedPrefixItemIDs: [String] {
            selectedPrefix.map(\.cargoItem.itemID)
        }

        public init(
            rankedItems: [RankedCargoItem],
            selectedPrefix: [RankedCargoItem],
            scoreBreakdowns: [EncounterScoreBreakdown],
            stopReason: EncounterSelectionStopReason,
            tieBreakReason: EncounterTieBreakReason
        ) {
            self.rankedItems = rankedItems
            self.selectedPrefix = selectedPrefix
            self.scoreBreakdowns = scoreBreakdowns
            self.stopReason = stopReason
            self.tieBreakReason = tieBreakReason
        }
    }

    private struct ScoredItem: Equatable, Sendable {
        let cargoItem: CargoItem
        let knownReplicaCount: Int
        let lastForwardedAtUnixMs: UInt64
        let scoreBreakdown: EncounterScoreBreakdown
    }

    private let scoreWeights: EncounterScoreWeights
    private let clockSkewToleranceMs: UInt64

    public init(
        scoreWeights: EncounterScoreWeights = .canonicalV1,
        clockSkewToleranceMs: UInt64 = 30_000
    ) {
        self.scoreWeights = scoreWeights
        self.clockSkewToleranceMs = clockSkewToleranceMs
    }

    public func schedule(
        encounterClass _: EncounterClass,
        budget: BudgetProfile,
        nowUnixMs: UInt64,
        cargoItems: [CargoItem]
    ) throws -> Result {
        try validateBudget(budget)
        let validated = try validateAndFilterEligible(cargoItems: cargoItems, budget: budget, nowUnixMs: nowUnixMs)

        guard !validated.isEmpty else {
            return Result(
                rankedItems: [],
                selectedPrefix: [],
                scoreBreakdowns: [],
                stopReason: .noEligibleItems,
                tieBreakReason: .none
            )
        }

        let scored = validated.map { item in
            score(item: item, budget: budget, nowUnixMs: nowUnixMs)
        }
        let rankedScored = scored.sorted(by: ranksBefore(_:_:))

        var rankedItems: [RankedCargoItem] = []
        rankedItems.reserveCapacity(rankedScored.count)

        var globalTieBreakReason: EncounterTieBreakReason = .none
        for index in rankedScored.indices {
            let tieReason: EncounterTieBreakReason
            if index == rankedScored.startIndex {
                tieReason = .none
            } else {
                tieReason = tieBreakReasonBetween(previous: rankedScored[index - 1], current: rankedScored[index])
            }

            if globalTieBreakReason == .none, tieReason != .none {
                globalTieBreakReason = tieReason
            }

            rankedItems.append(RankedCargoItem(
                cargoItem: rankedScored[index].cargoItem,
                scoreBreakdown: rankedScored[index].scoreBreakdown,
                tieBreakReason: tieReason,
                selectionReason: nil
            ))
        }

        var selectedIndices: [Int] = []
        selectedIndices.reserveCapacity(min(rankedItems.count, budget.maxItems))

        var selectedTotalBytes = 0
        var selectedDurableCargoBytes = 0
        var selectedDurationMs = 0

        let durableCargoRatioCap = budget.durableCargoRatioCap.map { clamp01($0) }
        var stopReason: EncounterSelectionStopReason = .completed

        for (index, rankedItem) in rankedItems.enumerated() {
            if selectedIndices.count >= budget.maxItems {
                stopReason = .budgetItemsExhausted
                break
            }

            let candidate = rankedItem.cargoItem
            let projectedTotalBytes = selectedTotalBytes + candidate.sizeBytes
            if projectedTotalBytes > budget.maxBytes {
                stopReason = .budgetBytesExhausted
                break
            }

            if let maxDurationMs = budget.maxDurationMs {
                let projectedDurationMs = selectedDurationMs + (candidate.estimatedDurationMs ?? 0)
                if projectedDurationMs > maxDurationMs {
                    stopReason = .encounterTimeExhausted
                    break
                }
            }

            if let durableCargoRatioCap {
                let projectedDurableCargoBytes = selectedDurableCargoBytes + (isDurableCargoTier(candidate.tier) ? candidate.sizeBytes : 0)
                let projectedDurableCargoRatio: Double
                if projectedTotalBytes > 0 {
                    projectedDurableCargoRatio = Double(projectedDurableCargoBytes) / Double(projectedTotalBytes)
                } else {
                    projectedDurableCargoRatio = 0
                }

                if projectedDurableCargoRatio > durableCargoRatioCap {
                    stopReason = .durableRatioCapReached
                    break
                }
            }

            selectedIndices.append(index)
            selectedTotalBytes = projectedTotalBytes
            selectedDurationMs += (candidate.estimatedDurationMs ?? 0)
            if isDurableCargoTier(candidate.tier) {
                selectedDurableCargoBytes += candidate.sizeBytes
            }
        }

        let selectedIndexSet = Set(selectedIndices)
        let rankedWithSelection = rankedItems.enumerated().map { index, rankedItem in
            guard selectedIndexSet.contains(index) else { return rankedItem }
            return RankedCargoItem(
                cargoItem: rankedItem.cargoItem,
                scoreBreakdown: rankedItem.scoreBreakdown,
                tieBreakReason: rankedItem.tieBreakReason,
                selectionReason: .selectedPrefix
            )
        }

        let selectedPrefix = selectedIndices.map { rankedWithSelection[$0] }

        return Result(
            rankedItems: rankedWithSelection,
            selectedPrefix: selectedPrefix,
            scoreBreakdowns: rankedWithSelection.map(\.scoreBreakdown),
            stopReason: stopReason,
            tieBreakReason: globalTieBreakReason
        )
    }

    private func validateBudget(_ budget: BudgetProfile) throws {
        guard budget.maxItems >= 0 else {
            throw SchedulerError.invalidBudgetMaxItems(budget.maxItems)
        }
        guard budget.maxBytes >= 0 else {
            throw SchedulerError.invalidBudgetMaxBytes(budget.maxBytes)
        }
        if let maxDurationMs = budget.maxDurationMs, maxDurationMs < 0 {
            throw SchedulerError.invalidBudgetMaxDurationMs(maxDurationMs)
        }
        guard budget.preferredTransferUnitBytes >= 1 else {
            throw SchedulerError.invalidBudgetPreferredTransferUnitBytes(budget.preferredTransferUnitBytes)
        }
        guard budget.targetReplicaCountDefault >= 1 else {
            throw SchedulerError.invalidBudgetTargetReplicaCountDefault(budget.targetReplicaCountDefault)
        }
    }

    private func validateAndFilterEligible(cargoItems: [CargoItem], budget: BudgetProfile, nowUnixMs: UInt64) throws -> [CargoItem] {
        var seenItemIDs: Set<String> = []
        seenItemIDs.reserveCapacity(cargoItems.count)

        let expiryThreshold = saturatedAdd(nowUnixMs, clockSkewToleranceMs)

        return try cargoItems.compactMap { item in
            guard Self.isValidItemID(item.itemID) else {
                throw SchedulerError.invalidItemID(item.itemID)
            }
            guard seenItemIDs.insert(item.itemID).inserted else {
                throw SchedulerError.duplicateItemID(item.itemID)
            }

            guard (0...5).contains(item.tier) else {
                throw SchedulerError.invalidTier(itemID: item.itemID, value: item.tier)
            }
            guard item.sizeBytes >= 1 else {
                throw SchedulerError.invalidSizeBytes(itemID: item.itemID, value: item.sizeBytes)
            }
            guard item.destinationRank >= 0 else {
                throw SchedulerError.invalidDestinationRank(itemID: item.itemID, value: item.destinationRank)
            }
            if let knownReplicaCount = item.knownReplicaCount, knownReplicaCount < 0 {
                throw SchedulerError.invalidKnownReplicaCount(itemID: item.itemID, value: knownReplicaCount)
            }
            if let targetReplicaCount = item.targetReplicaCount, targetReplicaCount < 1 {
                throw SchedulerError.invalidTargetReplicaCount(itemID: item.itemID, value: targetReplicaCount)
            }
            if let estimatedDurationMs = item.estimatedDurationMs, estimatedDurationMs < 0 {
                throw SchedulerError.invalidEstimatedDurationMs(itemID: item.itemID, value: estimatedDurationMs)
            }

            let _ = max(1, item.targetReplicaCount ?? budget.targetReplicaCountDefault)

            guard expiryThreshold < item.expiryAtUnixMs else {
                return nil
            }
            return item
        }
    }

    private func score(item: CargoItem, budget: BudgetProfile, nowUnixMs: UInt64) -> ScoredItem {
        let knownReplicaCount = item.knownReplicaCount ?? 0
        let targetReplicaCount = max(1, item.targetReplicaCount ?? budget.targetReplicaCountDefault)
        let durablyStored = item.durablyStored ?? false
        let relayIngested = item.relayIngested ?? false
        let receiptCoverage = clamp01(item.receiptCoverage ?? 0)
        let lastForwardedAtUnixMs = item.lastForwardedAtUnixMs ?? 0
        let proximityClass = item.proximityClass ?? .other
        let explicitUserInitiated = item.explicitUserInitiated ?? false
        let contentClassScore = clamp01(item.contentClassScore ?? 0)

        let scarcityRaw = clamp01(1 - min(Double(knownReplicaCount) / Double(targetReplicaCount), 1))
        let durableRisk = durablyStored ? 0.0 : 1.0
        let relayRisk = relayIngested ? 0.0 : 1.0
        let receiptRisk = 1 - receiptCoverage
        let safetyRaw = clamp01(durableRisk * 0.45 + relayRisk * 0.35 + receiptRisk * 0.20)

        let ttlMs = max(intDifference(item.expiryAtUnixMs, nowUnixMs), 0)
        let expiryRaw = clamp01(1 - min(Double(ttlMs) / Double(max(1, budget.expiryUrgencyHorizonMs)), 1))

        let idleMs = max(intDifference(nowUnixMs, lastForwardedAtUnixMs), 0)
        let stagnationRaw = clamp01(min(Double(idleMs) / Double(max(1, budget.stagnationHorizonMs)), 1))

        let proximityRaw: Double
        switch proximityClass {
        case .destinationPeer:
            proximityRaw = 1.0
        case .likelyCloser:
            proximityRaw = 0.6
        case .other:
            proximityRaw = 0.0
        }

        let sizeDenominator = log1p(Double(max(1, budget.preferredTransferUnitBytes)))
        let sizeRaw: Double
        if sizeDenominator == 0 {
            sizeRaw = 0
        } else {
            let sizeRatio = log1p(Double(item.sizeBytes)) / sizeDenominator
            sizeRaw = clamp01(1 - min(sizeRatio, 1))
        }

        let intentRaw = explicitUserInitiated ? 1.0 : 0.0

        let scarcityU = quantizeMillionths(scarcityRaw)
        let safetyU = quantizeMillionths(safetyRaw)
        let expiryU = quantizeMillionths(expiryRaw)
        let stagnationU = quantizeMillionths(stagnationRaw)
        let proximityU = quantizeMillionths(proximityRaw)
        let sizeU = quantizeMillionths(sizeRaw)
        let intentU = quantizeMillionths(intentRaw)
        let contentClassU = quantizeMillionths(contentClassScore)

        let scoreNumerator =
            (scarcityU * scoreWeights.scarcity)
            + (safetyU * scoreWeights.safety)
            + (expiryU * scoreWeights.expiry)
            + (stagnationU * scoreWeights.stagnation)
            + (proximityU * scoreWeights.proximity)
            + (sizeU * scoreWeights.size)
            + (intentU * scoreWeights.intent)
            + (contentClassU * scoreWeights.contentClass)

        let breakdown = EncounterScoreBreakdown(
            itemID: item.itemID,
            components: EncounterScoreBreakdown.Components(
                scarcity: fromMillionths(scarcityU),
                safety: fromMillionths(safetyU),
                expiry: fromMillionths(expiryU),
                stagnation: fromMillionths(stagnationU),
                proximity: fromMillionths(proximityU),
                size: fromMillionths(sizeU),
                intent: fromMillionths(intentU),
                contentClass: fromMillionths(contentClassU)
            ),
            scoreNumerator: scoreNumerator,
            score: fromScoreNumerator(scoreNumerator)
        )

        return ScoredItem(
            cargoItem: item,
            knownReplicaCount: knownReplicaCount,
            lastForwardedAtUnixMs: lastForwardedAtUnixMs,
            scoreBreakdown: breakdown
        )
    }

    private func ranksBefore(_ lhs: ScoredItem, _ rhs: ScoredItem) -> Bool {
        if lhs.cargoItem.tier != rhs.cargoItem.tier {
            return lhs.cargoItem.tier < rhs.cargoItem.tier
        }
        if lhs.scoreBreakdown.scoreNumerator != rhs.scoreBreakdown.scoreNumerator {
            return lhs.scoreBreakdown.scoreNumerator > rhs.scoreBreakdown.scoreNumerator
        }
        if lhs.cargoItem.sizeBytes != rhs.cargoItem.sizeBytes {
            return lhs.cargoItem.sizeBytes < rhs.cargoItem.sizeBytes
        }
        if lhs.cargoItem.expiryAtUnixMs != rhs.cargoItem.expiryAtUnixMs {
            return lhs.cargoItem.expiryAtUnixMs < rhs.cargoItem.expiryAtUnixMs
        }
        if lhs.knownReplicaCount != rhs.knownReplicaCount {
            return lhs.knownReplicaCount < rhs.knownReplicaCount
        }
        if lhs.lastForwardedAtUnixMs != rhs.lastForwardedAtUnixMs {
            return lhs.lastForwardedAtUnixMs < rhs.lastForwardedAtUnixMs
        }
        if lhs.cargoItem.destinationRank != rhs.cargoItem.destinationRank {
            return lhs.cargoItem.destinationRank > rhs.cargoItem.destinationRank
        }
        return lhs.cargoItem.itemID > rhs.cargoItem.itemID
    }

    private func tieBreakReasonBetween(previous: ScoredItem, current: ScoredItem) -> EncounterTieBreakReason {
        guard previous.cargoItem.tier == current.cargoItem.tier else { return .none }
        guard previous.scoreBreakdown.scoreNumerator == current.scoreBreakdown.scoreNumerator else { return .none }

        if previous.cargoItem.sizeBytes != current.cargoItem.sizeBytes {
            return .sizeBytes
        }
        if previous.cargoItem.expiryAtUnixMs != current.cargoItem.expiryAtUnixMs {
            return .expiryAtUnixMs
        }
        if previous.knownReplicaCount != current.knownReplicaCount {
            return .knownReplicaCount
        }
        if previous.lastForwardedAtUnixMs != current.lastForwardedAtUnixMs {
            return .lastForwardedAtUnixMs
        }
        if previous.cargoItem.destinationRank != current.cargoItem.destinationRank {
            return .destinationRank
        }
        if previous.cargoItem.itemID != current.cargoItem.itemID {
            return .itemID
        }
        return .none
    }

    private func isDurableCargoTier(_ tier: Int) -> Bool {
        tier == 4 || tier == 5
    }

    private func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private func intDifference(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        if lhs >= rhs {
            return lhs - rhs
        }
        return 0
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func quantizeMillionths(_ value: Double) -> Int {
        let clamped = clamp01(value)
        let quantized = Int((clamped * 1_000_000).rounded(.toNearestOrEven))
        return min(max(quantized, 0), 1_000_000)
    }

    private func fromMillionths(_ millionths: Int) -> Double {
        Double(millionths) / 1_000_000
    }

    private func fromScoreNumerator(_ scoreNumerator: Int) -> Double {
        Double(scoreNumerator) / 100_000_000
    }

    private static func isValidItemID(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x61...0x66:
                continue
            default:
                return false
            }
        }
        return true
    }
}
