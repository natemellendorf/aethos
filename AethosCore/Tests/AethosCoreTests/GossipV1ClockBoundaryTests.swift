import Foundation
import Testing
@testable import AethosCore

@Test
func gossipV1_clockBoundary_justBeforeExpiryIsAccepted() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let store = GossipV1TestSupport.InMemoryGossipStore()

    _ = try engine.ingestInboundFrame(.hello(localHello), clock: GossipV1TestSupport.FixedClock(nowMs: 0), store: store)

    let now: UInt64 = 1_000
    let clock = GossipV1TestSupport.FixedClock(nowMs: now)
    let cutoff = now + GossipV1.CLOCK_SKEW_TOLERANCE_MS

    // cutoff < expiry => accepted.
    let expiry = cutoff + 1
    let env = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: env)
    let obj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: env, expiryUnixMs: expiry, hopCount: 0)
    let transfer = try GossipV1TransferFrame(objects: [obj])

    let result = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    #expect(result.acceptedTransferItemIDs == [id])
}

@Test
func gossipV1_clockBoundary_exactBoundaryIsRejected() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let store = GossipV1TestSupport.InMemoryGossipStore()

    _ = try engine.ingestInboundFrame(.hello(localHello), clock: GossipV1TestSupport.FixedClock(nowMs: 0), store: store)

    let now: UInt64 = 1_000
    let clock = GossipV1TestSupport.FixedClock(nowMs: now)
    let expiry = now + GossipV1.CLOCK_SKEW_TOLERANCE_MS // cutoff >= expiry => rejected

    let env = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: env)
    let obj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: env, expiryUnixMs: expiry, hopCount: 0)
    let transfer = try GossipV1TransferFrame(objects: [obj])

    let result = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    #expect(result.acceptedTransferItemIDs.isEmpty)
    #expect(result.nonfatalValidationErrors == [.transferExpired(nowUnixMs: now, expiryUnixMs: expiry)])
}

@Test
func gossipV1_clockBoundary_justAfterExpiryIsRejected() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let store = GossipV1TestSupport.InMemoryGossipStore()
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: GossipV1TestSupport.FixedClock(nowMs: 0), store: store)

    let now: UInt64 = 1_000
    let clock = GossipV1TestSupport.FixedClock(nowMs: now)
    let expiry = now + GossipV1.CLOCK_SKEW_TOLERANCE_MS - 1

    let env = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: env)
    let obj = try GossipV1TransferFrame.Object(itemID: id, envelopeBytes: env, expiryUnixMs: expiry, hopCount: 0)
    let transfer = try GossipV1TransferFrame(objects: [obj])

    let result = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)
    #expect(result.acceptedTransferItemIDs.isEmpty)
    #expect(result.nonfatalValidationErrors == [.transferExpired(nowUnixMs: now, expiryUnixMs: expiry)])
}

@Test
func gossipV1_clockBoundary_expiredItemsNotForwardedEvenIfRequested() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let store = GossipV1TestSupport.InMemoryGossipStore()

    // Establish peer caps via inbound HELLO.
    let peerHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    _ = try engine.ingestInboundFrame(.hello(peerHello), clock: GossipV1TestSupport.FixedClock(nowMs: 0), store: store)

    let now: UInt64 = 1_000
    let clock = GossipV1TestSupport.FixedClock(nowMs: now)
    let expiry = now + GossipV1.CLOCK_SKEW_TOLERANCE_MS // cutoff >= expiry => expired

    let env = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(9))]))
    let id = GossipV1ItemID.derive(fromEnvelopeBytes: env)
    store.put(itemID: id, envelopeBytes: env, expiryUnixMs: expiry, hopCount: 0)
    store.setEligible([id])

    let request = try GossipV1RequestFrame(want: [id])
    let result = try engine.ingestInboundFrame(.request(request), clock: clock, store: store)
    #expect(result.outbound.isEmpty)
}
