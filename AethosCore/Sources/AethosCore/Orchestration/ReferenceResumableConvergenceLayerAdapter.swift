import Foundation

public final class ReferenceResumableConvergenceLayerAdapter: @unchecked Sendable, ConvergenceLayerAdapter {
    public let bearerID: BearerID

    private let capabilityTimeScope: TimeScope
    private let nowUnixMs: @Sendable () -> UInt64
    private let eventStreams = ResumableSessionEventStreams()

    public init(
        bearerID: BearerID,
        capabilityTimeScope: TimeScope,
        nowUnixMs: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.bearerID = bearerID
        self.capabilityTimeScope = capabilityTimeScope
        self.nowUnixMs = nowUnixMs
    }

    public func currentCapabilitySnapshot(nowUnixMs _: UInt64) -> BearerCapabilitySnapshot {
        BearerCapabilitySnapshot(
            bearerID: bearerID,
            supportedLanes: [.discovery, .control, .data, .resume],
            timeScope: capabilityTimeScope
        )
    }

    public func sessionEvents() -> AsyncStream<BearerSessionEvent> {
        eventStreams.makeStream()
    }

    public func emitOpportunityDiscovered(
        opportunityID: EncounterInstanceID,
        occurredAtUnixMs: UInt64? = nil,
        eventID: EventID = EventID()
    ) {
        emitSessionEvent(
            kind: .opportunityDiscovered,
            encounterInstanceID: opportunityID,
            interruptionReason: nil,
            occurredAtUnixMs: occurredAtUnixMs,
            eventID: eventID
        )
    }

    public func emitOpportunityLost(
        opportunityID: EncounterInstanceID,
        occurredAtUnixMs: UInt64? = nil,
        eventID: EventID = EventID()
    ) {
        emitSessionEvent(
            kind: .opportunityLost,
            encounterInstanceID: opportunityID,
            interruptionReason: nil,
            occurredAtUnixMs: occurredAtUnixMs,
            eventID: eventID
        )
    }

    public func openSession(
        encounterInstanceID: EncounterInstanceID,
        occurredAtUnixMs: UInt64? = nil,
        eventID: EventID = EventID()
    ) {
        emitSessionEvent(
            kind: .sessionOpened,
            encounterInstanceID: encounterInstanceID,
            interruptionReason: nil,
            occurredAtUnixMs: occurredAtUnixMs,
            eventID: eventID
        )
    }

    public func closeSession(
        encounterInstanceID: EncounterInstanceID,
        occurredAtUnixMs: UInt64? = nil,
        eventID: EventID = EventID()
    ) {
        emitSessionEvent(
            kind: .sessionClosed,
            encounterInstanceID: encounterInstanceID,
            interruptionReason: nil,
            occurredAtUnixMs: occurredAtUnixMs,
            eventID: eventID
        )
    }

    public func emitSessionInterruptionObserved(
        encounterInstanceID: EncounterInstanceID,
        reason: InterruptionReason,
        occurredAtUnixMs: UInt64? = nil,
        eventID: EventID = EventID()
    ) {
        emitSessionEvent(
            kind: .sessionInterruptionObserved,
            encounterInstanceID: encounterInstanceID,
            interruptionReason: reason,
            occurredAtUnixMs: occurredAtUnixMs,
            eventID: eventID
        )
    }

    private func emitSessionEvent(
        kind: BearerSessionEventKind,
        encounterInstanceID: EncounterInstanceID,
        interruptionReason: InterruptionReason?,
        occurredAtUnixMs: UInt64?,
        eventID: EventID
    ) {
        let event = BearerSessionEvent(
            eventID: eventID,
            occurredAtUnixMs: occurredAtUnixMs ?? nowUnixMs(),
            bearerID: bearerID,
            kind: kind,
            encounterInstanceID: encounterInstanceID,
            interruptionReason: interruptionReason
        )
        eventStreams.yield(event)
    }
}

private final class ResumableSessionEventStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BearerSessionEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<BearerSessionEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            storeContinuation(continuation, for: streamID)
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(for: streamID)
            }
        }
    }

    func yield(_ event: BearerSessionEvent) {
        let streamContinuations = currentContinuations()
        for continuation in streamContinuations {
            continuation.yield(event)
        }
    }

    private func storeContinuation(_ continuation: AsyncStream<BearerSessionEvent>.Continuation, for streamID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        continuations[streamID] = continuation
    }

    private func removeContinuation(for streamID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        continuations.removeValue(forKey: streamID)
    }

    private func currentContinuations() -> [AsyncStream<BearerSessionEvent>.Continuation] {
        lock.lock()
        defer { lock.unlock() }
        return Array(continuations.values)
    }
}
