import Foundation
import XCTest
@testable import AethosCore

final class GossipV1NegativeFixtureVectorsTests: XCTestCase {
    func testNegativeVectors_decodeReencodeDriftGuard_andRejectWithExpectedError() throws {
        let vectors: [Vector] = [
            .expiredTransfer,
            .hopRegression,
            .hashMismatch,
            .oversizeRequest,
            .oversizeTransfer,
            .helloVersionMismatch,
            .oversizeDatagramFrame,
        ]

        for vector in vectors {
            try assertVector(vector)
        }
    }

    func testRelayIngestUnauthenticated_hasNoEffect_andAuthenticatedHasEffect() throws {
        // Fixture decode + drift guard.
        let bytes = try loadFixtureBytes("relay_ingest_unauthenticated.cbor")
        let frame = try GossipV1Frame.decode(bytes: bytes)
        XCTAssertEqual(frame.encode(), bytes)
        guard case .relayIngest(let ingest) = frame else {
            return XCTFail("Expected relay ingest frame")
        }

        let engine = GossipV1EncounterEngine(config: .init(localHello: try makeHello(version: GossipV1.GOSSIP_VERSION)))
        let clock = FixedClock(nowMs: 123)
        let observer = InMemoryRelayIngestObserver()

        let expectedItemIDs = ingest.itemIDs
        let expectedNowMs = clock.nowMs

        try engine.handleRelayIngest(ingest, isAuthenticatedRelayTransport: false, clock: clock, observer: observer)

        // Unauthenticated MUST have zero effect beyond "observer not called".
        // This trust boundary should not throw and should not invoke side-effect hooks.
        XCTAssertEqual(observer.calls, 0)
        XCTAssertEqual(observer.lastItemIDs, nil)
        XCTAssertEqual(observer.lastNowMs, nil)

        // Engine should remain unchanged; relay ingest is a pure trust-boundary hook.
        XCTAssertEqual(engine.state, .awaitingHello)
        XCTAssertEqual(engine.peerCaps, nil)

        try engine.handleRelayIngest(ingest, isAuthenticatedRelayTransport: true, clock: clock, observer: observer)
        XCTAssertEqual(observer.calls, 1)
        XCTAssertEqual(observer.lastItemIDs, expectedItemIDs)
        XCTAssertEqual(observer.lastNowMs, expectedNowMs)
    }
}

// MARK: - Vectors

private extension GossipV1NegativeFixtureVectorsTests {
    enum DriftGuard {
        /// Drift guard at the frame boundary (decode frame -> encode frame).
        case frame
        /// Drift guard at the CBOR boundary (decode canonical CBOR value -> re-encode).
        case canonicalCBOR
        /// No drift guard possible/meaningful (e.g. fixture is not CBOR).
        case none
    }

    struct Vector {
        let fixture: String
        let driftGuard: DriftGuard
        let assertError: (Data) throws -> Void
    }

    func assertVector(_ vector: Vector) throws {
        let bytes = try loadFixtureBytes(vector.fixture)

        switch vector.driftGuard {
        case .frame:
            // Drift guard: decode -> encode matches fixture bytes.
            let decoded = try GossipV1Frame.decode(bytes: bytes)
            XCTAssertEqual(decoded.encode(), bytes)
        case .canonicalCBOR:
            // Drift guard: canonical CBOR decode -> encode matches fixture bytes.
            let value = try CanonicalCBORDecoder().decode(bytes)
            let reencoded = try CanonicalCBOREncoder().encode(value)
            XCTAssertEqual(reencoded, bytes)
        case .none:
            break
        }

        try vector.assertError(bytes)
    }
}

private extension GossipV1NegativeFixtureVectorsTests.Vector {
    static var expiredTransfer: Self {
        .init(
            fixture: "transfer_expired.cbor",
            driftGuard: .frame,
            assertError: { bytes in
                let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
                var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
                let store = InMemoryGossipStore()
                _ = try engine.ingestInboundFrame(.hello(localHello), clock: FixedClock(nowMs: 0), store: store)

                let result = try engine.ingestInboundDatagram(bytes, clock: FixedClock(nowMs: 1000), store: store)
                XCTAssertEqual(result.state, .active)
                let transfer = try GossipV1Framing.decodeDatagram(bytes)
                guard case .transfer(let decoded) = transfer else {
                    return XCTFail("Expected TRANSFER fixture")
                }
                let cutoff = 1000 + GossipV1.CLOCK_SKEW_TOLERANCE_MS
                let expectedAccepted = decoded.objects
                    .filter { cutoff < $0.expiryUnixMs }
                    .map { $0.itemID }
                XCTAssertEqual(result.acceptedTransferItemIDs, expectedAccepted)

                let expectedNonfatal = decoded.objects
                    .filter { cutoff >= $0.expiryUnixMs }
                    .map { GossipV1EncounterEngine.ValidationError.transferExpired(nowUnixMs: 1000, expiryUnixMs: $0.expiryUnixMs) }
                XCTAssertEqual(result.nonfatalValidationErrors, expectedNonfatal)
            }
        )
    }

    static var hopRegression: Self {
        .init(
            fixture: "transfer_hop_regression.cbor",
            driftGuard: .frame,
            assertError: { bytes in
                let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
                var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
                let store = InMemoryGossipStore()
                _ = try engine.ingestInboundFrame(.hello(localHello), clock: FixedClock(nowMs: 0), store: store)
                // Seed store with higher hop count.
                guard let objID = try extractSingleTransferItemID(from: bytes) else {
                    return XCTFail("Expected transfer fixture")
                }
                store.setHopCount(id: objID, hop: 10)

                let result = try engine.ingestInboundDatagram(bytes, clock: FixedClock(nowMs: 0), store: store)
                XCTAssertEqual(result.state, .active)
                let transfer = try GossipV1Framing.decodeDatagram(bytes)
                guard case .transfer(let decoded) = transfer else {
                    return XCTFail("Expected TRANSFER fixture")
                }
                let cutoff = UInt64(0) + GossipV1.CLOCK_SKEW_TOLERANCE_MS
                let expectedNonfatal: [GossipV1EncounterEngine.ValidationError] = decoded.objects.compactMap { obj in
                    if cutoff >= obj.expiryUnixMs {
                        return .transferExpired(nowUnixMs: 0, expiryUnixMs: obj.expiryUnixMs)
                    }
                    if obj.itemID == objID, obj.hopCount < 10 {
                        return .hopRegression(existing: 10, incoming: obj.hopCount)
                    }
                    return nil
                }
                let expectedAccepted: [GossipV1ItemID] = decoded.objects.compactMap { obj in
                    if cutoff >= obj.expiryUnixMs { return nil }
                    if obj.itemID == objID, obj.hopCount < 10 { return nil }
                    return obj.itemID
                }
                XCTAssertEqual(result.acceptedTransferItemIDs, expectedAccepted)
                XCTAssertEqual(result.nonfatalValidationErrors, expectedNonfatal)
            }
        )
    }

    static var hashMismatch: Self {
        .init(
            fixture: "transfer_item_id_hash_mismatch.cbor",
            driftGuard: .canonicalCBOR,
            assertError: { bytes in
                let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
                var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
                let store = InMemoryGossipStore()
                _ = try engine.ingestInboundFrame(.hello(localHello), clock: FixedClock(nowMs: 0), store: store)

                XCTAssertThrowsError(
                    try engine.ingestInboundDatagram(bytes, clock: FixedClock(nowMs: 0), store: store)
                ) { err in
                    XCTAssertEqual(
                        err as? GossipV1FramingError,
                        .invalidDatagramFrame(underlying: .transferItemIDMismatch)
                    )
                }
            }
        )
    }

    static var oversizeRequest: Self {
        .init(
            fixture: "request_oversize.cbor",
            driftGuard: .frame,
            assertError: { bytes in
                let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxWant: 1)
                var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
                let store = InMemoryGossipStore()
                // Peer caps drive inbound REQUEST.want validation.
                let peerHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxWant: 1)
                _ = try engine.ingestInboundFrame(.hello(peerHello), clock: FixedClock(nowMs: 0), store: store)

                XCTAssertThrowsError(
                    try engine.ingestInboundDatagram(bytes, clock: FixedClock(nowMs: 0), store: store)
                ) { err in
                    XCTAssertEqual(
                        err as? GossipV1EncounterEngine.ValidationError,
                        .wantTooManyItems(max: 1, actual: 2)
                    )
                }
            }
        )
    }

    static var oversizeTransfer: Self {
        .init(
            fixture: "transfer_oversize_bytes.cbor",
            driftGuard: .canonicalCBOR,
            assertError: { bytes in
                let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
                var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
                let store = InMemoryGossipStore()
                _ = try engine.ingestInboundFrame(.hello(localHello), clock: FixedClock(nowMs: 0), store: store)

                XCTAssertThrowsError(
                    try engine.ingestInboundDatagram(bytes, clock: FixedClock(nowMs: 0), store: store)
                ) { err in
                    // This fixture intentionally exceeds MAX_TRANSFER_BYTES at the frame decoding boundary.
                    // Engine ingest should therefore fail inside framing, before engine-level validation.
                    XCTAssertEqual(
                        err as? GossipV1FramingError,
                        .invalidDatagramFrame(
                            underlying: .transferTotalEnvelopeBytesTooLarge(max: GossipV1.MAX_TRANSFER_BYTES, actual: 524_395)
                        )
                    )
                }
            }
        )
    }

    static var helloVersionMismatch: Self {
        .init(
            fixture: "hello_version_mismatch.cbor",
            driftGuard: .frame,
            assertError: { bytes in
                let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
                var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
                let store = InMemoryGossipStore()

                XCTAssertThrowsError(
                    try engine.ingestInboundDatagram(bytes, clock: FixedClock(nowMs: 0), store: store)
                ) { err in
                    XCTAssertEqual(
                        err as? GossipV1EncounterEngine.ValidationError,
                        .invalidHelloVersion(expected: GossipV1.GOSSIP_VERSION, actual: GossipV1.GOSSIP_VERSION + 1)
                    )
                }
                XCTAssertEqual(
                    engine.state,
                    .terminated(reason: .helloVersionMismatch(expected: GossipV1.GOSSIP_VERSION, actual: GossipV1.GOSSIP_VERSION + 1))
                )
            }
        )
    }

    static var oversizeDatagramFrame: Self {
        .init(
            fixture: "datagram_frame_too_large.cbor",
            driftGuard: .none,
            assertError: { bytes in
                XCTAssertEqual(bytes.count, GossipV1.MAX_FRAME_BYTES + 1)
                XCTAssertThrowsError(try GossipV1Framing.decodeDatagramFrame(bytes)) { err in
                    XCTAssertEqual(
                        err as? GossipV1FramingError,
                        .frameTooLarge(max: GossipV1.MAX_FRAME_BYTES, actual: GossipV1.MAX_FRAME_BYTES + 1)
                    )
                }
            }
        )
    }
}

// MARK: - Fixture loading

private extension GossipV1NegativeFixtureVectorsTests {
    func loadFixtureBytes(_ name: String) throws -> Data {
        // Avoid storing multi-megabyte fixtures in-repo.
        // Keep the JSON fixture as the vector definition; generate bytes deterministically in tests.
        if name == "datagram_frame_too_large.cbor" {
            return Data(repeating: 0x00, count: GossipV1.MAX_FRAME_BYTES + 1)
        }
        return try GossipV1TestSupport.fixtureData(name)
    }
}

// MARK: - Minimal engine/store helpers (test-only)

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
    private struct Stored: Sendable {
        let envelopeBytes: Data
        let expiryUnixMs: UInt64
        let hopCount: UInt16
    }

    private var storedByID: [GossipV1ItemID: Stored] = [:]
    private var eligible: [GossipV1ItemID] = []

    func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { eligible }

    func fetch(_ itemID: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? {
        guard let stored = storedByID[itemID] else { return nil }
        return (stored.envelopeBytes, stored.expiryUnixMs, stored.hopCount)
    }

    func existingHopCount(_ itemID: GossipV1ItemID) throws -> UInt16? {
        storedByID[itemID]?.hopCount
    }

    func ingest(_ itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) throws {
        if let existing = storedByID[itemID], hopCount < existing.hopCount {
            throw GossipV1EncounterEngine.ValidationError.hopRegression(existing: existing.hopCount, incoming: hopCount)
        }
        storedByID[itemID] = Stored(envelopeBytes: envelopeBytes, expiryUnixMs: expiryUnixMs, hopCount: hopCount)
    }

    func setHopCount(id: GossipV1ItemID, hop: UInt16) {
        if let existing = storedByID[id] {
            storedByID[id] = Stored(envelopeBytes: existing.envelopeBytes, expiryUnixMs: existing.expiryUnixMs, hopCount: hop)
            return
        }
        storedByID[id] = Stored(envelopeBytes: Data(), expiryUnixMs: 4_102_444_800_000, hopCount: hop)
    }
}

private final class InMemoryRelayIngestObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    private(set) var calls: Int = 0
    private(set) var lastItemIDs: [GossipV1ItemID]?
    private(set) var lastNowMs: UInt64?

    func noteAuthenticatedRelayIngest(itemIDs: [GossipV1ItemID], nowMs: UInt64) throws {
        calls += 1
        lastItemIDs = itemIDs
        lastNowMs = nowMs
    }
}

private func extractSingleTransferItemID(from transferDatagram: Data) throws -> GossipV1ItemID? {
    let frame = try GossipV1Framing.decodeDatagram(transferDatagram)
    guard case .transfer(let transfer) = frame else { return nil }
    return transfer.objects.first?.itemID
}
