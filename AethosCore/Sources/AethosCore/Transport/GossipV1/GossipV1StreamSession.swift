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

    public init<Clock: GossipV1EncounterEngine.Clock, Store: GossipV1EncounterEngine.Store>(
        engine: GossipV1EncounterEngine,
        clock: Clock,
        store: Store,
        relayIngest: GossipV1StreamAdapter.RelayIngestConfig,
        onEvent: @escaping @Sendable (GossipV1StreamAdapter.Event) -> Void,
        onApplicationFrame: (@Sendable (GossipV1Frame) -> Void)? = nil
    ) {
        var continuation: AsyncStream<Data>.Continuation?
        self.outboundStream = AsyncStream<Data> { c in
            continuation = c
        }
        guard let continuation else {
            preconditionFailure("AsyncStream builder did not supply a continuation")
        }
        self.outboundContinuation = continuation

        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { [outboundContinuation] bytes in
                outboundContinuation.yield(bytes)
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
    public func outboundBytes() -> AsyncStream<Data> {
        outboundStream
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
    public func runInbound<S: AsyncSequence>(bytes: S) async throws where S.Element == Data {
        do {
            for try await chunk in bytes {
                try Task.checkCancellation()
                try adapter.receiveBytes(chunk)
            }
            try adapter.finish()
        } catch let error as CancellationError {
            throw error
        }
    }
}
