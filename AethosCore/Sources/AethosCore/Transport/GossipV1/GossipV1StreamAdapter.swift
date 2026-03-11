import Foundation

/// Transport-layer adapter for Gossip v1 over a length-prefixed byte stream (TCP/WebSocket).
///
/// Scope: boundary framing, canonical CBOR decode/encode via GossipV1Framing/Frames,
/// validation via GossipV1EncounterEngine, and dispatch hooks.
public struct GossipV1StreamAdapter: Sendable {
    private enum IngestOutcome {
        case continueProcessing
        case stopProcessing
    }
    public struct RelayIngestConfig: Sendable {
        public var observer: (any GossipV1EncounterEngine.RelayIngestObserving)?
        public var isAuthenticatedTransport: @Sendable () -> Bool

        public init(
            observer: (any GossipV1EncounterEngine.RelayIngestObserving)? = nil,
            isAuthenticatedTransport: @escaping @Sendable () -> Bool
        ) {
            self.observer = observer
            self.isAuthenticatedTransport = isAuthenticatedTransport
        }
    }

    public enum Event: Equatable, Sendable {
        case didReceiveFrame(GossipV1Frame)
        case didSendFrame(GossipV1Frame)
        case didChangeState(from: GossipV1EncounterEngine.State, to: GossipV1EncounterEngine.State)
        case didAcceptTransfer(itemIDs: [GossipV1ItemID])
        case didEncounterError(GossipV1TransportError)
    }

    public struct Hooks: Sendable {
        public var onSend: @Sendable (Data) -> Void
        public var onEvent: @Sendable (Event) -> Void
        public var onApplicationFrame: (@Sendable (GossipV1Frame) -> Void)?

        public init(
            onSend: @escaping @Sendable (Data) -> Void,
            onEvent: @escaping @Sendable (Event) -> Void,
            onApplicationFrame: (@Sendable (GossipV1Frame) -> Void)? = nil
        ) {
            self.onSend = onSend
            self.onEvent = onEvent
            self.onApplicationFrame = onApplicationFrame
        }
    }

    private var framer = GossipV1StreamFramer()
    private var engine: GossipV1EncounterEngine

    private let clockBox: _ClockBox
    private let storeBox: _StoreBox
    private let relayObserverBox: _RelayIngestObserverBox?
    private let relayIngest: RelayIngestConfig
    private let hooks: Hooks

    public init(
        engine: GossipV1EncounterEngine,
        clock: some GossipV1EncounterEngine.Clock,
        store: some GossipV1EncounterEngine.Store,
        relayIngest: RelayIngestConfig,
        hooks: Hooks
    ) {
        self.engine = engine
        self.clockBox = _ClockBox(clock)
        self.storeBox = _StoreBox(store)
        self.relayObserverBox = relayIngest.observer.map { _RelayIngestObserverBox($0) }
        self.relayIngest = relayIngest
        self.hooks = hooks
    }

    public init(
        engine: GossipV1EncounterEngine,
        clock: some GossipV1EncounterEngine.Clock,
        store: some GossipV1EncounterEngine.Store,
        relayObserver: (any GossipV1EncounterEngine.RelayIngestObserving)? = nil,
        isAuthenticatedRelayTransport: @escaping @Sendable () -> Bool,
        hooks: Hooks
    ) {
        self.init(
            engine: engine,
            clock: clock,
            store: store,
            relayIngest: RelayIngestConfig(observer: relayObserver, isAuthenticatedTransport: isAuthenticatedRelayTransport),
            hooks: hooks
        )
    }

    public var state: GossipV1EncounterEngine.State { engine.state }

    /// Encodes and dispatches an outbound frame as stream bytes.
    public func sendFrame(_ frame: GossipV1Frame) {
        do {
            let streamBytes = try GossipV1Framing.encodeStreamFrame(frame.encode())
            hooks.onSend(streamBytes)
            hooks.onEvent(.didSendFrame(frame))
        } catch is CancellationError {
            // No async surfaces here; report cancellation as a transport event.
            hooks.onEvent(.didEncounterError(.cancelled))
        } catch {
            hooks.onEvent(.didEncounterError(.from(error)))
        }
    }

    /// Convenience: send an outbound HELLO built by the encounter engine.
    public func sendHello() {
        sendFrame(engine.buildHello())
    }

    /// Ingests raw inbound stream bytes.
    ///
    /// This method never throws for protocol/validation failures; those are surfaced via `onEvent`.
    /// Cancellation is preserved by rethrowing `CancellationError`.
    public mutating func receiveBytes(_ bytes: Data) throws {
        do {
            let frameBytesList = try framer.append(bytes)
            for frameBytes in frameBytesList {
                let outcome = try ingestCompleteFrameBytes(frameBytes)
                if outcome == .stopProcessing {
                    return
                }
            }
        } catch let error as GossipV1StreamFramer.PartialAppendError {
            // Preserve already-decoded frames and then apply fatal boundary error semantics.
            for frameBytes in error.frames {
                let outcome = try ingestCompleteFrameBytes(frameBytes)
                if outcome == .stopProcessing {
                    return
                }
            }
            // Boundary errors are fatal: emit termination-ordered events and stop processing.
            let previousState = engine.state
            engine.terminateDueToProtocolViolation("stream boundary")
            emitTerminationEventsIfNeeded(previousState: previousState, error: .from(error.underlying))
            return
        } catch let error as CancellationError {
            throw error
        } catch {
            // Boundary errors are fatal.
            if let framing = error as? GossipV1FramingError {
                let previousState = engine.state
                engine.terminateDueToProtocolViolation("stream boundary")
                emitTerminationEventsIfNeeded(previousState: previousState, error: .from(framing))
                return
            }
            hooks.onEvent(.didEncounterError(.from(error)))
        }
    }

    private func emitTerminationEventsIfNeeded(
        previousState: GossipV1EncounterEngine.State,
        error: GossipV1TransportError
    ) {
        guard previousState != engine.state else {
            hooks.onEvent(.didEncounterError(error))
            return
        }

        // Ordering guarantee: when the encounter transitions into `.terminated`, we emit
        // `.didChangeState(..., to: .terminated)` before emitting `.didEncounterError`.
        // Non-termination transitions may interleave with errors.
        if case .terminated = engine.state {
            hooks.onEvent(.didChangeState(from: previousState, to: engine.state))
            hooks.onEvent(.didEncounterError(error))
        } else {
            // Non-termination state transitions may interleave with errors.
            hooks.onEvent(.didEncounterError(error))
            hooks.onEvent(.didChangeState(from: previousState, to: engine.state))
        }
    }

    /// Signals end-of-stream; rejects truncated frames.
    public mutating func finish() throws {
        do {
            try framer.finish()
        } catch let error as CancellationError {
            throw error
        } catch {
            hooks.onEvent(.didEncounterError(.from(error)))
        }
    }

    private mutating func ingestCompleteFrameBytes(_ frameBytes: Data) throws -> IngestOutcome {
        // Stop-immediately semantics for already-terminated encounters.
        if case .terminated = engine.state {
            return .stopProcessing
        }

        let previousState = engine.state

        let frame: GossipV1Frame
        do {
            frame = try decodeFrameBytes(frameBytes)
        } catch let error as CancellationError {
            throw error
        } catch {
            // Some decode failures are fatal at the transport boundary.
            if let frameError = error as? GossipV1FrameError {
                let previousState = engine.state
                let didTerminate = terminateEncounterIfFatalFrameError(frameError)
                emitTerminationEventsIfNeeded(previousState: previousState, error: .invalidFrame(frameError))
                return didTerminate ? .stopProcessing : .continueProcessing
            }

            hooks.onEvent(.didEncounterError(.from(error)))
            return .continueProcessing
        }

        // Always emit raw decoded frames.
        hooks.onEvent(.didReceiveFrame(frame))

        // Relay ingest is a trust-boundary: always decode + surface raw frame,
        // but only forward it to application hooks when authenticated.
        if case .relayIngest(let ingest) = frame {
            #if DEBUG
            let stateBeforeRelayIngest = engine.state
            #endif

            let isAuthenticated = relayIngest.isAuthenticatedTransport()
            if isAuthenticated {
                hooks.onApplicationFrame?(frame)
            }

            do {
                try engine.handleRelayIngest(
                    ingest,
                    isAuthenticatedRelayTransport: isAuthenticated,
                    clock: clockBox,
                    observer: relayObserverBox
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                // Per contract: observer non-cancellation errors are surfaced as local app errors.
                // Cancellation is rethrown.
                // Emit an error event and continue processing future frames.
                hooks.onEvent(.didEncounterError(.fromRelayIngest(error)))
            }

            #if DEBUG
            assert(engine.state == stateBeforeRelayIngest, "Relay ingest observer MUST NOT mutate encounter state")
            #endif
            return .continueProcessing
        }

        hooks.onApplicationFrame?(frame)

        do {
            let result = try engine.ingestInboundFrame(frame, clock: clockBox, store: storeBox)
            if previousState != result.state {
                hooks.onEvent(.didChangeState(from: previousState, to: result.state))
            }
            if !result.acceptedTransferItemIDs.isEmpty {
                hooks.onEvent(.didAcceptTransfer(itemIDs: result.acceptedTransferItemIDs))
            }

            // Surface non-fatal per-object validation errors (e.g. mixed-validity TRANSFER).
            for err in result.nonfatalValidationErrors {
                hooks.onEvent(.didEncounterError(.encounterValidation(err)))
            }

            for outbound in result.outbound {
                sendFrame(outbound)
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            // Some engine validation failures are fatal by local policy.
            if let v = error as? GossipV1EncounterEngine.ValidationError {
                let didTerminate = terminateEncounterIfFatalEngineValidationError(v)
                emitTerminationEventsIfNeeded(previousState: previousState, error: .encounterValidation(v))
                return didTerminate ? .stopProcessing : .continueProcessing
            }

            // Engine validation errors can terminate encounters; callers should close the transport.
            emitTerminationEventsIfNeeded(previousState: previousState, error: .from(error))
        }

        if case .terminated = engine.state {
            return .stopProcessing
        }
        return .continueProcessing
    }

    @discardableResult
    private mutating func terminateEncounterIfFatalFrameError(_ error: GossipV1FrameError) -> Bool {
        let message: String?
        switch error {
        case .envelopeNotAMap,
             .envelopeMissingKey,
             .envelopeTypeNotText,
             .envelopePayloadNotMap:
            message = "invalid frame envelope"
        default:
            message = nil
        }

        guard let message else { return false }
        engine.terminateDueToProtocolViolation(message)
        return true
    }

    @discardableResult
    private mutating func terminateEncounterIfFatalEngineValidationError(
        _ error: GossipV1EncounterEngine.ValidationError
    ) -> Bool {
        let message: String?
        switch error {
        case .transferTooManyObjects, .transferOversize:
            message = "transfer validation"
        default:
            message = nil
        }

        guard let message else { return false }
        engine.terminateDueToProtocolViolation(message)
        return true
    }

    private func decodeFrameBytes(_ frameBytes: Data) throws -> GossipV1Frame {
        // Normalize CBOR decoder failures into the framing error domain.
        let decodedValue = try GossipV1Framing.decodeDatagramValue(frameBytes)
        return try GossipV1Frame.decode(decodedValue: decodedValue)
    }
}

// MARK: - Type erasure for existential-friendly engine calls

private struct _ClockBox: GossipV1EncounterEngine.Clock, @unchecked Sendable {
    private let _nowUnixMs: @Sendable () -> UInt64

    init(_ clock: some GossipV1EncounterEngine.Clock) {
        self._nowUnixMs = { clock.nowUnixMs() }
    }

    func nowUnixMs() -> UInt64 { _nowUnixMs() }
}

private struct _StoreBox: GossipV1EncounterEngine.Store, @unchecked Sendable {
    private let _eligibleItemIDs: @Sendable (UInt64) throws -> [GossipV1ItemID]
    private let _fetch: @Sendable (GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)?
    private let _existingHopCount: @Sendable (GossipV1ItemID) throws -> UInt16?
    private let _ingest: @Sendable (GossipV1ItemID, Data, UInt64, UInt16) throws -> Void

    init(_ store: some GossipV1EncounterEngine.Store) {
        self._eligibleItemIDs = { nowMs in try store.eligibleItemIDs(nowMs: nowMs) }
        self._fetch = { id in try store.fetch(id) }
        self._existingHopCount = { id in try store.existingHopCount(id) }
        self._ingest = { id, bytes, expiry, hop in try store.ingest(id, envelopeBytes: bytes, expiryUnixMs: expiry, hopCount: hop) }
    }

    func eligibleItemIDs(nowMs: UInt64) throws -> [GossipV1ItemID] { try _eligibleItemIDs(nowMs) }
    func fetch(_ itemID: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? { try _fetch(itemID) }
    func existingHopCount(_ itemID: GossipV1ItemID) throws -> UInt16? { try _existingHopCount(itemID) }
    func ingest(_ itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) throws {
        try _ingest(itemID, envelopeBytes, expiryUnixMs, hopCount)
    }
}

private struct _RelayIngestObserverBox: GossipV1EncounterEngine.RelayIngestObserving, @unchecked Sendable {
    private let _note: @Sendable ([GossipV1ItemID], UInt64) throws -> Void

    init(_ observer: any GossipV1EncounterEngine.RelayIngestObserving) {
        self._note = { itemIDs, nowMs in
            try observer.noteAuthenticatedRelayIngest(itemIDs: itemIDs, nowMs: nowMs)
        }
    }

    func noteAuthenticatedRelayIngest(itemIDs: [GossipV1ItemID], nowMs: UInt64) throws {
        try _note(itemIDs, nowMs)
    }
}

/// Single error domain for the Gossip v1 transport adapter layer.
public enum GossipV1TransportError: Swift.Error, Equatable, Sendable {
    case cancelled

    case streamBoundary(GossipV1FramingError)
    case invalidFrame(GossipV1FrameError)
    case encounterValidation(GossipV1EncounterEngine.ValidationError)
    case relayIngestValidation(GossipV1EncounterEngine.ValidationError)

    /// Defensive fallback for unexpected failures.
    case unexpected

    static func from(_ error: Swift.Error) -> GossipV1TransportError {
        if error is CancellationError { return .cancelled }
        if let e = error as? GossipV1FramingError { return .streamBoundary(e) }
        if let e = error as? GossipV1FrameError { return .invalidFrame(e) }
        if let e = error as? GossipV1EncounterEngine.ValidationError { return .encounterValidation(e) }
        return .unexpected
    }

    static func fromRelayIngest(_ error: Swift.Error) -> GossipV1TransportError {
        if error is CancellationError { return .cancelled }
        if let e = error as? GossipV1EncounterEngine.ValidationError { return .relayIngestValidation(e) }
        return .unexpected
    }
}
