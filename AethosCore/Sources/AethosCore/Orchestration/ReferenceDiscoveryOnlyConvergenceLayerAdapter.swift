import Foundation

public final class ReferenceDiscoveryOnlyConvergenceLayerAdapter: @unchecked Sendable, ConvergenceLayerAdapter {
    public let bearerID: BearerID

    private let capabilityTimeScope: TimeScope
    private let nowUnixMs: @Sendable () -> UInt64
    private let eventStreams = SessionEventStreams()

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
            supportedLanes: [.discovery],
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
        emitOpportunityEvent(
            kind: .opportunityDiscovered,
            opportunityID: opportunityID,
            occurredAtUnixMs: occurredAtUnixMs,
            eventID: eventID
        )
    }

    public func emitOpportunityLost(
        opportunityID: EncounterInstanceID,
        occurredAtUnixMs: UInt64? = nil,
        eventID: EventID = EventID()
    ) {
        emitOpportunityEvent(
            kind: .opportunityLost,
            opportunityID: opportunityID,
            occurredAtUnixMs: occurredAtUnixMs,
            eventID: eventID
        )
    }

    private func emitOpportunityEvent(
        kind: BearerSessionEventKind,
        opportunityID: EncounterInstanceID,
        occurredAtUnixMs: UInt64?,
        eventID: EventID
    ) {
        let event = BearerSessionEvent(
            eventID: eventID,
            occurredAtUnixMs: occurredAtUnixMs ?? nowUnixMs(),
            bearerID: bearerID,
            kind: kind,
            encounterInstanceID: opportunityID
        )
        eventStreams.yield(event)
    }
}

private final class SessionEventStreams: @unchecked Sendable {
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
