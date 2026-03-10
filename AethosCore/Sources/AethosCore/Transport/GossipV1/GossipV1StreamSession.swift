import Foundation

/// Session wrapper for Gossip v1 over an abstract byte stream.
///
/// This layer owns a `GossipV1StreamAdapter` and exposes:
/// - inbound: drive with an `AsyncSequence<Data>` of byte chunks
/// - outbound: observe adapter `onSend` bytes via `AsyncStream<Data>`
///
/// Scope: stream wiring only. No policy / replication / scoring.
public actor GossipV1StreamSession {
    private var adapter: GossipV1StreamAdapter

    /// Outbound stream of length-prefixed Gossip v1 bytes.
    ///
    /// - Important: This stream is intended to be single-consumer. Creating multiple
    ///   active iterators is not supported and may lead to lost or reordered bytes.
    public nonisolated let outboundBytes: AsyncStream<Data>
    private let outboundContinuation: AsyncStream<Data>.Continuation

    /// Transport-layer events emitted by the underlying `GossipV1StreamAdapter`.
    ///
    /// Events are best-effort, but this stream is finished deterministically on `close()`.
    public nonisolated let events: AsyncStream<GossipV1StreamAdapter.Event>
    private let eventsContinuation: AsyncStream<GossipV1StreamAdapter.Event>.Continuation

    private var isClosed = false

    private let outboundYieldGate = OutboundYieldGate()

    private let closeSignal: AsyncStream<Void>
    private let closeSignalContinuation: AsyncStream<Void>.Continuation

    public init<Clock: GossipV1EncounterEngine.Clock, Store: GossipV1EncounterEngine.Store>(
        engine: GossipV1EncounterEngine,
        clock: Clock,
        store: Store,
        relayIngest: GossipV1StreamAdapter.RelayIngestConfig,
        outboundBufferLimit: Int = 256,
        onEvent: @escaping @Sendable (GossipV1StreamAdapter.Event) -> Void,
        onApplicationFrame: (@Sendable (GossipV1Frame) -> Void)? = nil
    ) {
        var outboundContinuation: AsyncStream<Data>.Continuation?
        self.outboundBytes = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(outboundBufferLimit)) { c in
            outboundContinuation = c
        }
        guard let outboundContinuation else {
            preconditionFailure("AsyncStream builder did not supply an outbound continuation")
        }
        self.outboundContinuation = outboundContinuation

        var eventsContinuation: AsyncStream<GossipV1StreamAdapter.Event>.Continuation?
        self.events = AsyncStream<GossipV1StreamAdapter.Event>(bufferingPolicy: .unbounded) { c in
            eventsContinuation = c
        }
        guard let eventsContinuation else {
            preconditionFailure("AsyncStream builder did not supply an events continuation")
        }
        self.eventsContinuation = eventsContinuation

        var closeSignalContinuation: AsyncStream<Void>.Continuation?
        self.closeSignal = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { c in
            closeSignalContinuation = c
        }
        guard let closeSignalContinuation else {
            preconditionFailure("AsyncStream builder did not supply a close-signal continuation")
        }
        self.closeSignalContinuation = closeSignalContinuation

        let emitEvent: @Sendable (GossipV1StreamAdapter.Event) -> Void = { [eventsContinuation] event in
            _ = eventsContinuation.yield(event)
            onEvent(event)
        }

        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { [outboundContinuation, outboundYieldGate, closeSignalContinuation, emitEvent] bytes in
                guard outboundYieldGate.shouldYield else { return }
                switch outboundContinuation.yield(bytes) {
                case .enqueued:
                    break
                case .dropped:
                    // Buffering policy decided to drop a frame. This is fatal: we cannot
                    // silently lose transport bytes.
                    outboundYieldGate.markTerminated()
                    outboundContinuation.finish()
                    emitEvent(.didEncounterError(.from(OutboundBufferOverflowError())))
                    _ = closeSignalContinuation.yield(())
                    closeSignalContinuation.finish()
                case .terminated:
                    // Stream is finished; stop yielding.
                    outboundYieldGate.markTerminated()
                @unknown default:
                    break
                }
            },
            onEvent: emitEvent,
            onApplicationFrame: onApplicationFrame
        )

        self.adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: clock,
            store: store,
            relayIngest: relayIngest,
            hooks: hooks
        )

        let closeSignal = self.closeSignal
        Task { [weak self] in
            guard let self else { return }
            for await _ in closeSignal {
                await self.close()
            }
        }
    }

    deinit {
        outboundContinuation.finish()
        eventsContinuation.finish()
        closeSignalContinuation.finish()
    }

    /// Closes the session and finishes the outbound stream.
    ///
    /// Idempotent.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        outboundYieldGate.markTerminated()
        closeSignalContinuation.finish()
        do {
            try adapter.finish()
        } catch is CancellationError {
            // Cancellation should surface via runInbound; nothing to do here.
        } catch {
            // Defensive: if finish() ever throws non-cancellation, surface via events.
            _ = eventsContinuation.yield(.didEncounterError(.from(error)))
        }

        outboundContinuation.finish()
        eventsContinuation.finish()
    }

    public func sendFrame(_ frame: GossipV1Frame) {
        adapter.sendFrame(frame)
    }

    public func sendHello() {
        adapter.sendHello()
    }

    public func receiveBytes(_ bytes: Data) throws {
        try adapter.receiveBytes(bytes)
    }

    /// Drive inbound processing by consuming an async sequence of byte chunks.
    ///
    /// - Important: cancellation is preserved; `CancellationError` is not swallowed.
    /// - Important: prompt cancellation depends on the inbound sequence being cancellation-aware.
    ///   This session will always attempt to `close()` when cancellation is requested.
    public func runInbound<S: AsyncSequence>(bytes: S) async throws where S.Element == Data {
        try await withTaskCancellationHandler {
            do {
                for try await chunk in bytes {
                    try Task.checkCancellation()
                    try adapter.receiveBytes(chunk)
                }
                close()
            } catch let error as CancellationError {
                close()
                throw error
            } catch {
                close()
                throw error
            }
        } onCancel: {
            Task { await self.close() }
        }
    }
}

private final class OutboundYieldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false

    var shouldYield: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !terminated
    }

    func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }
}

private struct OutboundBufferOverflowError: Swift.Error, Sendable {
    // Map to `GossipV1TransportError.unexpected` via `.from(_)`.
}
