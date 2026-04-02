public struct BearerCapabilitySnapshot: Equatable, Sendable, Codable {
    public let bearerID: BearerID
    public let supportedLanes: Set<BearerFunctionLane>
    public let timeScope: TimeScope

    public init(
        bearerID: BearerID,
        supportedLanes: Set<BearerFunctionLane>,
        timeScope: TimeScope
    ) {
        self.bearerID = bearerID
        self.supportedLanes = supportedLanes
        self.timeScope = timeScope
    }
}

public enum BearerSessionEventKind: String, Equatable, Sendable, Codable {
    case opportunityDiscovered = "opportunity_discovered"
    case opportunityLost = "opportunity_lost"
    case sessionOpened = "session_opened"
    case sessionClosed = "session_closed"
    /// CLA-scoped interruption notification (distinct from telemetry `eventType`).
    case sessionInterruptionObserved = "session_interruption_observed"
}

public struct BearerSessionEvent: Equatable, Sendable, Codable {
    public let eventID: EventID
    public let occurredAtUnixMs: UInt64
    public let bearerID: BearerID
    public let kind: BearerSessionEventKind
    public let encounterInstanceID: EncounterInstanceID?
    public let interruptionReason: InterruptionReason?

    public init(
        eventID: EventID,
        occurredAtUnixMs: UInt64,
        bearerID: BearerID,
        kind: BearerSessionEventKind,
        encounterInstanceID: EncounterInstanceID? = nil,
        interruptionReason: InterruptionReason? = nil
    ) {
        self.eventID = eventID
        self.occurredAtUnixMs = occurredAtUnixMs
        self.bearerID = bearerID
        self.kind = kind
        self.encounterInstanceID = encounterInstanceID
        self.interruptionReason = interruptionReason
    }
}

public enum OrchestrationContractError: Error, Equatable, Sendable {
    case acceptedCandidateCannotHaveRefusalReason
    case acceptedCandidateCannotHaveTimeScopeEvaluation
    case refusedCandidateMissingRefusalReason
    case timeScopeEvalRequiredForTimeScopeRefusal
    case refusedCandidateCannotHaveTimeScopeEvaluationForNonTimeScopeRefusal
    case refusedCandidateTimeScopeEvaluationMismatch(expected: TimeScopeEvaluationResult, actual: TimeScopeEvaluationResult)
    case selectedCandidateNotAccepted(BearerID)
    case acceptedTransitionCannotHaveRefusalReason
    case acceptedTransitionCannotHaveTimeScopeEvaluation
    case refusedTransitionMissingRefusalReason
    case refusedTransitionCannotHaveTimeScopeEvaluationForNonTimeScopeRefusal
    case refusedTransitionTimeScopeEvaluationMismatch(expected: TimeScopeEvaluationResult, actual: TimeScopeEvaluationResult)
    case refusedTransitionCannotSelectCandidate
    case selectedBearerRequiredWhenTransitionAccepted
}

public struct EncounterSelectionCandidateEvaluation: Equatable, Sendable {
    public let candidateID: BearerID
    public let accepted: Bool
    public let refusalReason: RefusalReason?
    public let timeScopeEval: TimeScopeEvaluation?

    public init(
        candidateID: BearerID,
        accepted: Bool,
        refusalReason: RefusalReason? = nil,
        timeScopeEval: TimeScopeEvaluation? = nil
    ) throws {
        if accepted {
            guard refusalReason == nil else {
                throw OrchestrationContractError.acceptedCandidateCannotHaveRefusalReason
            }
            guard timeScopeEval == nil else {
                throw OrchestrationContractError.acceptedCandidateCannotHaveTimeScopeEvaluation
            }
            self.candidateID = candidateID
            self.accepted = accepted
            self.refusalReason = nil
            self.timeScopeEval = nil
            return
        }

        guard let refusalReason else {
            throw OrchestrationContractError.refusedCandidateMissingRefusalReason
        }
        if let expectedResult = refusalReason.requiredTimeScopeEvaluationResult {
            guard let timeScopeEval else {
                throw OrchestrationContractError.timeScopeEvalRequiredForTimeScopeRefusal
            }
            guard timeScopeEval.result == expectedResult else {
                throw OrchestrationContractError.refusedCandidateTimeScopeEvaluationMismatch(
                    expected: expectedResult,
                    actual: timeScopeEval.result
                )
            }
        } else {
            guard timeScopeEval == nil else {
                throw OrchestrationContractError.refusedCandidateCannotHaveTimeScopeEvaluationForNonTimeScopeRefusal
            }
        }

        self.candidateID = candidateID
        self.accepted = accepted
        self.refusalReason = refusalReason
        self.timeScopeEval = timeScopeEval
    }
}

public struct EncounterSelectionOutcome: Equatable, Sendable {
    public let requiredLanes: Set<BearerFunctionLane>
    public let candidateSequence: [EncounterSelectionCandidateEvaluation]
    public let selectedCandidateID: BearerID?

    public init(
        requiredLanes: Set<BearerFunctionLane>,
        candidateSequence: [EncounterSelectionCandidateEvaluation],
        selectedCandidateID: BearerID?
    ) throws {
        if let selectedCandidateID {
            guard candidateSequence.contains(where: { $0.candidateID == selectedCandidateID && $0.accepted }) else {
                throw OrchestrationContractError.selectedCandidateNotAccepted(selectedCandidateID)
            }
        }

        self.requiredLanes = requiredLanes
        self.candidateSequence = candidateSequence
        self.selectedCandidateID = selectedCandidateID
    }
}

public struct EncounterTransitionDecision: Equatable, Sendable {
    public let transitionIntent: TransitionType
    public let fromEncounterInstanceID: EncounterInstanceID
    public let toEncounterInstanceID: EncounterInstanceID?
    public let selectedCandidateID: BearerID?
    public let accepted: Bool
    public let refusalReason: RefusalReason?
    public let timeScopeEval: TimeScopeEvaluation?

    public init(
        transitionIntent: TransitionType,
        fromEncounterInstanceID: EncounterInstanceID,
        toEncounterInstanceID: EncounterInstanceID?,
        selectedCandidateID: BearerID?,
        accepted: Bool,
        refusalReason: RefusalReason? = nil,
        timeScopeEval: TimeScopeEvaluation? = nil
    ) throws {
        if accepted {
            guard selectedCandidateID != nil else {
                throw OrchestrationContractError.selectedBearerRequiredWhenTransitionAccepted
            }
            guard refusalReason == nil else {
                throw OrchestrationContractError.acceptedTransitionCannotHaveRefusalReason
            }
            guard timeScopeEval == nil else {
                throw OrchestrationContractError.acceptedTransitionCannotHaveTimeScopeEvaluation
            }

            self.transitionIntent = transitionIntent
            self.fromEncounterInstanceID = fromEncounterInstanceID
            self.toEncounterInstanceID = toEncounterInstanceID
            self.selectedCandidateID = selectedCandidateID
            self.accepted = true
            self.refusalReason = nil
            self.timeScopeEval = nil
            return
        }

        guard selectedCandidateID == nil else {
            throw OrchestrationContractError.refusedTransitionCannotSelectCandidate
        }

        guard let refusalReason else {
            throw OrchestrationContractError.refusedTransitionMissingRefusalReason
        }
        if let expectedResult = refusalReason.requiredTimeScopeEvaluationResult {
            guard let timeScopeEval else {
                throw OrchestrationContractError.timeScopeEvalRequiredForTimeScopeRefusal
            }
            guard timeScopeEval.result == expectedResult else {
                throw OrchestrationContractError.refusedTransitionTimeScopeEvaluationMismatch(
                    expected: expectedResult,
                    actual: timeScopeEval.result
                )
            }
        } else {
            guard timeScopeEval == nil else {
                throw OrchestrationContractError.refusedTransitionCannotHaveTimeScopeEvaluationForNonTimeScopeRefusal
            }
        }

        self.transitionIntent = transitionIntent
        self.fromEncounterInstanceID = fromEncounterInstanceID
        self.toEncounterInstanceID = toEncounterInstanceID
        self.selectedCandidateID = selectedCandidateID
        self.accepted = false
        self.refusalReason = refusalReason
        self.timeScopeEval = timeScopeEval
    }
}

public protocol ConvergenceLayerAdapter: Sendable {
    var bearerID: BearerID { get }
    func currentCapabilitySnapshot(nowUnixMs: UInt64) -> BearerCapabilitySnapshot
    func sessionEvents() -> AsyncStream<BearerSessionEvent>
}

public protocol EncounterOrchestrationPolicy: Sendable {
    func evaluateSelection(
        encounterContextID: EncounterContextID,
        encounterAttemptID: EncounterAttemptID,
        requiredLanes: Set<BearerFunctionLane>,
        candidates: [BearerCapabilitySnapshot],
        nowUnixMs: UInt64
    ) throws -> EncounterSelectionOutcome

    func decideTransition(
        encounterContextID: EncounterContextID,
        encounterAttemptID: EncounterAttemptID,
        transitionIntent: TransitionType,
        fromEncounterInstanceID: EncounterInstanceID,
        candidates: [BearerCapabilitySnapshot],
        nowUnixMs: UInt64
    ) throws -> EncounterTransitionDecision
}

public protocol EncounterTransitionHook: Sendable {
    func onTransitionDecided(_ decision: EncounterTransitionDecision)
}
