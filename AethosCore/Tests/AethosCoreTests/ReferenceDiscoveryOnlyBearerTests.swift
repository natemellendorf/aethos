import Foundation
import Testing
@testable import AethosCore

@Test
func referenceDiscoveryOnlyAdapterSupportsDiscoveryLaneOnly() {
    let bearerID = BearerID(rawValue: "discovery-ref")
    let timeScope = TimeScope(observedAt: 100, staleAfter: 200, validUntil: 300)
    let adapter = ReferenceDiscoveryOnlyConvergenceLayerAdapter(
        bearerID: bearerID,
        capabilityTimeScope: timeScope,
        nowUnixMs: { 999 }
    )

    let snapshot = adapter.currentCapabilitySnapshot(nowUnixMs: 150)
    #expect(snapshot.bearerID == bearerID)
    #expect(snapshot.supportedLanes == [.discovery])
    #expect(snapshot.supportedLanes.contains(.control) == false)
    #expect(snapshot.supportedLanes.contains(.data) == false)
    #expect(snapshot.supportedLanes.contains(.resume) == false)
}

@Test
func referenceDiscoveryOnlyAdapterPropagatesTimeScopeForDeterministicEvaluation() {
    let validWindowScope = TimeScope(observedAt: 100, staleAfter: 200, validUntil: 250)
    let validWindowAdapter = ReferenceDiscoveryOnlyConvergenceLayerAdapter(
        bearerID: BearerID(rawValue: "scope-ref-valid"),
        capabilityTimeScope: validWindowScope,
        nowUnixMs: { 0 }
    )

    let validWindowSnapshot = validWindowAdapter.currentCapabilitySnapshot(nowUnixMs: 125)
    #expect(validWindowSnapshot.timeScope == validWindowScope)

    let staleEval = TimeScopeEvaluator.evaluate(validWindowSnapshot.timeScope, nowUnixMs: 220)
    #expect(staleEval.result == .timeScopeStale)
    #expect(staleEval.refusalReason == .timeScopeStale)

    let expiredEval = TimeScopeEvaluator.evaluate(validWindowSnapshot.timeScope, nowUnixMs: 250)
    #expect(expiredEval.result == .timeScopeExpired)
    #expect(expiredEval.refusalReason == .timeScopeExpired)

    let invalidOrderingScope = TimeScope(observedAt: 300, staleAfter: 200, validUntil: 250)
    let invalidOrderingAdapter = ReferenceDiscoveryOnlyConvergenceLayerAdapter(
        bearerID: BearerID(rawValue: "scope-ref-invalid"),
        capabilityTimeScope: invalidOrderingScope,
        nowUnixMs: { 0 }
    )

    let invalidOrderingSnapshot = invalidOrderingAdapter.currentCapabilitySnapshot(nowUnixMs: 999)
    #expect(invalidOrderingSnapshot.timeScope == invalidOrderingScope)

    let invalidEval = TimeScopeEvaluator.evaluate(invalidOrderingSnapshot.timeScope, nowUnixMs: 999)
    #expect(invalidEval.result == .timeScopeInvalid)
    #expect(invalidEval.refusalReason == .timeScopeInvalid)
}

@Test
func referenceDiscoveryOnlyAdapterEmitsOpportunityEventsInOrderWithBearerID() async {
    let bearerID = BearerID(rawValue: "events-ref")
    let adapter = ReferenceDiscoveryOnlyConvergenceLayerAdapter(
        bearerID: bearerID,
        capabilityTimeScope: TimeScope(observedAt: 100, staleAfter: 200),
        nowUnixMs: { 77 }
    )

    let events = adapter.sessionEvents()
    let collector = Task { () -> [BearerSessionEvent] in
        var iterator = events.makeAsyncIterator()
        var captured: [BearerSessionEvent] = []
        for _ in 0 ..< 3 {
            if let event = await iterator.next() {
                captured.append(event)
            }
        }
        return captured
    }

    await Task.yield()

    let firstOpportunity = EncounterInstanceID(rawValue: "opp-1")
    let secondOpportunity = EncounterInstanceID(rawValue: "opp-2")
    let thirdOpportunity = EncounterInstanceID(rawValue: "opp-3")

    adapter.emitOpportunityDiscovered(opportunityID: firstOpportunity, occurredAtUnixMs: 101, eventID: EventID(rawValue: "e1"))
    adapter.emitOpportunityLost(opportunityID: secondOpportunity, occurredAtUnixMs: 102, eventID: EventID(rawValue: "e2"))
    adapter.emitOpportunityDiscovered(opportunityID: thirdOpportunity, occurredAtUnixMs: 103, eventID: EventID(rawValue: "e3"))

    let captured = await collector.value
    #expect(captured.count == 3)

    #expect(captured[0].kind == .opportunityDiscovered)
    #expect(captured[0].bearerID == bearerID)
    #expect(captured[0].encounterInstanceID == firstOpportunity)

    #expect(captured[1].kind == .opportunityLost)
    #expect(captured[1].bearerID == bearerID)
    #expect(captured[1].encounterInstanceID == secondOpportunity)

    #expect(captured[2].kind == .opportunityDiscovered)
    #expect(captured[2].bearerID == bearerID)
    #expect(captured[2].encounterInstanceID == thirdOpportunity)
}
