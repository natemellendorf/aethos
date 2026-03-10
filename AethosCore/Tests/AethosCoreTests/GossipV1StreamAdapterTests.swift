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
