import Foundation
import Testing
@testable import AethosCore

private typealias Locked<T> = GossipV1TestSupport.Locked<T>

@Test
func gossipV1_recovery_mixedValidityTransfer_commitsOnlyValidObjects_andIsolatesInvalidOnes() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = GossipV1TestSupport.FixedClock(nowMs: 1_000)
    let store = GossipV1TestSupport.InMemoryGossipStore()

    _ = try engine.ingestInboundFrame(.hello(localHello), clock: GossipV1TestSupport.FixedClock(nowMs: 0), store: store)

    let envGood = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(1))]))
    let idGood = GossipV1ItemID.derive(fromEnvelopeBytes: envGood)
    let expiryOk: UInt64 = 1_000 + GossipV1.CLOCK_SKEW_TOLERANCE_MS + 1
    let goodObj = try GossipV1TransferFrame.Object(itemID: idGood, envelopeBytes: envGood, expiryUnixMs: expiryOk, hopCount: 0)

    let envExpired = try CanonicalCBOREncoder().encode(.map([.init(key: .text("x"), value: .unsigned(2))]))
    let idExpired = GossipV1ItemID.derive(fromEnvelopeBytes: envExpired)
    let expiryExpired: UInt64 = 1_000 + GossipV1.CLOCK_SKEW_TOLERANCE_MS
    let expiredObj = try GossipV1TransferFrame.Object(itemID: idExpired, envelopeBytes: envExpired, expiryUnixMs: expiryExpired, hopCount: 0)

    let transfer = GossipV1TransferFrame(unsafeObjects: [goodObj, expiredObj])
    let result = try engine.ingestInboundFrame(.transfer(transfer), clock: clock, store: store)

    #expect(result.acceptedTransferItemIDs == [idGood])
    #expect(result.nonfatalValidationErrors == [.transferExpired(nowUnixMs: 1_000, expiryUnixMs: expiryExpired)])

    #expect(store.snapshot(idGood) != nil)
    #expect(store.snapshot(idExpired) == nil)
}

@Test
func gossipV1_recovery_observerHookFailureDoesNotDamageValidFlow_whenContractSaysContinue() throws {
    let engine = GossipV1EncounterEngine(config: .init(localHello: try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)))

    let thrown = NonCancellationObserverError()
    let observer = ThrowingRelayObserver(error: thrown)

    let receivedFrames = Locked<[GossipV1Frame]>([])
    let errors = Locked<[GossipV1TransportError]>([])

    let hooks = GossipV1StreamAdapter.Hooks(
        onSend: { _ in },
        onEvent: { event in
            if case .didReceiveFrame(let f) = event { receivedFrames.withLock { $0.append(f) } }
            if case .didEncounterError(let e) = event { errors.withLock { $0.append(e) } }
        }
    )

    var adapter = GossipV1StreamAdapter(
        engine: engine,
        clock: GossipV1TestSupport.FixedClock(nowMs: 0),
        store: GossipV1TestSupport.InMemoryGossipStore(),
        relayObserver: observer,
        isAuthenticatedRelayTransport: { true },
        hooks: hooks
    )

    let itemID = GossipV1ItemID.derive(fromEnvelopeBytes: Data([0x01]))
    let ingest = try GossipV1RelayIngestFrame(itemIDs: [itemID])
    let relayBytes = try GossipV1Framing.encodeStreamFrame(GossipV1Frame.relayIngest(ingest).encode())
    let helloBytes = try GossipV1TestSupport.fixtureData("hello.cbor")
    let helloStreamBytes = try GossipV1Framing.encodeStreamFrame(helloBytes)

    try adapter.receiveBytes(relayBytes + helloStreamBytes)

    // The observer error should be surfaced, but processing continues and HELLO is received.
    #expect(errors.withLock { $0 }.contains(.unexpected))
    #expect(receivedFrames.withLock { $0 }.contains { if case .hello = $0 { true } else { false } })
    #expect(adapter.state == .active)
}

private struct NonCancellationObserverError: Swift.Error, Equatable {}

private final class ThrowingRelayObserver: @unchecked Sendable, GossipV1EncounterEngine.RelayIngestObserving {
    let error: any Swift.Error

    init(error: any Swift.Error) {
        self.error = error
    }

    func noteAuthenticatedRelayIngest(itemIDs _: [GossipV1ItemID], nowMs _: UInt64) throws {
        throw error
    }
}
