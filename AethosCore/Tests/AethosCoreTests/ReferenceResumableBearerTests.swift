import Foundation
import Testing
@testable import AethosCore

@Test
func referenceResumableAdapterSupportsDiscoveryControlDataAndResumeLanes() {
    let bearerID = BearerID(rawValue: "resumable-ref")
    let timeScope = TimeScope(observedAt: 100, staleAfter: 200, validUntil: 300)
    let adapter = ReferenceResumableConvergenceLayerAdapter(
        bearerID: bearerID,
        capabilityTimeScope: timeScope,
        nowUnixMs: { 999 }
    )

    let snapshot = adapter.currentCapabilitySnapshot(nowUnixMs: 150)
    #expect(snapshot.bearerID == bearerID)
    #expect(snapshot.supportedLanes == [.discovery, .control, .data, .resume])
}

@Test
func referenceResumableAdapterPropagatesTimeScopeForDeterministicEvaluation() {
    let validWindowScope = TimeScope(observedAt: 100, staleAfter: 200, validUntil: 250)
    let validWindowAdapter = ReferenceResumableConvergenceLayerAdapter(
        bearerID: BearerID(rawValue: "scope-resumable-valid"),
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
    let invalidOrderingAdapter = ReferenceResumableConvergenceLayerAdapter(
        bearerID: BearerID(rawValue: "scope-resumable-invalid"),
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
func referenceResumableAdapterInterruptionEventsCarryReasonAndEncounterInstanceID() async {
    let bearerID = BearerID(rawValue: "resumable-events-ref")
    let adapter = ReferenceResumableConvergenceLayerAdapter(
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

    let encounterID = EncounterInstanceID(rawValue: "enc-resume-1")
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
        reason: .sessionIdleTimeout,
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

    #expect(captured[2].kind == .sessionInterruptionObserved)
    #expect(captured[2].bearerID == bearerID)
    #expect(captured[2].encounterInstanceID == encounterID)
    #expect(captured[2].interruptionReason == .sessionIdleTimeout)
}

@Test
func referenceResumableAdapterDefaultsOccurredAtUnixMsWhenNil() async {
    let adapter = ReferenceResumableConvergenceLayerAdapter(
        bearerID: BearerID(rawValue: "resumable-default-time"),
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

    let encounterID = EncounterInstanceID(rawValue: "enc-resume-default")
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

@Test
func referenceResumableAdapterFansOutEventsToMultipleSubscribers() async {
    let adapter = ReferenceResumableConvergenceLayerAdapter(
        bearerID: BearerID(rawValue: "resumable-fanout"),
        capabilityTimeScope: TimeScope(observedAt: 1, staleAfter: 2),
        nowUnixMs: { 50 }
    )

    let firstStream = adapter.sessionEvents()
    let secondStream = adapter.sessionEvents()

    let firstCollector = Task { () -> [BearerSessionEvent] in
        var iterator = firstStream.makeAsyncIterator()
        var captured: [BearerSessionEvent] = []
        for _ in 0 ..< 2 {
            if let event = await iterator.next() {
                captured.append(event)
            }
        }
        return captured
    }

    let secondCollector = Task { () -> [BearerSessionEvent] in
        var iterator = secondStream.makeAsyncIterator()
        var captured: [BearerSessionEvent] = []
        for _ in 0 ..< 2 {
            if let event = await iterator.next() {
                captured.append(event)
            }
        }
        return captured
    }

    await Task.yield()

    let encounterID = EncounterInstanceID(rawValue: "enc-resume-fanout")
    adapter.emitOpportunityDiscovered(opportunityID: encounterID, eventID: EventID(rawValue: "fanout-1"))
    adapter.emitOpportunityLost(opportunityID: encounterID, eventID: EventID(rawValue: "fanout-2"))

    let firstCaptured = await firstCollector.value
    let secondCaptured = await secondCollector.value

    #expect(firstCaptured.count == 2)
    #expect(secondCaptured.count == 2)

    #expect(firstCaptured.map(\.eventID) == secondCaptured.map(\.eventID))
    #expect(firstCaptured.map(\.kind) == secondCaptured.map(\.kind))
    #expect(firstCaptured.map(\.encounterInstanceID) == secondCaptured.map(\.encounterInstanceID))
}
