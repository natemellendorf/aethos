import Foundation
import Testing
@testable import AethosCore

@Test
func gossipV1_invariants_frameEncodeRepeatability_forAllCanonicalFixtures() throws {
    let fixtures = [
        "hello.cbor",
        "summary.cbor",
        "request.cbor",
        "transfer.cbor",
        "receipt.cbor",
        "relay_ingest.cbor",
    ]

    for name in fixtures {
        let bytes = try Data(contentsOf: GossipV1TestSupport.fixturesDir().appendingPathComponent(name))
        let frame = try GossipV1Frame.decode(bytes: bytes)
        let a = frame.encode()
        let b = frame.encode()
        let c = frame.encode()
        #expect(a == b)
        #expect(b == c)
    }
}

@Test
func gossipV1_invariants_bloomIndependentOfInsertionOrder_forSameSet() throws {
    let ids: [GossipV1ItemID] = try (0..<10).map { i in
        var b = Data(repeating: 0, count: 32)
        b[0] = UInt8(i)
        return try GossipV1ItemID(bytes: b)
    }

    let a = GossipV1BloomFilter.build(for: ids)
    let b = GossipV1BloomFilter.build(for: ids.reversed())
    let c = GossipV1BloomFilter.build(for: [ids[5], ids[0], ids[9], ids[1], ids[8], ids[2], ids[7], ids[3], ids[6], ids[4]])
    #expect(a == b)
    #expect(b == c)
}

@Test
func gossipV1_invariants_encodeDecodeEncodeStability_forCanonicalFrames() throws {
    let fixtures = [
        "hello.cbor",
        "summary.cbor",
        "request.cbor",
        "transfer.cbor",
        "receipt.cbor",
        "relay_ingest.cbor",
    ]
    for name in fixtures {
        let bytes = try Data(contentsOf: GossipV1TestSupport.fixturesDir().appendingPathComponent(name))
        let decoded1 = try GossipV1Frame.decode(bytes: bytes)
        let reencoded1 = decoded1.encode()
        let decoded2 = try GossipV1Frame.decode(bytes: reencoded1)
        let reencoded2 = decoded2.encode()
        #expect(reencoded1 == reencoded2)
    }
}

@Test
func gossipV1_invariants_requestWant_isUnique_andLexicographicallySorted_byBytes() throws {
    let ids: [GossipV1ItemID] = try (0..<32).map { i in
        var b = Data(repeating: 0, count: 32)
        b[0] = UInt8(i)
        return try GossipV1ItemID(bytes: b)
    }

    let peerBloom = GossipV1BloomFilter.build(for: ids)
    let want = try GossipV1SummaryReconciliation.computeWant(
        bloomFilterBytes: peerBloom,
        candidateItemIDs: Array(ids.reversed()) + ids + ids,
        localHaveItemIDs: [],
        peerMaxWant: 128
    )

    let unique = Set(want)
    #expect(unique.count == want.count)

    let sorted = want.sorted(by: { DataLexicographic.compare($0.rawBytes(), $1.rawBytes()) == .orderedAscending })
    #expect(sorted == want)
}

@Test
func gossipV1_invariants_duplicateValidImportsDoNotChangeFinalState() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = GossipV1TestSupport.FixedClock(nowMs: 1_000)

    final class CountingStore: @unchecked Sendable, GossipV1EncounterEngine.Store {
        private var hopByID: [GossipV1ItemID: UInt16] = [:]
        private(set) var ingested: [GossipV1ItemID] = []

        func eligibleItemIDs(nowMs _: UInt64) throws -> [GossipV1ItemID] { [] }
        func fetch(_: GossipV1ItemID) throws -> (envelopeBytes: Data, expiryUnixMs: UInt64, hopCount: UInt16)? { nil }
        func existingHopCount(_ itemID: GossipV1ItemID) throws -> UInt16? { hopByID[itemID] }

        func ingest(_ itemID: GossipV1ItemID, envelopeBytes _: Data, expiryUnixMs _: UInt64, hopCount: UInt16) throws {
            // Idempotent import: allow equal hop.
            if let existing = hopByID[itemID], hopCount < existing {
                throw GossipV1EncounterEngine.ValidationError.hopRegression(existing: existing, incoming: hopCount)
            }
            hopByID[itemID] = hopCount
            ingested.append(itemID)
        }
    }
    let store = CountingStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: GossipV1TestSupport.FixedClock(nowMs: 0), store: store)

    let expiryOk: UInt64 = 1_000 + GossipV1.CLOCK_SKEW_TOLERANCE_MS + 1
    let env = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(7))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: env)
    let obj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: env, expiryUnixMs: expiryOk, hopCount: 0)
    let transfer = try GossipV1TransferFrame(objects: [obj])

    _ = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    _ = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)

    #expect(try store.existingHopCount(id) == 0)
}
