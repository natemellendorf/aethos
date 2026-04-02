import Foundation
import Testing
@testable import AethosCore

@Test
func orchestrationIDsSupportRawValueEqualityAndHashing() {
    let contextA = EncounterContextID(rawValue: "ctx-1")
    let contextB = EncounterContextID(rawValue: "ctx-1")
    let instance = EncounterInstanceID(rawValue: "inst-1")
    let attempt = EncounterAttemptID(rawValue: "att-1")
    let bearer = BearerID(rawValue: "bearer-1")
    let event = EventID(rawValue: "event-1")

    #expect(contextA == contextB)
    #expect(Set([contextA, contextB]).count == 1)
    #expect(instance.rawValue == "inst-1")
    #expect(attempt.rawValue == "att-1")
    #expect(bearer.rawValue == "bearer-1")
    #expect(event.rawValue == "event-1")
}

@Test
func refusalReasonAcceptsCanonicalAndExtensionCodes() {
    #expect(RefusalReason(rawValue: "capability_mismatch") == .capabilityMismatch)
    #expect(RefusalReason(rawValue: "time_scope_invalid") == .timeScopeInvalid)

    let extensionReason = RefusalReason(rawValue: "x_radio_scan_busy")
    #expect(extensionReason != nil)
    #expect(extensionReason?.isExtension == true)
    #expect(extensionReason?.isCanonical == false)
}

@Test
func refusalReasonRejectsInvalidExtensionCodes() {
    #expect(RefusalReason(rawValue: "policy-stop") == nil)
    #expect(RefusalReason(rawValue: "x_") == nil)
    #expect(RefusalReason(rawValue: "x_Radio") == nil)
    #expect(RefusalReason(rawValue: "x-with-dash") == nil)
    #expect(RefusalReason(rawValue: "not_registered_reason") == nil)
}

@Test
func timeScopeEvaluatorReturnsInvalidWhenInvariantsFail() {
    let invalidOrder = TimeScope(observedAt: 200, staleAfter: 100, validUntil: 300)
    let invalidOrderResult = TimeScopeEvaluator.evaluate(invalidOrder, nowUnixMs: 50)
    #expect(invalidOrderResult.result == .timeScopeInvalid)
    #expect(invalidOrderResult.refusalReason == .timeScopeInvalid)
    #expect(invalidOrderResult.invariants.observedAtLteStaleAfter == false)

    let invalidValidUntil = TimeScope(observedAt: 100, staleAfter: 200, validUntil: 150)
    let invalidValidUntilResult = TimeScopeEvaluator.evaluate(invalidValidUntil, nowUnixMs: 100)
    #expect(invalidValidUntilResult.result == .timeScopeInvalid)
    #expect(invalidValidUntilResult.invariants.staleAfterLteValidUntil == false)
}

@Test
func timeScopeEvaluatorReturnsExpiredStaleAndValidInDeterministicOrder() {
    let withHardCutoff = TimeScope(observedAt: 100, staleAfter: 200, validUntil: 250)
    let expiredResult = TimeScopeEvaluator.evaluate(withHardCutoff, nowUnixMs: 250)
    #expect(expiredResult.result == .timeScopeExpired)
    #expect(expiredResult.refusalReason == .timeScopeExpired)

    let staleOnly = TimeScope(observedAt: 100, staleAfter: 200, validUntil: nil)
    let staleResult = TimeScopeEvaluator.evaluate(staleOnly, nowUnixMs: 220)
    #expect(staleResult.result == .timeScopeStale)
    #expect(staleResult.invariants.staleAfterLteValidUntil == nil)

    let validResult = TimeScopeEvaluator.evaluate(staleOnly, nowUnixMs: 199)
    #expect(validResult.result == .valid)
    #expect(validResult.refusalReason == nil)
}

@Test
func orchestrationStopReasonMapsFromExistingSchedulerStopReasons() {
    #expect(EncounterOrchestrationStopReason(selectionStopReason: .completed) == .completed)
    #expect(EncounterOrchestrationStopReason(selectionStopReason: .noEligibleItems) == .noEligibleItems)
    #expect(EncounterOrchestrationStopReason(selectionStopReason: .budgetItemsExhausted) == .budgetItemsExhausted)
    #expect(EncounterOrchestrationStopReason(selectionStopReason: .budgetBytesExhausted) == .budgetBytesExhausted)
    #expect(EncounterOrchestrationStopReason(selectionStopReason: .encounterTimeExhausted) == .encounterTimeExhausted)
    #expect(EncounterOrchestrationStopReason(selectionStopReason: .durableRatioCapReached) == .durableRatioCapReached)

    #expect(EncounterOrchestrationStopReason(decisionLogStopReason: .completedCandidates) == .completed)
    #expect(EncounterOrchestrationStopReason(decisionLogStopReason: .maxItemsReached) == .budgetItemsExhausted)
    #expect(EncounterOrchestrationStopReason(decisionLogStopReason: .maxBytesReached) == .budgetBytesExhausted)
    #expect(EncounterOrchestrationStopReason(decisionLogStopReason: .estimatedTimeBudgetReached) == .encounterTimeExhausted)
    #expect(EncounterOrchestrationStopReason(decisionLogStopReason: .durableCargoCapReached) == .durableRatioCapReached)
}

@Test
func orchestrationStopReasonMapsToTerminalOutcomeAndStopClass() {
    #expect(EncounterOrchestrationStopReason.policyStop.selectionStopReason == nil)
    #expect(EncounterOrchestrationStopReason.policyStop.terminalOutcome == .policyStop)
    #expect(EncounterOrchestrationStopReason.policyStop.stopClass == .policyStop)

    #expect(EncounterOrchestrationStopReason.completed.terminalOutcome == .cleanEnd)
    #expect(EncounterOrchestrationStopReason.completed.stopClass == .completed)
    #expect(EncounterOrchestrationStopReason.noEligibleItems.stopClass == .noEligibleItems)
    #expect(EncounterOrchestrationStopReason.budgetItemsExhausted.stopClass == .budgetExhausted)
}

@Test
func selectionOutcomeEnforcesAcceptanceAndTimeScopeRules() throws {
    let candidate = BearerID(rawValue: "bearer-a")

    #expect(throws: OrchestrationContractError.refusedCandidateMissingRefusalReason) {
        _ = try EncounterSelectionCandidateEvaluation(candidateID: candidate, accepted: false)
    }

    #expect(throws: OrchestrationContractError.timeScopeEvalRequiredForTimeScopeRefusal) {
        _ = try EncounterSelectionCandidateEvaluation(
            candidateID: candidate,
            accepted: false,
            refusalReason: .timeScopeStale,
            timeScopeEval: nil
        )
    }

    let timeScopeEval = TimeScopeEvaluator.evaluate(
        TimeScope(observedAt: 100, staleAfter: 200),
        nowUnixMs: 220
    )
    let refused = try EncounterSelectionCandidateEvaluation(
        candidateID: candidate,
        accepted: false,
        refusalReason: .timeScopeStale,
        timeScopeEval: timeScopeEval
    )
    #expect(refused.refusalReason == .timeScopeStale)
    #expect(refused.timeScopeEval?.result == .timeScopeStale)

    let accepted = try EncounterSelectionCandidateEvaluation(candidateID: candidate, accepted: true)
    let outcome = try EncounterSelectionOutcome(
        requiredLanes: [.discovery, .control],
        candidateSequence: [accepted],
        selectedCandidateID: candidate
    )
    #expect(outcome.selectedCandidateID == candidate)

    #expect(throws: OrchestrationContractError.selectedCandidateNotAccepted(candidate)) {
        _ = try EncounterSelectionOutcome(
            requiredLanes: [.discovery],
            candidateSequence: [refused],
            selectedCandidateID: candidate
        )
    }

    #expect(throws: OrchestrationContractError.acceptedCandidateCannotHaveRefusalReason) {
        _ = try EncounterSelectionCandidateEvaluation(
            candidateID: candidate,
            accepted: true,
            refusalReason: .capabilityMismatch,
            timeScopeEval: nil
        )
    }

    #expect(throws: OrchestrationContractError.acceptedCandidateCannotHaveTimeScopeEvaluation) {
        _ = try EncounterSelectionCandidateEvaluation(
            candidateID: candidate,
            accepted: true,
            refusalReason: nil,
            timeScopeEval: timeScopeEval
        )
    }

    #expect(throws: OrchestrationContractError.refusedCandidateCannotHaveTimeScopeEvaluationForNonTimeScopeRefusal) {
        _ = try EncounterSelectionCandidateEvaluation(
            candidateID: candidate,
            accepted: false,
            refusalReason: .capabilityMismatch,
            timeScopeEval: timeScopeEval
        )
    }

    #expect(throws: OrchestrationContractError.refusedCandidateTimeScopeEvaluationMismatch(expected: .timeScopeExpired, actual: .timeScopeStale)) {
        _ = try EncounterSelectionCandidateEvaluation(
            candidateID: candidate,
            accepted: false,
            refusalReason: .timeScopeExpired,
            timeScopeEval: timeScopeEval
        )
    }
}

@Test
func transitionDecisionEnforcesAcceptanceAndRefusalRules() {
    let fromInstance = EncounterInstanceID(rawValue: "from-1")
    let selectedCandidate = BearerID(rawValue: "bearer-selected")

    #expect(throws: OrchestrationContractError.selectedBearerRequiredWhenTransitionAccepted) {
        _ = try EncounterTransitionDecision(
            transitionIntent: .upgrade,
            fromEncounterInstanceID: fromInstance,
            toEncounterInstanceID: nil,
            selectedCandidateID: nil,
            accepted: true
        )
    }

    #expect(throws: OrchestrationContractError.refusedTransitionMissingRefusalReason) {
        _ = try EncounterTransitionDecision(
            transitionIntent: .resume,
            fromEncounterInstanceID: fromInstance,
            toEncounterInstanceID: nil,
            selectedCandidateID: nil,
            accepted: false
        )
    }

    let staleEval = TimeScopeEvaluator.evaluate(
        TimeScope(observedAt: 100, staleAfter: 200),
        nowUnixMs: 220
    )

    #expect(throws: OrchestrationContractError.timeScopeEvalRequiredForTimeScopeRefusal) {
        _ = try EncounterTransitionDecision(
            transitionIntent: .resume,
            fromEncounterInstanceID: fromInstance,
            toEncounterInstanceID: nil,
            selectedCandidateID: nil,
            accepted: false,
            refusalReason: .timeScopeExpired,
            timeScopeEval: nil
        )
    }

    #expect(throws: OrchestrationContractError.acceptedTransitionCannotHaveRefusalReason) {
        _ = try EncounterTransitionDecision(
            transitionIntent: .upgrade,
            fromEncounterInstanceID: fromInstance,
            toEncounterInstanceID: nil,
            selectedCandidateID: selectedCandidate,
            accepted: true,
            refusalReason: .capabilityMismatch,
            timeScopeEval: nil
        )
    }

    #expect(throws: OrchestrationContractError.acceptedTransitionCannotHaveTimeScopeEvaluation) {
        _ = try EncounterTransitionDecision(
            transitionIntent: .upgrade,
            fromEncounterInstanceID: fromInstance,
            toEncounterInstanceID: nil,
            selectedCandidateID: selectedCandidate,
            accepted: true,
            refusalReason: nil,
            timeScopeEval: staleEval
        )
    }

    #expect(throws: OrchestrationContractError.refusedTransitionCannotHaveTimeScopeEvaluationForNonTimeScopeRefusal) {
        _ = try EncounterTransitionDecision(
            transitionIntent: .resume,
            fromEncounterInstanceID: fromInstance,
            toEncounterInstanceID: nil,
            selectedCandidateID: nil,
            accepted: false,
            refusalReason: .capabilityMismatch,
            timeScopeEval: staleEval
        )
    }

    #expect(throws: OrchestrationContractError.refusedTransitionTimeScopeEvaluationMismatch(expected: .timeScopeExpired, actual: .timeScopeStale)) {
        _ = try EncounterTransitionDecision(
            transitionIntent: .resume,
            fromEncounterInstanceID: fromInstance,
            toEncounterInstanceID: nil,
            selectedCandidateID: nil,
            accepted: false,
            refusalReason: .timeScopeExpired,
            timeScopeEval: staleEval
        )
    }

    #expect(throws: OrchestrationContractError.refusedTransitionCannotSelectCandidate) {
        _ = try EncounterTransitionDecision(
            transitionIntent: .resume,
            fromEncounterInstanceID: fromInstance,
            toEncounterInstanceID: nil,
            selectedCandidateID: selectedCandidate,
            accepted: false,
            refusalReason: .sessionUnavailable,
            timeScopeEval: nil
        )
    }
}

@Test
func telemetryEventCarriesRequiredEnvelopeFields() {
    let eventID = EventID(rawValue: "evt-1")
    let encounterContextID = EncounterContextID(rawValue: "ctx-1")
    let encounterInstanceID = EncounterInstanceID(rawValue: "inst-1")
    let encounterAttemptID = EncounterAttemptID(rawValue: "attempt-1")
    let bearerID = BearerID(rawValue: "bearer-1")

    let event = TelemetryEvent(
        eventID: eventID,
        layer: .encounter,
        eventType: "selection_evaluated",
        eventSequence: 7,
        occurredAtUnixMs: 1_760_000_000_000,
        encounterContextID: encounterContextID,
        encounterInstanceID: encounterInstanceID,
        encounterAttemptID: encounterAttemptID,
        bearerID: bearerID,
        payload: [
            "accepted": .bool(false),
            "retryInMs": .int(3000),
            "reasons": .array([.string("capability_mismatch"), .string("session_unavailable")]),
            "details": .object([
                "marker": .string("resume"),
                "weight": .double(0.7),
                "none": .null,
            ]),
        ]
    )

    #expect(event.contractVersion == 1)
    #expect(event.eventID == eventID)
    #expect(event.eventType == "selection_evaluated")
    #expect(event.eventSequence == 7)
    #expect(event.occurredAtUnixMs == 1_760_000_000_000)
    #expect(event.encounterContextID == encounterContextID)
    #expect(event.encounterInstanceID == encounterInstanceID)
    #expect(event.encounterAttemptID == encounterAttemptID)
    #expect(event.bearerID == bearerID)
    #expect(event.layer == .encounter)
    #expect(event.payload["accepted"] == .bool(false))
}

@Test
func telemetryEventAndJSONValueCodableRoundTrip() throws {
    let original = TelemetryEvent(
        eventID: EventID(rawValue: "evt-2"),
        layer: .forwarding,
        eventType: "transition_refused",
        eventSequence: 99,
        occurredAtUnixMs: 1_760_000_999_999,
        encounterContextID: EncounterContextID(rawValue: "ctx-2"),
        encounterInstanceID: EncounterInstanceID(rawValue: "inst-2"),
        encounterAttemptID: EncounterAttemptID(rawValue: "attempt-2"),
        bearerID: nil,
        payload: [
            "scalar": .string("ok"),
            "nested": .object([
                "num": .int(12),
                "arr": .array([.bool(true), .double(1.5)]),
            ]),
        ]
    )

    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TelemetryEvent.self, from: encoded)
    #expect(decoded == original)
}

@Test
func telemetryEventDecodeRejectsNonV1ContractVersion() throws {
    let invalidVersionPayload = """
    {
      "contractVersion": 2,
      "eventID": "evt-invalid",
      "layer": "encounter",
      "eventType": "selection_evaluated",
      "eventSequence": 1,
      "occurredAtUnixMs": 1760000000000,
      "encounterContextID": "ctx-invalid",
      "encounterInstanceID": "inst-invalid",
      "encounterAttemptID": "attempt-invalid",
      "payload": {}
    }
    """

    let payloadData = try #require(invalidVersionPayload.data(using: .utf8))
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(TelemetryEvent.self, from: payloadData)
    }
}

@Test
func jsonValuePrefersIntDecodingForIntegerLiterals() throws {
    let payloadData = try #require("1".data(using: .utf8))
    let decoded = try JSONDecoder().decode(JSONValue.self, from: payloadData)
    #expect(decoded == .int(1))
}
