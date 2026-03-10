import Foundation
import XCTest
@testable import AethosCore

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

        let outbound = await session.outboundBytes()
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

        let outbound = await session.outboundBytes()
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

        let outbound = await session.outboundBytes()
        let nextTask = Task { () -> Data? in
            var it = outbound.makeAsyncIterator()
            return await it.next()
        }

        await session.close()
        await session.sendHello()

        let next = try await withTimeout(seconds: 1) { await nextTask.value }
        XCTAssertNil(next)
    }
}

// MARK: - Minimal helpers (scoped to this file)

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private struct TimeoutError: Swift.Error {}

private func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
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
