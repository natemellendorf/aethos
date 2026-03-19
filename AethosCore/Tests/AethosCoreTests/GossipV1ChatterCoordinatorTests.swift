import Foundation
import Testing
@testable import AethosCore

@Test
func chatterCoordinator_inventoryDeltaAndNoOpSuppression() {
    var coordinator = GossipV1ChatterCoordinator()
    let relayBearer = GossipV1Bearer.relay("relay-a")

    let first = coordinator.planAdvertisement(for: relayBearer, manifests: ["b", "a", "b"])
    #expect(first == .full(["a", "b"]))

    let noOp = coordinator.planAdvertisement(for: relayBearer, manifests: ["a", "b"])
    #expect(noOp == .suppressNoOp)

    let delta = coordinator.planAdvertisement(for: relayBearer, manifests: ["b", "c"])
    #expect(delta == .delta(.init(added: ["c"], removed: ["a"])))

    #expect(coordinator.metrics.advertisementFullSent == 1)
    #expect(coordinator.metrics.advertisementDeltaSent == 1)
    #expect(coordinator.metrics.advertisementNoOpSuppressed == 1)
}

@Test
func chatterCoordinator_requestSuppressionAndNormalization() throws {
    var coordinator = GossipV1ChatterCoordinator()
    let lanBearer = GossipV1Bearer.lan(interface: "en0")

    let empty = coordinator.planRequest(for: lanBearer, want: [])
    #expect(empty == .suppressEmpty)

    let a = try GossipV1ItemID(bytes: Data(repeating: 0x01, count: 32))
    let b = try GossipV1ItemID(bytes: Data(repeating: 0x02, count: 32))

    let send = coordinator.planRequest(for: lanBearer, want: [b, a, b])
    #expect(send == .send([a, b]))

    let noOp = coordinator.planRequest(for: lanBearer, want: [a, b])
    #expect(noOp == .suppressNoOp)

    #expect(coordinator.metrics.requestSent == 1)
    #expect(coordinator.metrics.requestEmptySuppressed == 1)
    #expect(coordinator.metrics.requestNoOpSuppressed == 1)
}

@Test
func chatterCoordinator_lanDiscoveryIsMulticastFirstWithUnicastFollowUp() {
    var coordinator = GossipV1ChatterCoordinator()

    let multicast = coordinator.beginLanDiscovery(nowMs: 1_000, interfaces: ["en1", "en0"])
    #expect(multicast == [
        .multicastProbe(interface: "en0"),
        .multicastProbe(interface: "en1"),
    ])

    coordinator.noteLanDiscoveryResponse(interface: "en0", peerID: "peer-1", endpoint: "udp://10.0.0.2:9000", nowMs: 1_020)
    #expect(coordinator.dueLanFollowUps(nowMs: 1_200).isEmpty)

    let followUps = coordinator.dueLanFollowUps(nowMs: 1_270)
    #expect(followUps == [
        .unicastFollowUp(interface: "en0", peerID: "peer-1", endpoint: "udp://10.0.0.2:9000")
    ])

    #expect(coordinator.metrics.lanMulticastSent == 2)
    #expect(coordinator.metrics.lanUnicastFollowUpSent == 1)
}

@Test
func chatterCoordinator_interfaceSuppressionPreventsRapidRepeatedMulticast() {
    var coordinator = GossipV1ChatterCoordinator()

    let first = coordinator.beginLanDiscovery(nowMs: 1_000, interfaces: ["en0"])
    #expect(first == [.multicastProbe(interface: "en0")])

    let suppressed = coordinator.beginLanDiscovery(nowMs: 1_100, interfaces: ["en0"])
    #expect(suppressed.isEmpty)

    let later = coordinator.beginLanDiscovery(nowMs: 2_100, interfaces: ["en0"])
    #expect(later == [.multicastProbe(interface: "en0")])

    #expect(coordinator.metrics.lanMulticastSent == 2)
    #expect(coordinator.metrics.lanMulticastSuppressedByInterface == 1)
}

@Test
func chatterCoordinator_adaptivePacingBackoffAndJitterAreDeterministic() {
    var coordinator = GossipV1ChatterCoordinator()
    let bearer = GossipV1Bearer.relay("relay-a")

    _ = coordinator.planAdvertisement(for: bearer, manifests: ["a"])
    _ = coordinator.planAdvertisement(for: bearer, manifests: ["a"])
    #expect(coordinator.pacer.currentIntervalMs == 1_500)

    coordinator.notePacingFailure()
    #expect(coordinator.pacer.currentIntervalMs == 3_000)

    _ = coordinator.planAdvertisement(for: bearer, manifests: ["a", "b"])
    #expect(coordinator.pacer.currentIntervalMs == 1_500)

    #expect(coordinator.nextRecommendedDelayMs(jitterSample: 0.0) == 1_300)
    #expect(coordinator.nextRecommendedDelayMs(jitterSample: 1.0) == 1_700)
}

@Test
func chatterCoordinator_crossBearerDedupeSuppressesWithinWindow() {
    var coordinator = GossipV1ChatterCoordinator()
    let fingerprint = Data([0xAB, 0xCD])

    let first = coordinator.shouldTransmit(
        fingerprint: fingerprint,
        via: .relay("relay-a"),
        nowMs: 10_000
    )
    #expect(first)

    let suppressed = coordinator.shouldTransmit(
        fingerprint: fingerprint,
        via: .lan(interface: "en0"),
        nowMs: 10_200
    )
    #expect(!suppressed)

    let allowedAgain = coordinator.shouldTransmit(
        fingerprint: fingerprint,
        via: .lan(interface: "en0"),
        nowMs: 15_201
    )
    #expect(allowedAgain)

    #expect(coordinator.metrics.crossBearerDedupeSuppressed == 1)
}

@Test
func chatterCoordinator_keepsLanAndRelaySimultaneouslyActive() {
    var coordinator = GossipV1ChatterCoordinator()
    let relayBearer = GossipV1Bearer.relay("relay-a")
    let lanBearer = GossipV1Bearer.lan(interface: "en0")

    let relayPlan = coordinator.planAdvertisement(for: relayBearer, manifests: ["a"])
    let lanPlan = coordinator.planAdvertisement(for: lanBearer, manifests: ["a"])

    #expect(relayPlan == .full(["a"]))
    #expect(lanPlan == .full(["a"]))

    let lanActions = coordinator.beginLanDiscovery(nowMs: 1_000, interfaces: ["en0"])
    #expect(lanActions == [.multicastProbe(interface: "en0")])
}
