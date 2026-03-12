import Foundation
import Testing
@testable import AethosCore

@Test
func gossipV1_stateMachine_summaryNotAcceptedBeforeHello() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))

    let summary = try GossipV1SummaryFrame(
        bloomFilter: Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES),
        itemCount: 0
    )
    #expect(throws: GossipV1EncounterEngine.ValidationError.helloRequiredFirst) {
        _ = try engine.ingestInboundFrame(
            .summary(summary),
            clock: GossipV1TestSupport.FixedClock(nowMs: 0),
            store: GossipV1TestSupport.InMemoryGossipStore()
        )
    }
}

@Test
func gossipV1_stateMachine_requestNotAcceptedBeforeHello_orBeforePeerCapsEstablished() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = GossipV1TestSupport.FixedClock(nowMs: 0)
    let store = GossipV1TestSupport.InMemoryGossipStore()

    let id = try GossipV1ItemID(bytes: Data(repeating: 0x01, count: 32))
    let request = try GossipV1RequestFrame(want: [id])

    // Before any HELLO: helloRequiredFirst.
    #expect(throws: GossipV1EncounterEngine.ValidationError.helloRequiredFirst) {
        _ = try engine.ingestInboundFrame(.request(request), clock: clock, store: store)
    }

    // After inbound HELLO (caps established).
    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)
    #expect(engine.state == .active)
    #expect(engine.peerCaps != nil)

    // Active but no peer caps is a fail-fast error.
    #if DEBUG
    var engineWithoutCaps = GossipV1EncounterEngine(_testing: .init(localHello: localHello), state: .active, peerCaps: nil)
    #expect(throws: GossipV1EncounterEngine.ValidationError.peerCapsUnknown) {
        _ = try engineWithoutCaps.ingestInboundFrame(.request(request), clock: clock, store: store)
    }
    #endif
}

@Test
func gossipV1_stateMachine_receiptNotAcceptedWithoutPrecedingOutboundTransfer() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = GossipV1TestSupport.FixedClock(nowMs: 0)
    let store = GossipV1TestSupport.InMemoryGossipStore()

    _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)

    let received = try GossipV1ItemID(bytes: Data(repeating: 0xAA, count: 32))
    let receipt = try GossipV1ReceiptFrame(received: [received])

    #expect(throws: GossipV1EncounterEngine.ValidationError.receiptWithoutPrecedingTransfer) {
        _ = try engine.ingestInboundFrame(.receipt(receipt), clock: clock, store: store)
    }
}

@Test
func gossipV1_stateMachine_terminalStateRemainsTerminal_andDoesNotResumeProcessing() throws {
    let localHello = try GossipV1TestSupport.makeHello(version: GossipV1.GOSSIP_VERSION)
    var engine = GossipV1EncounterEngine(config: .init(localHello: localHello))
    let clock = GossipV1TestSupport.FixedClock(nowMs: 0)
    let store = GossipV1TestSupport.InMemoryGossipStore()

    // Terminate via HELLO version mismatch.
    let badHelloDatagram = try makeHelloDatagramWithVersion(GossipV1.GOSSIP_VERSION + 1)
    #expect(throws: GossipV1EncounterEngine.ValidationError.invalidHelloVersion(expected: GossipV1.GOSSIP_VERSION, actual: GossipV1.GOSSIP_VERSION + 1)) {
        _ = try engine.ingestInboundDatagram(badHelloDatagram, clock: clock, store: store)
    }
    #expect(engine.state == .terminated(reason: .helloVersionMismatch(expected: GossipV1.GOSSIP_VERSION, actual: GossipV1.GOSSIP_VERSION + 1)))

    // Any subsequent frames must fail fast.
    #expect(throws: GossipV1EncounterEngine.ValidationError.encounterTerminated) {
        _ = try engine.ingestInboundFrame(.hello(localHello), clock: clock, store: store)
    }
    let summary = try GossipV1SummaryFrame(bloomFilter: Data(repeating: 0, count: GossipV1.BLOOM_FILTER_BYTES), itemCount: 0)
    #expect(throws: GossipV1EncounterEngine.ValidationError.encounterTerminated) {
        _ = try engine.ingestInboundFrame(.summary(summary), clock: clock, store: store)
    }
}

private func makeHelloDatagramWithVersion(_ version: UInt64) throws -> Data {
    let pubKey = Data(repeating: 0x01, count: 32)
    let nodeID = GossipV1NodeID.derive(fromPublicKeyRawBytes: pubKey)

    let payload: CanonicalCBORValue = .map([
        .init(key: .text("version"), value: .unsigned(version)),
        .init(key: .text("node_id"), value: .text(nodeID.hex)),
        .init(key: .text("node_pubkey"), value: .text(GossipV1Base64URL.encode(pubKey))),
        .init(key: .text("capabilities"), value: .array([.text("store")])),
        .init(key: .text("propagation_class"), value: .text("direct")),
        .init(key: .text("max_want"), value: .unsigned(128)),
        .init(key: .text("max_transfer"), value: .unsigned(16)),
    ])

    return try GossipV1FixtureVectorBuilder.encodeFrameBytes(type: .HELLO, payload: payload)
}
