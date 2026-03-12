import Foundation
import XCTest
@testable import AethosCore

private typealias Locked<T> = GossipV1TestSupport.Locked<T>

final class GossipV1StreamSessionTests: XCTestCase {
    func testSendHelloYieldsOutboundBytes() async throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let session = GossipV1StreamSession(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayIngest: .init(observer: nil, isAuthenticatedTransport: { false }),
            onEvent: { _ in }
        )

        let outbound = session.outboundBytes
        let readTask = Task { () -> GossipV1Frame? in
            var it = outbound.makeAsyncIterator()
            guard let produced = await it.next() else { return nil }
            let frameBytes = try GossipV1Framing.decodeSingleStreamFrame(from: produced)
            let decodedValue = try GossipV1Framing.decodeDatagramValue(frameBytes)
            return try GossipV1Frame.decode(decodedValue: decodedValue)
        }

        await session.sendHello()
        let producedFrame = try await withTimeout(seconds: 1) { try await readTask.value }
        guard case .hello(let decodedHello)? = producedFrame else {
            return XCTFail("Expected HELLO frame")
        }
        XCTAssertEqual(decodedHello.version, GossipV1.GOSSIP_VERSION)
    }

    func testInboundBytesDriveDecodingAndEmitEvents() async throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let session = GossipV1StreamSession(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayIngest: .init(observer: nil, isAuthenticatedTransport: { false }),
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        let helloFrameBytes = localHello.encode()
        let streamBytes = try GossipV1Framing.encodeStreamFrame(helloFrameBytes)
        try await session.runInbound(bytes: AsyncStream<Data> { continuation in
            continuation.yield(streamBytes)
            continuation.finish()
        })

        let snapshot = events.withLock { $0 }
        XCTAssertTrue(snapshot.contains { event in
            if case .didReceiveFrame(.hello) = event { return true }
            return false
        })
        XCTAssertTrue(snapshot.contains { event in
            if case .didChangeState(from: .awaitingHello, to: .active) = event { return true }
            return false
        })
    }

    func testRunInboundCancellationClosesOutboundPromptly() async throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let session = GossipV1StreamSession(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayIngest: .init(observer: nil, isAuthenticatedTransport: { false }),
            onEvent: { _ in }
        )

        let outbound = session.outboundBytes
        let outboundFinished = Task {
            var it = outbound.makeAsyncIterator()
            while await it.next() != nil {}
        }

        let neverEndingInbound = AsyncStream<Data> { _ in }
        let runTask = Task {
            try await session.runInbound(bytes: neverEndingInbound)
        }

        runTask.cancel()
        try await withTimeout(seconds: 1) {
            _ = try? await runTask.value
        }
        try await withTimeout(seconds: 1) {
            _ = await outboundFinished.value
        }
    }

    func testCloseFinishesOutboundAndPreventsFurtherYields() async throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let session = GossipV1StreamSession(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayIngest: .init(observer: nil, isAuthenticatedTransport: { false }),
            onEvent: { _ in }
        )

        let outbound = session.outboundBytes
        let nextTask = Task { () -> Data? in
            var it = outbound.makeAsyncIterator()
            return await it.next()
        }

        await session.close()
        await session.sendHello()

        let next = try await withTimeout(seconds: 1) { await nextTask.value }
        XCTAssertNil(next)
    }

    func testRunInboundRethrowsThrowingInboundSequenceError() async throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let session = GossipV1StreamSession(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayIngest: .init(observer: nil, isAuthenticatedTransport: { false }),
            onEvent: { _ in }
        )

        struct Boom: Swift.Error {}
        let inbound = AsyncThrowingStream<Data, Swift.Error> { continuation in
            continuation.finish(throwing: Boom())
        }

        do {
            try await session.runInbound(bytes: inbound)
            XCTFail("Expected runInbound to rethrow inbound sequence error")
        } catch is Boom {
            // expected
        }

        // Ensure the session closed and outbound finished.
        let outbound = session.outboundBytes
        let drain = Task {
            var it = outbound.makeAsyncIterator()
            while await it.next() != nil {}
        }
        try await withTimeout(seconds: 1) { _ = await drain.value }
    }

    func testOutboundDropSurfacedAndClosesSession() async throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let session = GossipV1StreamSession(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayIngest: .init(observer: nil, isAuthenticatedTransport: { false }),
            outboundBufferLimit: 1,
            onEvent: { _ in }
        )

        let events = session.events
        let errorTask = Task { () -> GossipV1TransportError? in
            var it = events.makeAsyncIterator()
            while let event = await it.next() {
                if case .didEncounterError(let e) = event { return e }
            }
            return nil
        }

        // Do not consume outboundBytes; force bufferingOldest(1) to drop quickly.
        await session.sendHello()
        await session.sendHello()
        await session.sendHello()

        let error = try await withTimeout(seconds: 1) { await errorTask.value }
        XCTAssertEqual(error, .unexpected)

        // Outbound should be finished after fatal drop.
        let outbound = session.outboundBytes
        let outboundFinished = Task {
            var it = outbound.makeAsyncIterator()
            while await it.next() != nil {}
        }
        try await withTimeout(seconds: 1) { _ = await outboundFinished.value }
    }
}

// MARK: - Minimal helpers (scoped to this file)

private struct TimeoutError: Swift.Error, CustomStringConvertible {
    let seconds: TimeInterval
    let context: String
    var description: String { "Timeout after \(seconds)s: \(context)" }
}

private func withTimeout<T: Sendable>(seconds: TimeInterval, context: String = "operation did not complete", _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds, context: context)
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func makeHello(version: UInt64, maxWant: UInt64 = 128, maxTransfer: UInt64 = 16) throws -> GossipV1HelloFrame {
    let pubKey = Data(repeating: 0x01, count: 32)
    let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKey)
    return try GossipV1HelloFrame(
        version: version,
        nodeID: nodeID,
        nodePublicKeyRawBytes: pubKey,
        capabilities: ["store"],
        propagationClass: "direct",
        maxWant: maxWant,
        maxTransfer: maxTransfer
    )
}

private struct FixedClock: GossipV1EncounterEngine.Clock {
    let nowMs: UInt64
    func nowUnixMs() -> UInt64 { nowMs }
}

private final class InMemoryGossipStore: @unchecked Sendable, GossipV1EncounterEngine.Store {
    func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { [] }
    func fetch(_: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? { nil }
    func existingHopCount(_: GossipV1ItemID) throws -> UInt16? { nil }
    func ingest(_: GossipV1ItemID, envelopeBytes _: Data, expiryUnixMs _: UInt64, hopCount _: UInt16) throws {}
}
