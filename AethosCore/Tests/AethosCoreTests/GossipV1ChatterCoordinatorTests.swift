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

    #expect(coordinator.metrics.advertisementFullPlanned == 1)
    #expect(coordinator.metrics.advertisementDeltaPlanned == 1)
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

    #expect(coordinator.metrics.requestPlanned == 1)
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

    #expect(coordinator.metrics.lanMulticastPlanned == 2)
    #expect(coordinator.metrics.lanUnicastFollowUpEnqueued == 1)
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

    #expect(coordinator.metrics.lanMulticastPlanned == 2)
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
func chatterCoordinator_crossBearerDedupeSuppressesOnlyAfterSuccessfulTransmitAndOnlyAcrossBearers() {
    var coordinator = GossipV1ChatterCoordinator()
    let fingerprint = Data([0xAB, 0xCD])

    let firstAttempt = coordinator.shouldTransmit(
        fingerprint: fingerprint,
        via: .relay("relay-a"),
        nowMs: 10_000
    )
    #expect(firstAttempt)

    // No successful transmit recorded yet; retries should not be suppressed.
    let retryAttempt = coordinator.shouldTransmit(
        fingerprint: fingerprint,
        via: .relay("relay-a"),
        nowMs: 10_050
    )
    #expect(retryAttempt)

    coordinator.noteDidTransmit(
        fingerprint: fingerprint,
        via: .relay("relay-a"),
        nowMs: 10_100
    )

    // Same-bearer retransmits are allowed (cross-bearer dedupe only).
    let sameBearerRepeat = coordinator.shouldTransmit(
        fingerprint: fingerprint,
        via: .relay("relay-a"),
        nowMs: 10_101
    )
    #expect(sameBearerRepeat)

    // Second bearer is suppressed while within cross-bearer suppression window.
    let firstLanAttempt = coordinator.shouldTransmit(
        fingerprint: fingerprint,
        via: .lan(interface: "en0"),
        nowMs: 10_200
    )
    #expect(!firstLanAttempt)

    let suppressedCrossBearer = coordinator.shouldTransmit(
        fingerprint: fingerprint,
        via: .lan(interface: "en0"),
        nowMs: 10_201
    )
    #expect(!suppressedCrossBearer)

    // Suppression boundary is exclusive (< window suppresses, == window allows).
    let boundaryAllowed = coordinator.shouldTransmit(
        fingerprint: fingerprint,
        via: .relay("relay-a"),
        nowMs: 15_200
    )
    #expect(boundaryAllowed)

    #expect(coordinator.metrics.crossBearerDedupeSuppressed == 2)
}

@Test
func chatterCoordinator_lanDiscoveryIgnoresStaleResponsesForFollowUpScheduling() {
    var coordinator = GossipV1ChatterCoordinator(
        config: .init(
            pacer: .default,
            dedupe: .default,
            discovery: .init(
                followUpDelayMs: 250,
                interfaceSuppressionWindowMs: 1_000,
                maxResponseAgeMs: 200,
                maxUnicastFollowUpsPerTick: 8
            )
        )
    )

    _ = coordinator.beginLanDiscovery(nowMs: 1_000, interfaces: ["en0"])

    // Too old relative to multicast, ignored.
    coordinator.noteLanDiscoveryResponse(interface: "en0", peerID: "stale", endpoint: "udp://10.0.0.3:9000", nowMs: 1_250)

    // Fresh enough, accepted.
    coordinator.noteLanDiscoveryResponse(interface: "en0", peerID: "fresh", endpoint: "udp://10.0.0.4:9000", nowMs: 1_150)

    let followUps = coordinator.dueLanFollowUps(nowMs: 1_500)
    #expect(followUps == [
        .unicastFollowUp(interface: "en0", peerID: "fresh", endpoint: "udp://10.0.0.4:9000")
    ])
}

@Test
func adaptivePacerConfigValidatingInitRejectsInvalidValues() {
    #expect(throws: GossipV1AdaptivePacer.Config.ValidationError.minIntervalNegative(actual: -1)) {
        _ = try GossipV1AdaptivePacer.Config(
            validating: -1,
            maxIntervalMs: 30_000,
            initialIntervalMs: 2_000,
            noOpBackoffMultiplier: 1.5,
            failureBackoffMultiplier: 2.0,
            jitterMs: 200
        )
    }

    #expect(throws: GossipV1AdaptivePacer.Config.ValidationError.maxIntervalLessThanMin(min: 1_000, max: 999)) {
        _ = try GossipV1AdaptivePacer.Config(
            validating: 1_000,
            maxIntervalMs: 999,
            initialIntervalMs: 1_000,
            noOpBackoffMultiplier: 1.5,
            failureBackoffMultiplier: 2.0,
            jitterMs: 200
        )
    }

    #expect(throws: GossipV1AdaptivePacer.Config.ValidationError.initialIntervalOutOfRange(min: 500, max: 5_000, actual: 6_000)) {
        _ = try GossipV1AdaptivePacer.Config(
            validating: 500,
            maxIntervalMs: 5_000,
            initialIntervalMs: 6_000,
            noOpBackoffMultiplier: 1.5,
            failureBackoffMultiplier: 2.0,
            jitterMs: 200
        )
    }

    #expect(throws: GossipV1AdaptivePacer.Config.ValidationError.noOpBackoffMultiplierLessThanOne(actual: 0.9)) {
        _ = try GossipV1AdaptivePacer.Config(
            validating: 500,
            maxIntervalMs: 5_000,
            initialIntervalMs: 2_000,
            noOpBackoffMultiplier: 0.9,
            failureBackoffMultiplier: 2.0,
            jitterMs: 200
        )
    }

    #expect(throws: GossipV1AdaptivePacer.Config.ValidationError.failureBackoffMultiplierLessThanOne(actual: 0.5)) {
        _ = try GossipV1AdaptivePacer.Config(
            validating: 500,
            maxIntervalMs: 5_000,
            initialIntervalMs: 2_000,
            noOpBackoffMultiplier: 1.5,
            failureBackoffMultiplier: 0.5,
            jitterMs: 200
        )
    }

    #expect(throws: GossipV1AdaptivePacer.Config.ValidationError.jitterNegative(actual: -1)) {
        _ = try GossipV1AdaptivePacer.Config(
            validating: 500,
            maxIntervalMs: 5_000,
            initialIntervalMs: 2_000,
            noOpBackoffMultiplier: 1.5,
            failureBackoffMultiplier: 2.0,
            jitterMs: -1
        )
    }
}

@Test
func adaptivePacerConfigValidatingInitAcceptsValidValues() throws {
    let config = try GossipV1AdaptivePacer.Config(
        validating: 500,
        maxIntervalMs: 5_000,
        initialIntervalMs: 2_000,
        noOpBackoffMultiplier: 1.5,
        failureBackoffMultiplier: 2.0,
        jitterMs: 200
    )

    #expect(config.minIntervalMs == 500)
    #expect(config.maxIntervalMs == 5_000)
    #expect(config.initialIntervalMs == 2_000)
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
