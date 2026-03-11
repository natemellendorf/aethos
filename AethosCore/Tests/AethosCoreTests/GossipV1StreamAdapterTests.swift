import Foundation
import XCTest
@testable import AethosCore

final class GossipV1StreamAdapterTests: XCTestCase {
    func testSendingHelloEmitsStreamBytes_lengthPrefixPlusPayload() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let sent = Locked<[Data]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { bytes in
                sent.withLock { $0.append(bytes) }
            },
            onEvent: { _ in }
        )

        let adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )
        adapter.sendHello()

        let sentSnapshot = sent.withLock { $0 }
        XCTAssertEqual(sentSnapshot.count, 1)
        let expectedPayload = engine.buildHello().encode()
        let expected = try GossipV1Framing.encodeStreamFrame(expectedPayload)
        XCTAssertEqual(sentSnapshot.first, expected)
    }

    func testHelloVersionMismatchProducesEventError() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let mismatchFrameBytes = try Data(contentsOf: fixturesDir().appendingPathComponent("hello_version_mismatch.cbor"))
        let streamBytes = try GossipV1Framing.encodeStreamFrame(mismatchFrameBytes)
        try adapter.receiveBytes(streamBytes)

        // Find the error event.
        let errorEvents = events.withLock { $0 }.compactMap { event -> GossipV1TransportError? in
            guard case .didEncounterError(let err) = event else { return nil }
            return err
        }
        XCTAssertEqual(errorEvents.count, 1)
        XCTAssertEqual(
            errorEvents.first,
            .encounterValidation(.invalidHelloVersion(expected: GossipV1.GOSSIP_VERSION, actual: GossipV1.GOSSIP_VERSION + 1))
        )
    }

    func testHelloVersionMismatch_emitsStateChangeBeforeEncounterError() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let mismatchFrameBytes = try Data(contentsOf: fixturesDir().appendingPathComponent("hello_version_mismatch.cbor"))
        let streamBytes = try GossipV1Framing.encodeStreamFrame(mismatchFrameBytes)
        try adapter.receiveBytes(streamBytes)

        let snapshot = events.withLock { $0 }
        let stateIdx = snapshot.firstIndex { event in
            if case .didChangeState = event { return true }
            return false
        }
        let errorIdx = snapshot.firstIndex { event in
            if case .didEncounterError = event { return true }
            return false
        }
        XCTAssertNotNil(stateIdx)
        XCTAssertNotNil(errorIdx)
        XCTAssertLessThan(stateIdx!, errorIdx!)
    }

    func testReceiveBytes_twoFramesInOneBuffer_firstInvalidSecondValid_secondStillProcessedWhenFirstNonFatal() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let receivedFrames = Locked<[GossipV1Frame]>([])
        let errorEvents = Locked<[GossipV1TransportError]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                switch event {
                case .didReceiveFrame(let frame):
                    receivedFrames.withLock { $0.append(frame) }
                case .didEncounterError(let err):
                    errorEvents.withLock { $0.append(err) }
                default:
                    break
                }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        // This fixture exceeds MAX_FRAME_BYTES and should fail framing as non-fatal.
        let invalidFirst = try Data(contentsOf: fixturesDir().appendingPathComponent("transfer_oversize_bytes.cbor"))
        let validSecond = try Data(contentsOf: fixturesDir().appendingPathComponent("hello.cbor"))
        let streamBytes = try GossipV1Framing.encodeStreamFrame(invalidFirst) + GossipV1Framing.encodeStreamFrame(validSecond)

        try adapter.receiveBytes(streamBytes)

        let frames = receivedFrames.withLock { $0 }
        XCTAssertEqual(frames.count, 1)
        guard case .hello(let decodedHello)? = frames.first else {
            return XCTFail("Expected HELLO frame")
        }
        XCTAssertEqual(decodedHello.version, localHello.version)

        let errors = errorEvents.withLock { $0 }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first, .invalidFrame(.transferTotalEnvelopeBytesTooLarge(max: GossipV1.MAX_TRANSFER_BYTES, actual: 524_294)))
    }

    func testReceiveBytes_stopImmediatelyAfterTermination_remainingFramesInSameBufferNotProcessed() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let receivedFrames = Locked<[GossipV1Frame]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                if case .didReceiveFrame(let frame) = event {
                    receivedFrames.withLock { $0.append(frame) }
                }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let terminatingHello = try Data(contentsOf: fixturesDir().appendingPathComponent("hello_version_mismatch.cbor"))
        let secondHello = try Data(contentsOf: fixturesDir().appendingPathComponent("hello.cbor"))
        let streamBytes = try GossipV1Framing.encodeStreamFrame(terminatingHello) + GossipV1Framing.encodeStreamFrame(secondHello)

        try adapter.receiveBytes(streamBytes)

        // Only the first frame should be decoded/emitted; termination stops further processing.
        XCTAssertEqual(receivedFrames.withLock { $0 }.count, 1)
    }

    func testRelayIngestUnauthenticated_emitsDidReceiveFrame_butDoesNotCallOnApplicationFrame() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let didReceive = Locked<[GossipV1Frame]>([])
        let onApplicationFrames = Locked<[GossipV1Frame]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                if case .didReceiveFrame(let frame) = event {
                    didReceive.withLock { $0.append(frame) }
                }
            },
            onApplicationFrame: { frame in
                onApplicationFrames.withLock { $0.append(frame) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            isAuthenticatedRelayTransport: { false },
            hooks: hooks
        )

        let relayIngestBytes = try Data(contentsOf: fixturesDir().appendingPathComponent("relay_ingest_unauthenticated.cbor"))
        let streamBytes = try GossipV1Framing.encodeStreamFrame(relayIngestBytes)
        try adapter.receiveBytes(streamBytes)

        XCTAssertEqual(didReceive.withLock { $0 }.count, 1)
        XCTAssertEqual(onApplicationFrames.withLock { $0 }.count, 0)
    }

    func testReceiveBytes_relayIngestObserverThrowingCancellationError_isRethrown() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let observer = CancellationThrowingRelayObserver()
        let hooks = GossipV1StreamAdapter.Hooks(onSend: { _ in }, onEvent: { _ in })
        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayObserver: observer,
            isAuthenticatedRelayTransport: { true },
            hooks: hooks
        )

        let relayIngestBytes = try Data(contentsOf: fixturesDir().appendingPathComponent("relay_ingest.cbor"))
        let streamBytes = try GossipV1Framing.encodeStreamFrame(relayIngestBytes)

        XCTAssertThrowsError(try adapter.receiveBytes(streamBytes)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testReceiveBytes_relayIngestObserverThrowingValidationError_isMappedToRelayIngestValidationTransportError_andDoesNotTerminateEncounter() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let thrown: GossipV1EncounterEngine.ValidationError = .encounterTerminated
        // NOTE: Relay-ingest validation errors are not produced by the engine today.
        // This observer is an intentional seam to force a ValidationError and verify the
        // adapter maps it into the relay-ingest transport error domain.
        let observer = RelayIngestValidationErrorSeamObserver(error: thrown)

        let errors = Locked<[GossipV1TransportError]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                guard case .didEncounterError(let err) = event else { return }
                errors.withLock { $0.append(err) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayObserver: observer,
            isAuthenticatedRelayTransport: { true },
            hooks: hooks
        )

        let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: Data([0x01]))
        let relayIngest = try GossipV1RelayIngestFrame(itemIDs: [itemID])
        let streamBytes = try GossipV1Framing.encodeStreamFrame(GossipV1Frame.relayIngest(relayIngest).encode())
        try adapter.receiveBytes(streamBytes)

        XCTAssertEqual(errors.withLock { $0 }, [.relayIngestValidation(thrown)])

        // Observer errors must not change encounter state.
        XCTAssertEqual(adapter.state, .awaitingHello)
    }

    func testReceiveBytes_relayIngestObserverNonCancellationError_emitsErrorEvent_andContinuesProcessingFutureFrames() throws {
        let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
        let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

        let thrown = FixtureError()
        let observer = ThrowingRelayObserver(error: thrown)

        let events = Locked<[GossipV1StreamAdapter.Event]>([])
        let hooks = GossipV1StreamAdapter.Hooks(
            onSend: { _ in },
            onEvent: { event in
                events.withLock { $0.append(event) }
            }
        )

        var adapter = GossipV1StreamAdapter(
            engine: engine,
            clock: FixedClock(nowMs: 0),
            store: InMemoryGossipStore(),
            relayObserver: observer,
            isAuthenticatedRelayTransport: { true },
            hooks: hooks
        )

        let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: Data([0x01]))
        let ingest = try GossipV1RelayIngestFrame(itemIDs: [itemID])
        let relayBytes = try GossipV1Framing.encodeStreamFrame(GossipV1Frame.relayIngest(ingest).encode())
        let helloBytes = try Data(contentsOf: fixturesDir().appendingPathComponent("hello.cbor"))
        let helloStreamBytes = try GossipV1Framing.encodeStreamFrame(helloBytes)

        // Relay ingest observer error must not stop processing subsequent frames.
        try adapter.receiveBytes(relayBytes + helloStreamBytes)

        let snapshot = events.withLock { $0 }
        XCTAssertTrue(snapshot.contains { event in
            if case .didEncounterError(.unexpected) = event { return true }
            return false
        })
        XCTAssertTrue(snapshot.contains { event in
            if case .didReceiveFrame(.hello) = event { return true }
            return false
        })
        XCTAssertTrue(snapshot.contains { event in
            if case .didChangeState(from: .awaitingHello, to: .active) = event { return true }
            return false
        })
    }
}

// MARK: - Minimal test helpers (scoped to this file)

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

private func fixturesDir() -> URL {
    let here = URL(fileURLWithPath: #filePath)
    return here
        .deletingLastPathComponent() // AethosCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // AethosCore
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Fixtures/Protocol/gossip-v1", isDirectory: true)
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

private final class CancellationThrowingRelayObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    func noteAuthenticatedRelayIngest(itemIDs _: [GossipV1ItemID], nowMs _: UInt64) throws {
        throw CancellationError()
    }
}

private final class RelayIngestValidationErrorSeamObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    let error: GossipV1EncounterEngine.ValidationError

    init(error: GossipV1EncounterEngine.ValidationError) {
        self.error = error
    }

    func noteAuthenticatedRelayIngest(itemIDs _: [GossipV1ItemID], nowMs _: UInt64) throws {
        throw error
    }
}

private struct FixtureError: Swift.Error, Equatable {}

private final class ThrowingRelayObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    let error: any Swift.Error

    init(error: any Swift.Error) {
        self.error = error
    }

    func noteAuthenticatedRelayIngest(itemIDs _: [GossipV1ItemID], nowMs _: UInt64) throws {
        throw error
    }
}
