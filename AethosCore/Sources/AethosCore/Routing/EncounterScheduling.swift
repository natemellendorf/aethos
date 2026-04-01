import Foundation

public enum EncounterClass: String, Equatable, Sendable {
    case blink
    case short
    case durable
}

public enum EncounterTier: Int, CaseIterable, Comparable, Sendable {
    /// tier 0: control/receipts/checkpoints/resumability
    case tier0Control = 0
    /// tier 1: tiny endangered destination-relevant message items
    case tier1TinyEndangeredDestination = 1
    /// tier 2: tiny endangered transit items not for peer
    case tier2TinyEndangeredTransit = 2
    /// tier 3: manifests/metadata for larger objects
    case tier3Metadata = 3
    /// tier 4: message bodies/small attachments
    case tier4BodyAndSmallAttachment = 4
    /// tier 5: large media chunks
    case tier5LargeMediaChunk = 5

    public static func < (lhs: EncounterTier, rhs: EncounterTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct EncounterBudgetProfile: Equatable, Sendable {
    public let maxBytes: Int
    public let maxItems: Int
    public let estimatedDurationSeconds: TimeInterval?
    public let durableCargoRatioCap: Double?

    public init(
        maxBytes: Int,
        maxItems: Int,
        estimatedDurationSeconds: TimeInterval? = nil,
        durableCargoRatioCap: Double? = nil
    ) {
        self.maxBytes = maxBytes
        self.maxItems = maxItems
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.durableCargoRatioCap = durableCargoRatioCap
    }
}

public struct EncounterSchedulingContext: Equatable, Sendable {
    public let budget: EncounterBudgetProfile
    public let selectedBearer: String
    public let remoteWayfarerId: Data?
    public let userIntentBoostItemIDs: Set<Data>
    public let relayIngestSafetyAvailable: Bool
    public let shadowMode: EncounterShadowMode
    public let shadowTopN: Int

    public init(
        budget: EncounterBudgetProfile,
        selectedBearer: String = "unspecified",
        remoteWayfarerId: Data? = nil,
        userIntentBoostItemIDs: Set<Data> = [],
        relayIngestSafetyAvailable: Bool = false,
        shadowMode: EncounterShadowMode = .defaultForCurrentBuild,
        shadowTopN: Int = 5
    ) {
        self.budget = budget
        self.selectedBearer = selectedBearer
        self.remoteWayfarerId = remoteWayfarerId
        self.userIntentBoostItemIDs = userIntentBoostItemIDs
        self.relayIngestSafetyAvailable = relayIngestSafetyAvailable
        self.shadowMode = shadowMode
        self.shadowTopN = max(shadowTopN, 1)
    }
}

public enum EncounterShadowMode: String, Equatable, Sendable {
    case disabled
    case compareCanonicalV1

    public static var defaultForCurrentBuild: EncounterShadowMode {
        #if DEBUG
        return .compareCanonicalV1
        #else
        return .disabled
        #endif
    }
}

public struct EncounterShadowTransitDirectBalance: Equatable, Sendable {
    public let directCount: Int
    public let transitCount: Int

    public init(directCount: Int, transitCount: Int) {
        self.directCount = directCount
        self.transitCount = transitCount
    }
}

public struct EncounterShadowComparison: Equatable, Sendable {
    public enum Difference: String, Equatable, Sendable {
        case topNChanged
        case firstSelectedChanged
        case stopReasonChanged
        case tierDistributionChanged
        case transitDirectBalanceChanged
        case selectedItemMappingLoss
        case schedulerError

        public static func detect(
            legacyTopNItemIDsHex: [String],
            canonicalTopNItemIDsHex: [String],
            legacyFirstSelectedItemIDHex: String?,
            canonicalFirstSelectedItemIDHex: String?,
            legacyStopReason: String,
            canonicalStopReason: String,
            legacyTierDistribution: [Int],
            canonicalTierDistribution: [Int],
            legacyTransitDirectBalance: EncounterShadowTransitDirectBalance,
            canonicalTransitDirectBalance: EncounterShadowTransitDirectBalance,
            legacyUnmappedSelectedItemCount: Int,
            canonicalUnmappedSelectedItemCount: Int
        ) -> [Difference] {
            var differences: [Difference] = []
            if legacyTopNItemIDsHex != canonicalTopNItemIDsHex { differences.append(.topNChanged) }
            if legacyFirstSelectedItemIDHex != canonicalFirstSelectedItemIDHex { differences.append(.firstSelectedChanged) }
            if legacyStopReason != canonicalStopReason { differences.append(.stopReasonChanged) }
            if legacyTierDistribution != canonicalTierDistribution { differences.append(.tierDistributionChanged) }
            if legacyTransitDirectBalance != canonicalTransitDirectBalance { differences.append(.transitDirectBalanceChanged) }
            if legacyUnmappedSelectedItemCount > 0 || canonicalUnmappedSelectedItemCount > 0 {
                differences.append(.selectedItemMappingLoss)
            }
            return differences
        }
    }

    public let topN: Int
    public let legacyTopNItemIDsHex: [String]
    public let canonicalTopNItemIDsHex: [String]
    public let legacyFirstSelectedItemIDHex: String?
    public let canonicalFirstSelectedItemIDHex: String?
    public let legacyStopReason: String
    public let canonicalStopReason: String?
    public let legacyTierDistribution: [Int]
    public let canonicalTierDistribution: [Int]?
    public let legacyTransitDirectBalance: EncounterShadowTransitDirectBalance
    public let canonicalTransitDirectBalance: EncounterShadowTransitDirectBalance?
    public let legacyUnmappedSelectedItemCount: Int
    public let canonicalUnmappedSelectedItemCount: Int
    public let schedulerErrorDescription: String?
    public let differences: [Difference]

    public init(
        topN: Int,
        legacyTopNItemIDsHex: [String],
        canonicalTopNItemIDsHex: [String],
        legacyFirstSelectedItemIDHex: String?,
        canonicalFirstSelectedItemIDHex: String?,
        legacyStopReason: String,
        canonicalStopReason: String?,
        legacyTierDistribution: [Int],
        canonicalTierDistribution: [Int]?,
        legacyTransitDirectBalance: EncounterShadowTransitDirectBalance,
        canonicalTransitDirectBalance: EncounterShadowTransitDirectBalance?,
        legacyUnmappedSelectedItemCount: Int,
        canonicalUnmappedSelectedItemCount: Int,
        schedulerErrorDescription: String?,
        differences: [Difference]
    ) {
        self.topN = topN
        self.legacyTopNItemIDsHex = legacyTopNItemIDsHex
        self.canonicalTopNItemIDsHex = canonicalTopNItemIDsHex
        self.legacyFirstSelectedItemIDHex = legacyFirstSelectedItemIDHex
        self.canonicalFirstSelectedItemIDHex = canonicalFirstSelectedItemIDHex
        self.legacyStopReason = legacyStopReason
        self.canonicalStopReason = canonicalStopReason
        self.legacyTierDistribution = legacyTierDistribution
        self.canonicalTierDistribution = canonicalTierDistribution
        self.legacyTransitDirectBalance = legacyTransitDirectBalance
        self.canonicalTransitDirectBalance = canonicalTransitDirectBalance
        self.legacyUnmappedSelectedItemCount = legacyUnmappedSelectedItemCount
        self.canonicalUnmappedSelectedItemCount = canonicalUnmappedSelectedItemCount
        self.schedulerErrorDescription = schedulerErrorDescription
        self.differences = differences
    }
}

public struct EncounterDecisionScoreBreakdown: Equatable, Sendable {
    public let replicationScarcity: Double
    public let deliveryProximity: Double
    public let expiryUrgency: Double
    public let sizeCost: Double
    public let stagnationLackOfProgress: Double
    public let relayIngestOrDurableStorageSafety: Double
    public let userIntentBoost: Double
    public let contentClass: Double
    public let total: Double

    public init(
        replicationScarcity: Double,
        deliveryProximity: Double,
        expiryUrgency: Double,
        sizeCost: Double,
        stagnationLackOfProgress: Double,
        relayIngestOrDurableStorageSafety: Double,
        userIntentBoost: Double,
        contentClass: Double,
        total: Double
    ) {
        self.replicationScarcity = replicationScarcity
        self.deliveryProximity = deliveryProximity
        self.expiryUrgency = expiryUrgency
        self.sizeCost = sizeCost
        self.stagnationLackOfProgress = stagnationLackOfProgress
        self.relayIngestOrDurableStorageSafety = relayIngestOrDurableStorageSafety
        self.userIntentBoost = userIntentBoost
        self.contentClass = contentClass
        self.total = total
    }
}

public struct EncounterDecisionLog: Equatable, Sendable {
    public enum StopReason: String, Equatable, Sendable {
        case completedCandidates
        case maxItemsReached
        case maxBytesReached
        case estimatedTimeBudgetReached
        case durableCargoCapReached
    }

    public enum InterruptionMarker: String, Equatable, Sendable {
        case none
        case interruptionDetected
        case resumeReady
    }

    public let encounterClass: EncounterClass
    public let selectedBearer: String
    public let estimatedTimeBudgetSeconds: TimeInterval?
    public let estimatedByteBudget: Int
    public let candidateCountsByTier: [EncounterTier: Int]
    public let chosenItemIdHex: String?
    public let scoreBreakdown: EncounterDecisionScoreBreakdown?
    public let stopReason: StopReason?
    public let interruptionMarker: InterruptionMarker

    public init(
        encounterClass: EncounterClass,
        selectedBearer: String,
        estimatedTimeBudgetSeconds: TimeInterval?,
        estimatedByteBudget: Int,
        candidateCountsByTier: [EncounterTier: Int],
        chosenItemIdHex: String?,
        scoreBreakdown: EncounterDecisionScoreBreakdown?,
        stopReason: StopReason?,
        interruptionMarker: InterruptionMarker
    ) {
        self.encounterClass = encounterClass
        self.selectedBearer = selectedBearer
        self.estimatedTimeBudgetSeconds = estimatedTimeBudgetSeconds
        self.estimatedByteBudget = estimatedByteBudget
        self.candidateCountsByTier = candidateCountsByTier
        self.chosenItemIdHex = chosenItemIdHex
        self.scoreBreakdown = scoreBreakdown
        self.stopReason = stopReason
        self.interruptionMarker = interruptionMarker
    }
}

public struct EncounterPlan: Equatable, Sendable {
    public let encounterClass: EncounterClass
    public let items: [CargoItem]
    public let decisionLogs: [EncounterDecisionLog]
    public let shadowComparison: EncounterShadowComparison?

    public init(
        encounterClass: EncounterClass,
        items: [CargoItem],
        decisionLogs: [EncounterDecisionLog],
        shadowComparison: EncounterShadowComparison? = nil
    ) {
        self.encounterClass = encounterClass
        self.items = items
        self.decisionLogs = decisionLogs
        self.shadowComparison = shadowComparison
    }
}
