import Foundation
import Testing
@testable import AethosCore

@Test
func referenceControlCapableAdapterSupportsControlAndDiscoveryLanesOnly() {
    let bearerID = BearerID(rawValue: "control-ref")
    let timeScope = TimeScope(observedAt: 100, staleAfter: 200, validUntil: 300)
    let adapter = ReferenceControlCapableConvergenceLayerAdapter(
        bearerID: bearerID,
        capabilityTimeScope: timeScope,
        nowUnixMs: { 999 }
    )

    let snapshot = adapter.currentCapabilitySnapshot(nowUnixMs: 150)
    #expect(snapshot.bearerID == bearerID)
    #expect(snapshot.supportedLanes == [.discovery, .control])
    #expect(snapshot.supportedLanes.contains(.data) == false)
    #expect(snapshot.supportedLanes.contains(.resume) == false)
}

@Test
func referenceControlCapableAdapterPropagatesTimeScopeForDeterministicEvaluation() {
    let validWindowScope = TimeScope(observedAt: 100, staleAfter: 200, validUntil: 250)
    let validWindowAdapter = ReferenceControlCapableConvergenceLayerAdapter(
        bearerID: BearerID(rawValue: "scope-control-valid"),
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
    let invalidOrderingAdapter = ReferenceControlCapableConvergenceLayerAdapter(
        bearerID: BearerID(rawValue: "scope-control-invalid"),
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
func referenceControlCapableAdapterEmitsLifecycleEventsInOrder() async {
    let bearerID = BearerID(rawValue: "control-events-ref")
    let adapter = ReferenceControlCapableConvergenceLayerAdapter(
        bearerID: bearerID,
        capabilityTimeScope: TimeScope(observedAt: 100, staleAfter: 200),
        nowUnixMs: { 77 }
    )

    let events = adapter.sessionEvents()
    let collector = Task { () -> [BearerSessionEvent] in
        var iterator = events.makeAsyncIterator()
        var captured: [BearerSessionEvent] = []
        for _ in 0 ..< 5 {
            if let event = await iterator.next() {
                captured.append(event)
            }
        }
        return captured
    }

    await Task.yield()

    let encounterID = EncounterInstanceID(rawValue: "enc-1")
    adapter.emitOpportunityDiscovered(
        opportunityID: encounterID,
        occurredAtUnixMs: 101,
        eventID: EventID(rawValue: "e1")
    )
    adapter.openSession(
        encounterInstanceID: encounterID,
        occurredAtUnixMs: 102,
        eventID: EventID(rawValue: "e2")
    )
    adapter.emitSessionInterruptionObserved(
        encounterInstanceID: encounterID,
        reason: .contactLost,
        occurredAtUnixMs: 103,
        eventID: EventID(rawValue: "e3")
    )
    adapter.closeSession(
        encounterInstanceID: encounterID,
        occurredAtUnixMs: 104,
        eventID: EventID(rawValue: "e4")
    )
    adapter.emitOpportunityLost(
        opportunityID: encounterID,
        occurredAtUnixMs: 105,
        eventID: EventID(rawValue: "e5")
    )

    let captured = await collector.value
    #expect(captured.count == 5)

    #expect(captured[0].kind == .opportunityDiscovered)
    #expect(captured[0].encounterInstanceID == encounterID)
    #expect(captured[0].interruptionReason == nil)

    #expect(captured[1].kind == .sessionOpened)
    #expect(captured[1].encounterInstanceID == encounterID)
    #expect(captured[1].interruptionReason == nil)

    #expect(captured[2].kind == .sessionInterruptionObserved)
    #expect(captured[2].encounterInstanceID == encounterID)
    #expect(captured[2].interruptionReason == .contactLost)

    #expect(captured[3].kind == .sessionClosed)
    #expect(captured[3].encounterInstanceID == encounterID)
    #expect(captured[3].interruptionReason == nil)

    #expect(captured[4].kind == .opportunityLost)
    #expect(captured[4].encounterInstanceID == encounterID)
    #expect(captured[4].interruptionReason == nil)

    for event in captured {
        #expect(event.bearerID == bearerID)
    }
}

@Test
func referenceControlCapableAdapterDefaultsOccurredAtUnixMsWhenNil() async {
    let adapter = ReferenceControlCapableConvergenceLayerAdapter(
        bearerID: BearerID(rawValue: "control-default-time"),
        capabilityTimeScope: TimeScope(observedAt: 1, staleAfter: 2),
        nowUnixMs: { 777 }
    )

    let events = adapter.sessionEvents()
    let collector = Task { () -> [BearerSessionEvent] in
        var iterator = events.makeAsyncIterator()
        var captured: [BearerSessionEvent] = []
        for _ in 0 ..< 4 {
            if let event = await iterator.next() {
                captured.append(event)
            }
        }
        return captured
    }

    await Task.yield()

    let encounterID = EncounterInstanceID(rawValue: "enc-default")
    adapter.emitOpportunityDiscovered(opportunityID: encounterID)
    adapter.openSession(encounterInstanceID: encounterID)
    adapter.closeSession(encounterInstanceID: encounterID)
    adapter.emitOpportunityLost(opportunityID: encounterID)

    let captured = await collector.value
    #expect(captured.count == 4)

    for event in captured {
        #expect(event.occurredAtUnixMs == 777)
    }
}
