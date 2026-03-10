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

    private let outboundContinuation: AsyncStream<Data>.Continuation
    private let outboundStream: AsyncStream<Data>

    private var outboundStreamClaimed = false
    private var isClosed = false

    private let outboundYieldGate = OutboundYieldGate()

    public init<Clock: GossipV1EncounterEngine.Clock, Store: GossipV1EncounterEngine.Store>(
        engine: GossipV1EncounterEngine,
        clock: Clock,
        store: Store,
        relayIngest: GossipV1StreamAdapter.RelayIngestConfig,
        outboundBufferLimit: Int = 256,
        onEvent: @escaping @Sendable (GossipV1StreamAdapter.Event) -> Void,
        onApplicationFrame: (@Sendable (GossipV1Frame) -> Void)? = nil
    ) {
        var continuation: AsyncStream<Data>.Continuation?
        self.outboundStream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(outboundBufferLimit)) { c in
            continuation = c
        }
        guard let continuation else {
            preconditionFailure("AsyncStream builder did not supply a continuation")
        }
        self.outboundContinuation = continuation

        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { [outboundContinuation, outboundYieldGate] bytes in
                guard outboundYieldGate.shouldYield else { return }
                switch outboundContinuation.yield(bytes) {
                case .enqueued:
                    break
                case .dropped:
                    // Backpressure policy decided to drop; keep going.
                    break
                case .terminated:
                    // Stream is finished; stop yielding.
                    outboundYieldGate.markTerminated()
                @unknown default:
                    break
                }
            },
            onEvent: onEvent,
            onApplicationFrame: onApplicationFrame
        )

        self.adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: clock,
            store: store,
            relayIngest: relayIngest,
            hooks: hooks
        )
    }

    deinit {
        outboundContinuation.finish()
    }

    /// Outbound stream of length-prefixed Gossip v1 bytes.
    ///
    /// - Important: This stream is single-consumer. Do not create multiple active iterators.
    /// - Important: This method may only be called once.
    public func outboundBytes() -> AsyncStream<Data> {
        precondition(!outboundStreamClaimed, "outboundBytes() may only be called once; the stream is single-consumer")
        outboundStreamClaimed = true
        return outboundStream
    }

    /// Closes the session and finishes the outbound stream.
    ///
    /// Idempotent.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        outboundYieldGate.markTerminated()
        outboundContinuation.finish()
        do {
            try adapter.finish()
        } catch is CancellationError {
            // Cancellation should surface via runInbound; nothing to do here.
        } catch {
            // finish() reports errors via adapter events; ignore.
        }
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
