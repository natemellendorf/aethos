public enum BearerFunctionLane: String, Equatable, Sendable, Codable {
    case discovery
    case control
    case data
    case resume
}

public enum TransitionType: String, Equatable, Sendable, Codable {
    case upgrade
    case downgrade
    case failover
    case handoff
    case resume
}

public enum TerminalOutcome: String, Equatable, Sendable, Codable {
    case cleanEnd = "clean-end"
    case failedEnd = "failed-end"
    case policyStop = "policy-stop"
}

public enum InterruptionReason: String, Equatable, Sendable, Codable {
    case contactLost = "contact_lost"
    case sessionIdleTimeout = "session_idle_timeout"
}

public enum EncounterStopClass: String, Equatable, Sendable, Codable {
    case policyStop = "policy_stop"
    case completed = "completed"
    case noEligibleItems = "no_eligible_items"
    case budgetExhausted = "budget_exhausted"
}

/// Orchestration-level stop reason for deterministic terminal mapping.
///
/// This type bridges existing scheduler/routing stop reasons and adds
/// the policy-driven `policy-stop` reason without requiring changes to
/// existing scheduler public APIs.
public enum EncounterOrchestrationStopReason: String, Equatable, Sendable, Codable {
    case completed
    case noEligibleItems = "no-eligible-items"
    case budgetItemsExhausted = "budget-items-exhausted"
    case budgetBytesExhausted = "budget-bytes-exhausted"
    case encounterTimeExhausted = "encounter-time-exhausted"
    case durableRatioCapReached = "durable-ratio-cap-reached"
    case policyStop = "policy-stop"

    public init(selectionStopReason: EncounterSelectionStopReason) {
        switch selectionStopReason {
        case .completed:
            self = .completed
        case .budgetItemsExhausted:
            self = .budgetItemsExhausted
        case .budgetBytesExhausted:
            self = .budgetBytesExhausted
        case .encounterTimeExhausted:
            self = .encounterTimeExhausted
        case .durableRatioCapReached:
            self = .durableRatioCapReached
        case .noEligibleItems:
            self = .noEligibleItems
        }
    }

    public init(decisionLogStopReason: EncounterDecisionLog.StopReason) {
        switch decisionLogStopReason {
        case .completedCandidates:
            self = .completed
        case .maxItemsReached:
            self = .budgetItemsExhausted
        case .maxBytesReached:
            self = .budgetBytesExhausted
        case .estimatedTimeBudgetReached:
            self = .encounterTimeExhausted
        case .durableCargoCapReached:
            self = .durableRatioCapReached
        }
    }

    public var selectionStopReason: EncounterSelectionStopReason? {
        switch self {
        case .completed:
            return .completed
        case .noEligibleItems:
            return .noEligibleItems
        case .budgetItemsExhausted:
            return .budgetItemsExhausted
        case .budgetBytesExhausted:
            return .budgetBytesExhausted
        case .encounterTimeExhausted:
            return .encounterTimeExhausted
        case .durableRatioCapReached:
            return .durableRatioCapReached
        case .policyStop:
            return nil
        }
    }

    public var terminalOutcome: TerminalOutcome {
        switch self {
        case .policyStop:
            return .policyStop
        case .completed,
             .noEligibleItems,
             .budgetItemsExhausted,
             .budgetBytesExhausted,
             .encounterTimeExhausted,
             .durableRatioCapReached:
            return .cleanEnd
        }
    }

    public var stopClass: EncounterStopClass {
        switch self {
        case .policyStop:
            return .policyStop
        case .completed:
            return .completed
        case .noEligibleItems:
            return .noEligibleItems
        case .budgetItemsExhausted,
             .budgetBytesExhausted,
             .encounterTimeExhausted,
             .durableRatioCapReached:
            return .budgetExhausted
        }
    }
}
