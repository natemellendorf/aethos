import Foundation
import Testing
@testable import AethosCore

@Test
func gossipV1_engine_requiresHelloFirst_andFailsClosedOnVersionMismatch() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()

    let summary = try GossipV1SummaryFrame(bloomFilter: Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES), itemCount: 0)
    #expect(throws: GossipV1EncounterEngine.ValidationError.helloRequiredFirst) {
        _ = try engine.ingestInboundFrame(.summary(summary), clock: clock, store: store)
    }

    // Version mismatch should terminate encounter and stop processing.
    // HELLO must still be decodable so the engine (not framing) can fail-closed.
    // Outbound HELLO construction is strict, so craft the mismatch at the CBOR level.
    let badHelloDatagram = try makeHelloDatagramWithVersion(GossipV1.GOSSIP_VERSION + 1)

    // First, assert that framing/decoding is permissive and yields a HELLO with a mismatched version.
    let decodedBadHelloFrame = try GossipV1Framing.decodeDatagram(badHelloDatagram)
    guard case .hello(let decodedBadHello) = decodedBadHelloFrame else {
        throw GossipV1EncounterEngineConformanceTestError.expectedHello
    }
    #expect(decodedBadHello.version != GossipV1.GOSSIP_VERSION)
    #expect(decodedBadHello.version == GossipV1.GOSSIP_VERSION + 1)

    #expect(throws: GossipV1EncounterEngine.ValidationError.invalidHelloVersion(expected: GossipV1.GOSSIP_VERSION, actual: GossipV1.GOSSIP_VERSION + 1)) {
        _ = try engine.ingestInboundDatagram(badHelloDatagram, clock: clock, store: store)
    }
    #expect(engine.state == .terminated(reason: .helloVersionMismatch(expected: GossipV1.GOSSIP_VERSION, actual: GossipV1.GOSSIP_VERSION + 1)))

    #expect(throws: GossipV1EncounterEngine.ValidationError.encounterTerminated) {
        _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)
    }
}

@Test
func gossipV1_engine_inboundRequest_duplicateItemIDs_rejectedAtFrameInitBoundary() throws {
    let id = try GossipV1ItemID(bytes: Data(repeating: 0x01, count: 32))
    #expect(throws: GossipV1FrameError.duplicateItemID) {
        _ = try GossipV1RequestFrame(want: [id, id])
    }
}

@Test
func gossipV1_engine_inboundRequest_invalidItemIDHex_rejectedAtFrameDecodeBoundary() throws {
    // Build a non-canonical REQUEST payload with an invalid want item_id.
    let payload: CanonicalCBORValue = .map([
        .init(key: .text("want"), value: .array([.text("not-hex")]))
    ])
    let bytes = try CanonicalCBOREncoder().encode(
        .map([
            .init(key: .text("type"), value: .text(GossipV1FrameType.REQUEST.rawValue)),
            .init(key: .text("payload"), value: payload),
        ])
    )

    #expect(throws: GossipV1FrameError.invalidScalar(field: "want", underlying: .invalidHexDigest(expectedChars: 64, actualChars: 7))) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_engine_inboundRequest_emptyWant_isValidNoOp_andProducesNoOutboundTransfer() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)

    let request = try GossipV1RequestFrame(want: [])
    let result = try engine.ingestInboundFrame(.request(request), clock: clock, store: store)
    #expect(result.outbound.isEmpty)
    #expect(result.acceptedTransferItemIDs.isEmpty)
    #expect(result.receiptEligibleItemIDs.isEmpty)
    #expect(result.acknowledgedTransferItemIDs.isEmpty)
    #expect(result.nonfatalValidationErrors.isEmpty)
}

@Test
func gossipV1_engine_expirySkew_allowsJustBeyondCutoff_andRejectsAtBoundary() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let store = InMemoryGossipStore()
    let now: UInt64 = 1_000
    let clock = FixedClock(nowMs: now)
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: FixedClock(nowMs: 0), store: store)

    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(7))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    let boundary = now + GossipV1.CLOCK_SKEW_TOLERANCE_MS

    let okObj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: boundary + 1, hopCount: 0)
    let okTransfer = try GossipV1TransferFrame(objects: [okObj])
    let okResult = try engine.ingestInboundFrame(.transfer(okTransfer), clock: clock, store: store)
    #expect(okResult.acceptedTransferItemIDs == [id])
    #expect(okResult.receiptEligibleItemIDs == [id])
    #expect(okResult.acknowledgedTransferItemIDs.isEmpty)

    // At the boundary, cutoff >= expiry rejects.
    let badObj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: boundary, hopCount: 0)
    let badTransfer = GossipV1TransferFrame(unsafeObjects: [badObj])
    let badResult = try engine.ingestInboundFrame(.transfer(badTransfer), clock: clock, store: store)
    #expect(badResult.acceptedTransferItemIDs.isEmpty)
    #expect(badResult.receiptEligibleItemIDs.isEmpty)
    #expect(badResult.acknowledgedTransferItemIDs.isEmpty)
    #expect(badResult.nonfatalValidationErrors == [.transferExpired(nowUnixMs: now, expiryUnixMs: boundary)])
}

private enum GossipV1EncounterEngineConformanceTestError: Swift.Error {
    case expectedHello
}

@Test
func gossipV1_engine_rejectsTransferItemIdMismatch() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)

    // Build object with mismatched item_id (frame init should throw).
    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let wrongID = try GossipV1ItemID(bytes: Data(repeating: 0x11, count: 32))
    #expect(throws: GossipV1FrameError.transferItemIDMismatch) {
        _ = try GossipV1TransferFrame.Object(itemID: wrongID, envelopeBytes: envBytes, expiryUnixMs: 4_102_444_800_000, hopCount: 0)
    }
}

@Test
func gossipV1_engine_enforcesExpirySkewBoundary_30000ms() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let store = InMemoryGossipStore()
    let now: UInt64 = 1_000
    let clock = FixedClock(nowMs: now)
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: FixedClock(nowMs: 0), store: store)

    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    let expiry = now + GossipV1.CLOCK_SKEW_TOLERANCE_MS // cutoff >= expiry rejects.
    let obj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
    let transfer = try GossipV1TransferFrame(objects: [obj])

    let result = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    #expect(result.acceptedTransferItemIDs.isEmpty)
    #expect(result.receiptEligibleItemIDs.isEmpty)
    #expect(result.acknowledgedTransferItemIDs.isEmpty)
    #expect(result.nonfatalValidationErrors == [.transferExpired(nowUnixMs: now, expiryUnixMs: expiry)])
}

@Test
func gossipV1_engine_rejectsHopRegression_usingStoreQuery() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)

    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(2))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    store.setHopCount(id: id, hop: 10)
    let obj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: 4_102_444_800_000, hopCount: 9)
    let transfer = try GossipV1TransferFrame(objects: [obj])

    let result = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    #expect(result.acceptedTransferItemIDs.isEmpty)
    #expect(result.receiptEligibleItemIDs.isEmpty)
    #expect(result.acknowledgedTransferItemIDs.isEmpty)
    #expect(result.nonfatalValidationErrors == [.hopRegression(existing: 10, incoming: 9)])
}

@Test
func gossipV1_engine_rejectsOversizeRequest_andOversizeTransferBytes() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxWant: 128)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()
    let peerHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxWant: 2)
    _ = try engine.ingestInboundFrame(.hello(peerHello), clock: clock, store: store)

    let ids = try (0..<3).map { i in try GossipV1ItemID(bytes: Data(repeating: UInt8(i), count: 32)) }
    let sorted = ids.sorted(by: { DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending })
    let request = try GossipV1RequestFrame(want: sorted)
    #expect(throws: GossipV1EncounterEngine.ValidationError.wantTooManyItems(max: 2, actual: 3)) {
        _ = try engine.ingestInboundFrame(.request(request), clock: clock, store: store)
    }

    // Transfer oversize (construct objects directly to bypass decoder enforcement).
    let bigPayload = Data(repeating: 0xAA, count: GossipV1.MAX_TRANSFER_BYTES + 1)
    let bigEnvelopeBytes = try CanonicalCBOREncoder().encode(.bytes(bigPayload))
    let actual = bigEnvelopeBytes.count
    let bigID = GossipV1ItemID.derive(fromEnvelopeBytes: bigEnvelopeBytes)
    let obj = try GossipV1TransferFrame.Object(itemID: bigID, envelopeBytes: bigEnvelopeBytes, expiryUnixMs: 4_102_444_800_000, hopCount: 0)
    #expect(throws: GossipV1FrameError.transferTotalEnvelopeBytesTooLarge(max: GossipV1.MAX_TRANSFER_BYTES, actual: actual)) {
        _ = try GossipV1TransferFrame(objects: [obj])
    }
}

@Test
func gossipV1_engine_inboundTransfer_rejectsTooManyObjects_andRejectsOversizeSum_withoutPartialIngest() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxTransfer: 2)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)

    final class RecordingStore: @unchecked Sendable, GossipV1EncounterEngine.Store {
        private(set) var ingestCallCount = 0
        func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { [] }
        func fetch(_: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? { nil }
        func existingHopCount(_: GossipV1ItemID) throws -> UInt16? { nil }
        func ingest(_: GossipV1ItemID, envelopeBytes _: Data, expiryUnixMs _: UInt64, hopCount _: UInt16) throws {
            ingestCallCount += 1
        }
    }
    let store = RecordingStore()

    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)

    let expiry: UInt64 = 4_102_444_800_000
    let objs: [GossipV1TransferFrame.Object] = try (0..<3).map { i in
        let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(UInt64(i)))]))
        let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
        return try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
    }
    let transferTooMany = try GossipV1TransferFrame(objects: objs)
    #expect(throws: GossipV1EncounterEngine.ValidationError.transferTooManyObjects(max: 2, actual: 3)) {
        _ = try engine.ingestInboundFrame(.transfer(transferTooMany), clock: clock, store: store)
    }
    #expect(store.ingestCallCount == 0)

    // Oversize sum: bypass frame-level enforcement by using unsafeObjects.
    let bigPayload = Data(repeating: 0xAA, count: GossipV1.MAX_TRANSFER_BYTES / 2 + 16)
    let env1 = try CanonicalCBOREncoder().encode(.bytes(bigPayload))
    let env2 = try CanonicalCBOREncoder().encode(.bytes(bigPayload))
    let id1 = GossipV1ItemID.derive(fromEnvelopeBytes: env1)
    let id2 = GossipV1ItemID.derive(fromEnvelopeBytes: env2)
    let o1 = try GossipV1TransferFrame.Object(itemID: id1, envelopeBytes: env1, expiryUnixMs: expiry, hopCount: 0)
    let o2 = try GossipV1TransferFrame.Object(itemID: id2, envelopeBytes: env2, expiryUnixMs: expiry, hopCount: 0)
    let oversize = GossipV1TransferFrame(unsafeObjects: [o1, o2])
    let expectedActualBytes = env1.count + env2.count
    #expect(throws: GossipV1EncounterEngine.ValidationError.transferOversize(maxBytes: GossipV1.MAX_TRANSFER_BYTES, actualBytes: expectedActualBytes)) {
        _ = try engine.ingestInboundFrame(.transfer(oversize), clock: clock, store: store)
    }
    #expect(store.ingestCallCount == 0)
}

@Test
func gossipV1_engine_inboundTransfer_validationIsAllOrNothing_noPartialIngestOnDeterministicViolation() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

    final class RecordingStore: @unchecked Sendable, GossipV1EncounterEngine.Store {
        private(set) var ingestedItemIDs: [GossipV1ItemID] = []
        private var hopByID: [GossipV1ItemID: UInt16] = [:]

        func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { [] }
        func fetch(_: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? { nil }
        func existingHopCount(_ itemID: GossipV1ItemID) throws -> UInt16? { hopByID[itemID] }
        func ingest(_ itemID: GossipV1ItemID, envelopeBytes _: Data, expiryUnixMs _: UInt64, hopCount: UInt16) throws {
            if let existing = hopByID[itemID], hopCount < existing {
                throw GossipV1EncounterEngine.ValidationError.hopRegression(existing: existing, incoming: hopCount)
            }
            hopByID[itemID] = hopCount
            ingestedItemIDs.append(itemID)
        }
    }

    let clock = FixedClock(nowMs: 1_000)
    let store = RecordingStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: FixedClock(nowMs: 0), store: store)

    let expiryOk: UInt64 = 1_000 + GossipV1.CLOCK_SKEW_TOLERANCE_MS + 1
    let expiryBad: UInt64 = 1_000 + GossipV1.CLOCK_SKEW_TOLERANCE_MS

    let envA = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let envB = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(2))]))
    let idA = GossipV1ItemID.derive(fromEnvelopeBytes: envA)
    let idB = GossipV1ItemID.derive(fromEnvelopeBytes: envB)

    let ok = try GossipV1TransferFrame.Object(itemID: idA, envelopeBytes: envA, expiryUnixMs: expiryOk, hopCount: 0)
    let expired = try GossipV1TransferFrame.Object(itemID: idB, envelopeBytes: envB, expiryUnixMs: expiryBad, hopCount: 0)
    let transfer = GossipV1TransferFrame(unsafeObjects: [ok, expired])

    // Spec: mixed validity TRANSFER is allowed; expired objects are rejected non-fatally and
    // valid objects are still ingested.
    let result = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    #expect(result.acceptedTransferItemIDs == [idA])
    #expect(result.receiptEligibleItemIDs == [idA])
    #expect(result.acknowledgedTransferItemIDs.isEmpty)
    #expect(store.ingestedItemIDs == [idA])
    #expect(result.nonfatalValidationErrors == [.transferExpired(nowUnixMs: 1_000, expiryUnixMs: expiryBad)])
}

@Test
func gossipV1_engine_inboundTransfer_acceptsHopEqual_asIdempotent() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

    final class HopTrackingStore: @unchecked Sendable, GossipV1EncounterEngine.Store {
        private var hopByID: [GossipV1ItemID: UInt16] = [:]
        private(set) var ingestCountByID: [GossipV1ItemID: Int] = [:]

        func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { [] }
        func fetch(_: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? { nil }
        func existingHopCount(_ itemID: GossipV1ItemID) throws -> UInt16? { hopByID[itemID] }

        func ingest(_ itemID: GossipV1ItemID, envelopeBytes _: Data, expiryUnixMs _: UInt64, hopCount: UInt16) throws {
            if let existing = hopByID[itemID], hopCount < existing {
                throw GossipV1EncounterEngine.ValidationError.hopRegression(existing: existing, incoming: hopCount)
            }
            hopByID[itemID] = hopCount
            ingestCountByID[itemID, default: 0] += 1
        }

        func seedHop(_ itemID: GossipV1ItemID, hop: UInt16) {
            hopByID[itemID] = hop
        }
    }

    let store = HopTrackingStore()
    let clock = FixedClock(nowMs: 1_000)
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: FixedClock(nowMs: 0), store: store)

    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(77))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    store.seedHop(id, hop: 5)

    let expiry: UInt64 = 1_000 + GossipV1.CLOCK_SKEW_TOLERANCE_MS + 1
    let obj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 5)
    let transfer = try GossipV1TransferFrame(objects: [obj])
    let result = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    #expect(result.acceptedTransferItemIDs == [id])
    #expect(result.receiptEligibleItemIDs == [id])
    #expect(result.acknowledgedTransferItemIDs.isEmpty)
    #expect(store.ingestCountByID[id] == 1)
}

@Test
func gossipV1_transferObject_decodeRejectsHopCountOverflow() throws {
    let idHex = String(repeating: "0", count: 64)
    let payload: CanonicalCBORValue = .map([
        .init(key: .text("objects"), value: .array([
            .map([
                .init(key: .text("item_id"), value: .text(idHex)),
                .init(key: .text("envelope_b64"), value: .text("AA")),
                .init(key: .text("expiry_unix_ms"), value: .unsigned(0)),
                .init(key: .text("hop_count"), value: .unsigned(UInt64(UInt16.max) + 1)),
            ]),
        ])),
    ])
    let bytes = try CanonicalCBOREncoder().encode(
        .map([
            .init(key: .text("type"), value: .text(GossipV1FrameType.TRANSFER.rawValue)),
            .init(key: .text("payload"), value: payload),
        ])
    )
    #expect(throws: GossipV1FrameError.invalidRange(field: "hop_count")) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_transferObject_decodeRejectsInvalidBase64URLAlphabet() throws {
    let idHex = String(repeating: "0", count: 64)
    let payload: CanonicalCBORValue = .map([
        .init(key: .text("objects"), value: .array([
            .map([
                .init(key: .text("item_id"), value: .text(idHex)),
                .init(key: .text("envelope_b64"), value: .text("**")),
                .init(key: .text("expiry_unix_ms"), value: .unsigned(0)),
                .init(key: .text("hop_count"), value: .unsigned(0)),
            ]),
        ])),
    ])
    let bytes = try CanonicalCBOREncoder().encode(
        .map([
            .init(key: .text("type"), value: .text(GossipV1FrameType.TRANSFER.rawValue)),
            .init(key: .text("payload"), value: payload),
        ])
    )
    #expect(throws: GossipV1FrameError.invalidScalar(field: "envelope_b64", underlying: .invalidBase64URLAlphabet)) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_transferObject_decodeRejectsItemIDMismatch() throws {
    // "AA" decodes to a single 0x00 byte, so the derived item_id cannot be all zeros.
    let idHex = String(repeating: "0", count: 64)
    let payload: CanonicalCBORValue = .map([
        .init(key: .text("objects"), value: .array([
            .map([
                .init(key: .text("item_id"), value: .text(idHex)),
                .init(key: .text("envelope_b64"), value: .text("AA")),
                .init(key: .text("expiry_unix_ms"), value: .unsigned(0)),
                .init(key: .text("hop_count"), value: .unsigned(0)),
            ]),
        ])),
    ])
    let bytes = try CanonicalCBOREncoder().encode(
        .map([
            .init(key: .text("type"), value: .text(GossipV1FrameType.TRANSFER.rawValue)),
            .init(key: .text("payload"), value: payload),
        ])
    )
    #expect(throws: GossipV1FrameError.transferItemIDMismatch) {
        _ = try GossipV1Frame.decode(bytes: bytes)
    }
}

@Test
func gossipV1_engine_capsInboundRequestWant_byPeerHelloMaxWant() throws {
    // Inbound REQUEST.want is capped by the peer's HELLO `max_want` (hard-ceilinged by
    // MAX_WANT_ITEMS).
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxWant: 128)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()

    // Deliberately make peer max_want smaller than local.
    // If the engine incorrectly uses local caps for inbound REQUEST validation, this test would not throw.
    let peerHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxWant: 1)
    _ = try engine.ingestInboundFrame(.hello(peerHello), clock: clock, store: store)

    let ids = try (0..<2).map { i in try GossipV1ItemID(bytes: Data(repeating: UInt8(i), count: 32)) }
    let sorted = ids.sorted(by: { DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending })
    let request = try GossipV1RequestFrame(want: sorted)
    #expect(throws: GossipV1EncounterEngine.ValidationError.wantTooManyItems(max: 1, actual: 2)) {
        _ = try engine.ingestInboundFrame(.request(request), clock: clock, store: store)
    }
}

@Test
func gossipV1_summaryDatagram_isDeterministic_forFixedEligibleSet() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()

    // Fixed eligible item set.
    let expiry: UInt64 = 4_102_444_800_000
    let envA = try CanonicalCBOREncoder().encode(.map([.init(key: .text("a"), value: .unsigned(1))]))
    let envB = try CanonicalCBOREncoder().encode(.map([.init(key: .text("b"), value: .unsigned(2))]))
    let envC = try CanonicalCBOREncoder().encode(.map([.init(key: .text("c"), value: .unsigned(3))]))
    let idA = GossipV1ItemID.derive(fromEnvelopeBytes: envA)
    let idB = GossipV1ItemID.derive(fromEnvelopeBytes: envB)
    let idC = GossipV1ItemID.derive(fromEnvelopeBytes: envC)

    store.put(itemID: idA, envelopeBytes: envA, expiryUnixMs: expiry, hopCount: 0)
    store.put(itemID: idB, envelopeBytes: envB, expiryUnixMs: expiry, hopCount: 0)
    store.put(itemID: idC, envelopeBytes: envC, expiryUnixMs: expiry, hopCount: 0)
    store.setEligible([idC, idA, idB])

    let frame = try engine.buildSummary(clock: clock, store: store)
    let bytes = frame.encode()

    // Fixture vector: canonical CBOR bytes for the SUMMARY datagram.
    // This MUST change if bloom hashing, item_count encoding, or canonical key ordering changes.
    let expected = try #require(Data(base64Encoded: "omR0eXBlZ1NVTU1BUllncGF5bG9hZKJqaXRlbV9jb3VudANsYmxvb21fZmlsdGVyWQgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
    #expect(bytes == expected)
}

@Test
func gossipV1_engine_enforcesPeerHelloMaxWant_onOutboundBuildRequest() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxWant: 128)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()

    let peerHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxWant: 1)
    _ = try engine.ingestInboundFrame(.hello(peerHello), clock: clock, store: store)

    let ids = try (0..<2).map { i in try GossipV1ItemID(bytes: Data(repeating: UInt8(i), count: 32)) }
        .sorted(by: { DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending })
    #expect(throws: GossipV1EncounterEngine.ValidationError.wantTooManyItems(max: 1, actual: 2)) {
        _ = try engine.buildRequest(want: ids)
    }
}

@Test
func gossipV1_engine_buildRequest_throwsHelloRequiredFirst_beforeAnyHello() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

    let id = try GossipV1ItemID(bytes: Data(repeating: 0x01, count: 32))
    #expect(throws: GossipV1EncounterEngine.ValidationError.helloRequiredFirst) {
        _ = try engine.buildRequest(want: [id])
    }
}

@Test
func gossipV1_engine_buildRequest_throwsPeerCapsUnknown_afterHelloButBeforePeerHello() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    let engine = GossipV1EncounterEngine(_testing: .init(localHello: localHello), state: .active, peerCaps: nil)

    let id = try GossipV1ItemID(bytes: Data(repeating: 0x02, count: 32))
    #expect(throws: GossipV1EncounterEngine.ValidationError.peerCapsUnknown) {
        _ = try engine.buildRequest(want: [id])
    }
}

@Test
func gossipV1_engine_buildTransfer_throwsHelloRequiredFirst_beforeAnyHello() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    let obj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: 4_102_444_800_000, hopCount: 0)

    #expect(throws: GossipV1EncounterEngine.ValidationError.helloRequiredFirst) {
        _ = try engine.buildTransfer(objects: [obj])
    }
}

@Test
func gossipV1_engine_buildTransfer_throwsPeerCapsUnknown_afterHelloButBeforePeerHello() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(_testing: .init(localHello: localHello), state: .active, peerCaps: nil)

    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(2))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    let obj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: 4_102_444_800_000, hopCount: 0)

    #expect(throws: GossipV1EncounterEngine.ValidationError.peerCapsUnknown) {
        _ = try engine.buildTransfer(objects: [obj])
    }
}

@Test
func gossipV1_engine_enforcesLocalHelloMaxTransfer_onInboundTransfer() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxTransfer: 2)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)

    let expiry: UInt64 = 4_102_444_800_000
    let objs: [GossipV1TransferFrame.Object] = try (0..<3).map { i in
        let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(UInt64(i)))]))
        let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
        return try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
    }
    let transfer = try GossipV1TransferFrame(objects: objs)

    #expect(throws: GossipV1EncounterEngine.ValidationError.transferTooManyObjects(max: 2, actual: 3)) {
        _ = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    }
}

@Test
func gossipV1_engine_enforcesPeerHelloMaxTransfer_onOutboundBuildTransfer() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxTransfer: UInt64(GossipV1.MAX_TRANSFER_ITEMS))
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()

    let peerHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxTransfer: 1)
    _ = try engine.ingestInboundFrame(.hello(peerHello), clock: clock, store: store)

    let expiry: UInt64 = 4_102_444_800_000
    let objs: [GossipV1TransferFrame.Object] = try (0..<2).map { i in
        let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(UInt64(i)))]))
        let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
        return try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
    }

    #expect(throws: GossipV1EncounterEngine.ValidationError.transferTooManyObjects(max: 1, actual: 2)) {
        _ = try engine.buildTransfer(objects: objs)
    }
}

@Test
func gossipV1_engine_rejectsInboundTransferTotalEnvelopeBytesOverMax_atEngineLevel() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION, maxTransfer: 2)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)

    // Bypass GossipV1TransferFrame.init envelope byte cap by constructing a transfer with two
    // objects that are each <= MAX_TRANSFER_BYTES but sum to > MAX_TRANSFER_BYTES.
    let perObject = GossipV1.MAX_TRANSFER_BYTES / 2 + 1
    let expiry: UInt64 = 4_102_444_800_000

    func makeObject(seed: UInt8) throws -> GossipV1TransferFrame.Object {
        let envBytes = try CanonicalCBOREncoder().encode(.bytes(Data(repeating: seed, count: perObject)))
        let id = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
        return try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
    }

    let o1 = try makeObject(seed: 0x01)
    let o2 = try makeObject(seed: 0x02)
    let transfer = GossipV1TransferFrame(unsafeObjects: [o1, o2])

    #expect(throws: GossipV1EncounterEngine.ValidationError.transferOversize(maxBytes: GossipV1.MAX_TRANSFER_BYTES, actualBytes: (o1.envelopeBytes.count + o2.envelopeBytes.count))) {
        _ = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    }
}

@Test
func gossipV1_engine_doesNotForwardHopOverflowedItems() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()

    let peerHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    _ = try engine.ingestInboundFrame(.hello(peerHello), clock: clock, store: store)

    let expiry: UInt64 = 4_102_444_800_000
    let envBytes1 = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let envBytes2 = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(2))]))
    let idForwardable = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes1)
    let idOverflow = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes2)

    store.put(itemID: idForwardable, envelopeBytes: envBytes1, expiryUnixMs: expiry, hopCount: 0)
    store.put(itemID: idOverflow, envelopeBytes: envBytes2, expiryUnixMs: expiry, hopCount: .max)

    let sorted = [idForwardable, idOverflow].sorted(by: { DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending })
    let request = try GossipV1RequestFrame(want: sorted)
    let result = try engine.ingestInboundFrame(.request(request), clock: clock, store: store)

    #expect(result.outbound.count == 1)
    guard case .transfer(let transfer) = result.outbound.first else {
        return #expect(Bool(false), "expected transfer outbound")
    }
    #expect(transfer.objects.count == 1)
    #expect(transfer.objects.first?.itemID == idForwardable)
    #expect(transfer.objects.first?.hopCount == 1)
}

@Test
func gossipV1_engine_doesNotForwardExpiredItems_evenIfRequested() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 1_000)
    let store = InMemoryGossipStore()

    let peerHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    _ = try engine.ingestInboundFrame(.hello(peerHello), clock: FixedClock(nowMs: 0), store: store)

    let envBytesExpired = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(9))]))
    let idExpired = GossipV1ItemID.derive(fromEnvelopeBytes: envBytesExpired)

    // Boundary: cutoff >= expiry rejects. So expiry = now + skew is expired.
    let expiryExpired = clock.nowMs + GossipV1.CLOCK_SKEW_TOLERANCE_MS
    store.put(itemID: idExpired, envelopeBytes: envBytesExpired, expiryUnixMs: expiryExpired, hopCount: 0)

    let request = try GossipV1RequestFrame(want: [idExpired])
    let result = try engine.ingestInboundFrame(.request(request), clock: clock, store: store)
    #expect(result.outbound.isEmpty)
}

@Test
func gossipV1_engine_happyPathCycle_summary_request_transfer_receipt() throws {
    // A (sender) has one eligible item.
    let helloA = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engineA = GossipV1EncounterEngine(config: .init(localHello: helloA))
    let storeA = InMemoryGossipStore()

    let expiry: UInt64 = 4_102_444_800_000
    let envBytes = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(42))]))
    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes)
    storeA.put(itemID: itemID, envelopeBytes: envBytes, expiryUnixMs: expiry, hopCount: 0)
    storeA.setEligible([itemID])

    // B (receiver) is active.
    let helloB = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engineB = GossipV1EncounterEngine(config: .init(localHello: helloB))
    let storeB = InMemoryGossipStore()

    let clock = FixedClock(nowMs: 0)

    // HELLO exchange.
    _ = try engineA.ingestInboundFrame(.hello(helloB), clock: clock, store: storeA)
    _ = try engineB.ingestInboundFrame(.hello(helloA), clock: clock, store: storeB)

    // SUMMARY from A.
    _ = try engineA.buildSummary(clock: clock, store: storeA)

    // REQUEST from B (bounded by A's caps).
    let request = try engineB.buildRequest(want: [itemID])
    let transferResult = try engineA.ingestInboundFrame(request, clock: clock, store: storeA)
    #expect(transferResult.outbound.count == 1)
    guard case .transfer(let transfer) = transferResult.outbound.first else {
        return #expect(Bool(false), "expected transfer outbound")
    }
    #expect(transfer.objects.count == 1)
    #expect(transfer.objects.first?.itemID == itemID)
    #expect(transfer.objects.first?.hopCount == 1)

    // TRANSFER from A.
    let receiptResult = try engineB.ingestInboundFrame(.transfer(transfer), clock: clock, store: storeB)
    #expect(receiptResult.acceptedTransferItemIDs == [itemID])
    #expect(receiptResult.receiptEligibleItemIDs == [itemID])
    #expect(receiptResult.acknowledgedTransferItemIDs.isEmpty)
    #expect(receiptResult.outbound.count == 1)
    guard case .receipt(let receipt) = receiptResult.outbound.first else {
        return #expect(Bool(false), "expected receipt outbound")
    }
    #expect(receipt.received == [itemID])

    // RECEIPT from B.
    let ackResult = try engineA.ingestInboundFrame(.receipt(receipt), clock: clock, store: storeA)
    #expect(ackResult.acknowledgedTransferItemIDs == [itemID])
    #expect(ackResult.acceptedTransferItemIDs.isEmpty)
    #expect(ackResult.receiptEligibleItemIDs.isEmpty)
}

@Test
func gossipV1_engine_enforcesReceiptSubsetRule() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)

    // Seed last outbound transfer ids.
    let envBytes1 = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let envBytes2 = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(2))]))
    let id1 = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes1)
    let id2 = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes2)
    let expiry: UInt64 = 4_102_444_800_000
    let o1 = try GossipV1TransferFrame.Object(itemID: id1, envelopeBytes: envBytes1, expiryUnixMs: expiry, hopCount: 0)
    let o2 = try GossipV1TransferFrame.Object(itemID: id2, envelopeBytes: envBytes2, expiryUnixMs: expiry, hopCount: 0)
    _ = try engine.buildTransfer(objects: [o1, o2])

    let other = try GossipV1ItemID(bytes: Data(repeating: 0xFF, count: 32))
    let receipt = try GossipV1ReceiptFrame(received: [id1, other])
    #expect(throws: GossipV1EncounterEngine.ValidationError.receiptNotSubsetOfLastTransfer) {
        _ = try engine.ingestInboundFrame(.receipt(receipt), clock: clock, store: store)
    }
}

@Test
func gossipV1_relayIngest_unauthenticated_hasNoEffect() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let observer = InMemoryRelayIngestObserver()

    let a = try GossipV1ItemID(bytes: Data(repeating: 0xAA, count: 32))
    let ingest = try GossipV1RelayIngestFrame(itemIDs: [a])

    try engine.handleRelayIngest(ingest, isAuthenticatedRelayTransport: false, clock: clock, observer: observer)
    #expect(observer.calls == 0)
}

@Test
func gossipV1_relayIngest_authenticated_callsObserver() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    let engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 123)
    let observer = InMemoryRelayIngestObserver()

    let a = try GossipV1ItemID(bytes: Data(repeating: 0xAA, count: 32))
    let ingest = try GossipV1RelayIngestFrame(itemIDs: [a])

    try engine.handleRelayIngest(ingest, isAuthenticatedRelayTransport: true, clock: clock, observer: observer)
    #expect(observer.calls == 1)
}

@Test
func gossipV1_engine_receiptMustBeForImmediatelyPrecedingOutboundTransfer() throws {
    let localHello = try makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = FixedClock(nowMs: 0)
    let store = InMemoryGossipStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)

    let envBytes1 = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let envBytes2 = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(2))]))
    let id1 = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes1)
    let id2 = GossipV1ItemID.derive(fromEnvelopeBytes: envBytes2)
    let expiry: UInt64 = 4_102_444_800_000
    let o1 = try GossipV1TransferFrame.Object(itemID: id1, envelopeBytes: envBytes1, expiryUnixMs: expiry, hopCount: 0)
    let o2 = try GossipV1TransferFrame.Object(itemID: id2, envelopeBytes: envBytes2, expiryUnixMs: expiry, hopCount: 0)
    _ = try engine.buildTransfer(objects: [o1, o2])

    let receipt = try GossipV1ReceiptFrame(received: [id1])
    _ = try engine.ingestInboundFrame(.receipt(receipt), clock: clock, store: store)

    #expect(throws: GossipV1EncounterEngine.ValidationError.receiptWithoutPrecedingTransfer) {
        _ = try engine.ingestInboundFrame(.receipt(receipt), clock: clock, store: store)
    }
}

// MARK: - Helpers

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

private func makeHelloDatagramWithVersion(_ version: UInt64, maxWant: UInt64 = 128, maxTransfer: UInt64 = 16) throws -> Data {
    let pubKey = Data(repeating: 0x01, count: 32)
    let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKey)

    let payload: CanonicalCBORValue = .map([
        .init(key: .text("version"), value: .unsigned(version)),
        .init(key: .text("node_id"), value: .text(nodeID.hex)),
        .init(key: .text("node_pubkey"), value: .text(GossipV1Base64URL.encode(pubKey))),
        .init(key: .text("capabilities"), value: .array([.text("store")])),
        .init(key: .text("propagation_class"), value: .text("direct")),
        .init(key: .text("max_want"), value: .unsigned(maxWant)),
        .init(key: .text("max_transfer"), value: .unsigned(maxTransfer)),
    ])

    let env: CanonicalCBORValue = .map([
        .init(key: .text("type"), value: .text(GossipV1FrameType.HELLO.rawValue)),
        .init(key: .text("payload"), value: payload),
    ])

    return try CanonicalCBOREncoder().encode(env)
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

    func put(itemID: GossipV1ItemID, envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16) {
        storedByID[itemID] = Stored(envelopeBytes: envelopeBytes, expiryUnixMs: expiryUnixMs, hopCount: hopCount)
    }

    func setEligible(_ ids: [GossipV1ItemID]) {
        eligible = ids
    }
}

private final class InMemoryRelayIngestObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    private(set) var calls: Int = 0

    func noteAuthenticatedRelayIngest(itemIDs _: [GossipV1ItemID], nowMs _: UInt64) throws {
        calls += 1
    }
}
