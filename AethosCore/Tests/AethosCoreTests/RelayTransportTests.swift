import Foundation
import Testing
@testable import AethosCore

// MARK: - Legacy Relay Frame Tests

@Test
func relayFrameEncodeDecodeRoundTrip() throws {
    let envelopeData = Data("test envelope payload".utf8)
    let frame = RelayFrame.envelope(envelopeData)

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .envelope(envelopeData))
}

@Test
func relayFrameAckEncodeDecodeRoundTrip() throws {
    let envelopeId = Data(repeating: 0xAB, count: 32)
    let frame = RelayFrame.ack(envelopeId: envelopeId)

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .ack(envelopeId: envelopeId))
}

@Test
func relayFrameNackEncodeDecodeRoundTrip() throws {
    let envelopeId = Data(repeating: 0xCD, count: 32)
    let reason = "destination offline"
    let frame = RelayFrame.nack(envelopeId: envelopeId, reason: reason)

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .nack(envelopeId: envelopeId, reason: reason))
}

@Test
func relayFrameNackEncodeDecodeRoundTripWithZeroBytes() throws {
    // Test NACK framing with envelope ID containing 0x00 bytes
    // This tests the deterministic length-prefixed encoding fix
    var envelopeId = Data(repeating: 0x00, count: 16)
    envelopeId.append(contentsOf: [0xAB, 0xCD, 0xEF])  // Append some non-zero bytes
    let reason = "relay unavailable"
    let frame = RelayFrame.nack(envelopeId: envelopeId, reason: reason)
    
    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)
    
    #expect(decoded == .nack(envelopeId: envelopeId, reason: reason))
}

@Test
func relayFrameNackBackwardCompatibilityWithOldFormat() throws {
    // Test backward compatibility: decode old format (envelopeId + 0x00 + reason)
    // This simulates data from older clients that used the old delimiter-based format
    var oldFormatPayload = Data(repeating: 0x42, count: 10)
    oldFormatPayload.append(0x00)  // Delimiter
    oldFormatPayload.append(contentsOf: "offline".utf8)
    
    // Frame type + length prefix + payload
    var encoded = Data([RelayFrame.nackTypeId])
    var length = UInt32(oldFormatPayload.count).bigEndian
    encoded.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
    encoded.append(oldFormatPayload)
    
    // Should decode successfully using backward compatibility fallback
    let decoded = try RelayFrame.decode(encoded)
    
    #expect(decoded != nil)
    if case .nack(let envId, let reason) = decoded {
        #expect(Data(envId) == Data(repeating: 0x42, count: 10))
        #expect(reason == "offline")
    }
}

@Test
func relayFrameHeartbeatEncodeDecodeRoundTrip() throws {
    let frame = RelayFrame.heartbeat

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .heartbeat)
}

@Test
func relayFrameHeartbeatAckEncodeDecodeRoundTrip() throws {
    let frame = RelayFrame.heartbeatAck

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .heartbeatAck)
}

@Test
func relayFrameDecodeReturnsNilForInvalidType() throws {
    var invalidData = Data()
    invalidData.append(0xFF)
    var length: UInt32 = 0
    invalidData.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })

    let decoded = try RelayFrame.decode(invalidData)
    #expect(decoded == nil)
}

@Test
func relayFrameAssignedTypeIDsAvoidReservedRanges() {
    let ids = RelayFrame.assignedTypeIDs
    #expect(Set(ids).count == ids.count)

    for id in ids {
        #expect(!RelayFrame.TypeSpace.reservedFutureRange.contains(id))
        #expect(!RelayFrame.TypeSpace.reservedErrorRange.contains(id))
    }
}

@Test
func relayFrameDecodeRejectsReservedFutureTypeID() throws {
    var bytes = Data([0x30])
    var length: UInt32 = 0
    bytes.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })

    let decoded = try RelayFrame.decode(bytes)
    #expect(decoded == nil)
}

// MARK: - Federation Frame Encode/Decode Tests

@Test
func clientHelloFrameRoundTrip() throws {
    let frame = RelayFrame.clientHello(wayfarerId: "wayfarer-abc123")

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .clientHello(wayfarerId: "wayfarer-abc123"))
}

@Test
func publishFrameRoundTrip() throws {
    let envelopeId = Data(repeating: 0x11, count: 32)
    let payload = Data("outbound message body".utf8)
    let frame = RelayFrame.publish(envelopeId: envelopeId, payload: payload)

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .publish(envelopeId: envelopeId, payload: payload))
}

@Test
func deliverFrameRoundTrip() throws {
    let envelopeId = Data(repeating: 0x22, count: 32)
    let payload = Data("inbound message body".utf8)
    let metadata = Data("sender-hint".utf8)
    let frame = RelayFrame.deliver(
        envelopeId: envelopeId, payload: payload, metadata: metadata
    )

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .deliver(
        envelopeId: envelopeId, payload: payload, metadata: metadata
    ))
}

@Test
func deliverFrameRoundTripWithEmptyMetadata() throws {
    let envelopeId = Data(repeating: 0x33, count: 16)
    let payload = Data("payload only".utf8)
    let frame = RelayFrame.deliver(
        envelopeId: envelopeId, payload: payload, metadata: Data()
    )

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .deliver(
        envelopeId: envelopeId, payload: payload, metadata: Data()
    ))
}

@Test
func relayPeerHelloFrameRoundTrip() throws {
    let frame = RelayFrame.relayPeerHello(relayId: "relay-us-east-1")

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .relayPeerHello(relayId: "relay-us-east-1"))
}

@Test
func relayInventoryFrameRoundTrip() throws {
    let inventoryBlob = Data(repeating: 0x44, count: 256)
    let frame = RelayFrame.relayInventory(inventoryBlob)

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .relayInventory(inventoryBlob))
}

@Test
func relayForwardFrameRoundTrip() throws {
    let envelopeId = Data(repeating: 0x55, count: 32)
    let payload = Data("forwarded envelope".utf8)
    let frame = RelayFrame.relayForward(envelopeId: envelopeId, payload: payload)

    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)

    #expect(decoded == .relayForward(envelopeId: envelopeId, payload: payload))
}

@Test
func relayFrameDecodeReturnsNilForTruncatedData() throws {
    let decoded = try RelayFrame.decode(Data([0x10, 0x00]))
    #expect(decoded == nil)
}

@Test
func relayFrameDecodeReturnsNilForEmptyData() throws {
    let decoded = try RelayFrame.decode(Data())
    #expect(decoded == nil)
}

// MARK: - Relay Selection Tests

@Test
func relaySelectionSelectsTopKByHealthScore() throws {
    let relays = [
        RelayConfig(relayId: "relay-a", wsURL: URL(string: "wss://a.example.com/ws")!, priority: 1),
        RelayConfig(relayId: "relay-b", wsURL: URL(string: "wss://b.example.com/ws")!, priority: 2),
        RelayConfig(relayId: "relay-c", wsURL: URL(string: "wss://c.example.com/ws")!, priority: 3),
    ]

    var health: [String: RelayHealth] = [:]
    health["relay-a"] = RelayHealth(relayId: "relay-a")
    health["relay-a"]?.currentScore = 50
    health["relay-b"] = RelayHealth(relayId: "relay-b")
    health["relay-b"]?.currentScore = 80
    health["relay-c"] = RelayHealth(relayId: "relay-c")
    health["relay-c"]?.currentScore = 30

    let selector = RelaySelection(strategy: .byHealthScore)
    let selected = selector.select(k: 2, from: relays, health: health)

    #expect(selected.count == 2)
    #expect(selected[0] == "relay-b")
    #expect(selected[1] == "relay-a")
}

@Test
func relaySelectionExcludesUnhealthyRelays() throws {
    let relays = [
        RelayConfig(relayId: "relay-healthy", wsURL: URL(string: "wss://healthy.example.com/ws")!, priority: 1),
        RelayConfig(relayId: "relay-backoff", wsURL: URL(string: "wss://backoff.example.com/ws")!, priority: 2),
    ]

    var health: [String: RelayHealth] = [:]
    health["relay-healthy"] = RelayHealth(relayId: "relay-healthy")
    health["relay-backoff"] = RelayHealth(relayId: "relay-backoff")
    health["relay-backoff"]?.backoffUntil = Date().addingTimeInterval(3600)

    let selector = RelaySelection(strategy: .byHealthScore)
    let selected = selector.select(k: 2, from: relays, health: health)

    #expect(selected.count == 1)
    #expect(selected[0] == "relay-healthy")
}

@Test
func relaySelectionRandomStrategy() throws {
    let relays = [
        RelayConfig(relayId: "relay-a", wsURL: URL(string: "wss://a.example.com/ws")!, priority: 1),
        RelayConfig(relayId: "relay-b", wsURL: URL(string: "wss://b.example.com/ws")!, priority: 2),
        RelayConfig(relayId: "relay-c", wsURL: URL(string: "wss://c.example.com/ws")!, priority: 3),
    ]

    var health: [String: RelayHealth] = [:]
    for relay in relays {
        health[relay.relayId] = RelayHealth(relayId: relay.relayId)
    }

    let selector = RelaySelection(strategy: .randomHealthy)
    var results: [[String]] = []

    for _ in 0..<10 {
        let selected = selector.select(k: 2, from: relays, health: health)
        results.append(selected)
    }

    let allCorrectCount = results.reduce(true) { $0 && ($1.count == 2) }
    #expect(allCorrectCount)
}

// MARK: - Backoff Tests

@Test
func deterministicBackoffIncreasesExponentially() {
    var backoff = DeterministicBackoff(seed: 0.5, deterministic: true)

    let first = backoff.nextBackoff(for: "relay-a", base: 1.0, max: 60.0, jitter: 0.0)
    let second = backoff.nextBackoff(for: "relay-a", base: 1.0, max: 60.0, jitter: 0.0)
    let third = backoff.nextBackoff(for: "relay-a", base: 1.0, max: 60.0, jitter: 0.0)

    #expect(first == 2.0)
    #expect(second == 4.0)
    #expect(third == 8.0)
}

@Test
func deterministicBackoffCapsAtMaximum() {
    var backoff = DeterministicBackoff(seed: 0.5, deterministic: true)

    for _ in 0..<20 {
        let result = backoff.nextBackoff(for: "relay-a", base: 1.0, max: 30.0, jitter: 0.0)
        #expect(result <= 30.0)
    }
}

@Test
func deterministicBackoffResetsAfterSuccess() {
    var backoff = DeterministicBackoff(seed: 0.5, deterministic: true)

    _ = backoff.nextBackoff(for: "relay-a", base: 1.0, max: 60.0, jitter: 0.0)
    _ = backoff.nextBackoff(for: "relay-a", base: 1.0, max: 60.0, jitter: 0.0)

    backoff.reset(for: "relay-a")

    let firstAfterReset = backoff.nextBackoff(for: "relay-a", base: 1.0, max: 60.0, jitter: 0.0)
    #expect(firstAfterReset == 2.0)
}

// MARK: - Relay Health Tests

@Test
func relayHealthManagerTracksHealth() {
    var manager = RelayHealthManager()

    let config = RelayConfig(relayId: "test-relay", wsURL: URL(string: "wss://test.example.com/ws")!)
    manager.addRelay(config)

    let state = manager.getState(for: "test-relay")
    #expect(state != nil)
    #expect(state?.currentScore == RelayHealth.initialScore)
}

@Test
func relayHealthManagerRecordsSuccess() {
    var manager = RelayHealthManager()

    let config = RelayConfig(relayId: "test-relay", wsURL: URL(string: "wss://test.example.com/ws")!)
    manager.addRelay(config)

    manager.recordSuccess(relayId: "test-relay", latencyMs: 50.0)

    let state = manager.getState(for: "test-relay")
    let expectedScore = RelayHealthManager.RelayHealthState.initialScore + 10

    #expect(state?.currentScore == expectedScore)
    #expect(state?.latencyMs == 50.0)
}

@Test
func relayHealthManagerRecordsFailure() {
    var manager = RelayHealthManager()

    let config = RelayConfig(relayId: "test-relay", wsURL: URL(string: "wss://test.example.com/ws")!)
    manager.addRelay(config)

    manager.recordFailure(relayId: "test-relay", baseBackoff: 1.0, maxBackoff: 60.0, jitterFactor: 0.0)

    let state = manager.getState(for: "test-relay")
    #expect(state?.currentScore == RelayHealth.initialScore - 20)
    #expect(state?.consecutiveFailures == 1)
    #expect(state?.backoffUntil != nil)
}

@Test
func relayHealthManagerSelectsTopK() {
    var manager = RelayHealthManager()

    let configs = [
        RelayConfig(relayId: "relay-a", wsURL: URL(string: "wss://a.example.com/ws")!),
        RelayConfig(relayId: "relay-b", wsURL: URL(string: "wss://b.example.com/ws")!),
        RelayConfig(relayId: "relay-c", wsURL: URL(string: "wss://c.example.com/ws")!),
    ]

    for config in configs {
        manager.addRelay(config)
    }

    manager.recordSuccess(relayId: "relay-a", latencyMs: 100.0)
    manager.recordFailure(relayId: "relay-b", baseBackoff: 1.0, maxBackoff: 60.0, jitterFactor: 0.0)
    manager.recordSuccess(relayId: "relay-c", latencyMs: 50.0)

    let selected = manager.selectTopK(2)
    #expect(selected.count == 2)
    #expect(selected.contains("relay-a"))
    #expect(selected.contains("relay-c"))
}

// MARK: - Publication Tracking Tests

@Test
func relayPublicationTracksAckedRelays() {
    // With requiredAcks=1, quorum is achieved with single ack (backward compatible)
    var publication = RelayPublication(
        envelopeId: Data(repeating: 0xAB, count: 32),
        payload: Data("test payload".utf8),
        targetRelays: Set(["relay-a", "relay-b", "relay-c"]),
        requiredAcks: 1
    )

    publication.ackedRelays.insert("relay-a")

    #expect(publication.ackedRelays.count == 1)
    #expect(!publication.isComplete)
    #expect(publication.isQuorumAchieved)
}

@Test
func relayPublicationQuorumRequiresMultipleAcks() {
    // With publishQuorum=2, need 2 acks for quorum
    var publication = RelayPublication(
        envelopeId: Data(repeating: 0xAB, count: 32),
        payload: Data("test payload".utf8),
        targetRelays: Set(["relay-a", "relay-b", "relay-c"]),
        requiredAcks: 2
    )
    
    publication.ackedRelays.insert("relay-a")
    
    #expect(publication.ackedRelays.count == 1)
    #expect(!publication.isQuorumAchieved)
    
    publication.ackedRelays.insert("relay-b")
    
    #expect(publication.ackedRelays.count == 2)
    #expect(publication.isQuorumAchieved)
}

@Test
func relayPublicationCompleteWhenAllAcked() {
    var publication = RelayPublication(
        envelopeId: Data(repeating: 0xAB, count: 32),
        payload: Data("test payload".utf8),
        targetRelays: Set(["relay-a", "relay-b"])
    )

    publication.ackedRelays.insert("relay-a")
    publication.ackedRelays.insert("relay-b")

    #expect(publication.isComplete)
    #expect(publication.isQuorumAchieved)
}

@Test
func relayPublicationFailsWhenRelaysFail() {
    var publication = RelayPublication(
        envelopeId: Data(repeating: 0xAB, count: 32),
        payload: Data("test payload".utf8),
        targetRelays: Set(["relay-a", "relay-b"])
    )

    publication.ackedRelays.insert("relay-a")
    publication.failedRelays.insert("relay-b")

    #expect(publication.isComplete)
}

// MARK: - Relay Config Tests

@Test
func relayTransportConfigDefaultValues() {
    let config = RelayTransportConfig.default

    #expect(config.publishQuorum == 2)
    #expect(config.maxActiveRelays == 5)
    #expect(config.baseBackoffSeconds == 1.0)
    #expect(config.maxBackoffSeconds == 60.0)
    #expect(config.backoffJitterFactor == 0.3)
    #expect(config.heartbeatIntervalSeconds == 30.0)
    #expect(config.connectionTimeoutSeconds == 10.0)
}

// MARK: - Relay Descriptor Tests

@Test
func relayDescriptorDerivesIdFromURL() {
    let url = URL(string: "wss://relay1.example.com/ws")!
    let descriptor = RelayDescriptor(url: url)

    #expect(descriptor.relayId == "relay1.example.com/ws")
    #expect(descriptor.url == url)
    #expect(descriptor.lastKnownHealthScore == RelayHealth.initialScore)
}

@Test
func relayDescriptorUsesExplicitId() {
    let url = URL(string: "wss://relay1.example.com/ws")!
    let descriptor = RelayDescriptor(url: url, relayId: "custom-id")

    #expect(descriptor.relayId == "custom-id")
}

@Test
func relayConfigFromDescriptor() {
    let url = URL(string: "wss://relay1.example.com/ws")!
    let descriptor = RelayDescriptor(url: url, tags: ["us-east"], weight: 5)
    let config = RelayConfig(descriptor: descriptor, priority: 3)

    #expect(config.relayId == descriptor.relayId)
    #expect(config.wsURL == url)
    #expect(config.priority == 3)
}

// MARK: - Delivery Deduplication Tests

@Test
func deduplicatorAcceptsFirstOccurrence() {
    var dedup = DeliveryDeduplicator(maxCapacity: 100)
    let envelopeId = Data(repeating: 0xAA, count: 32)

    let isNew = dedup.insertIfNew(envelopeId)

    #expect(isNew == true)
    #expect(dedup.contains(envelopeId))
    #expect(dedup.count == 1)
}

@Test
func deduplicatorRejectsDuplicate() {
    var dedup = DeliveryDeduplicator(maxCapacity: 100)
    let envelopeId = Data(repeating: 0xBB, count: 32)

    let first = dedup.insertIfNew(envelopeId)
    let second = dedup.insertIfNew(envelopeId)

    #expect(first == true)
    #expect(second == false)
    #expect(dedup.count == 1)
}

@Test
func deduplicatorEvictsOldestWhenFull() {
    var dedup = DeliveryDeduplicator(maxCapacity: 3)

    let id1 = Data(repeating: 0x01, count: 4)
    let id2 = Data(repeating: 0x02, count: 4)
    let id3 = Data(repeating: 0x03, count: 4)
    let id4 = Data(repeating: 0x04, count: 4)

    _ = dedup.insertIfNew(id1)
    _ = dedup.insertIfNew(id2)
    _ = dedup.insertIfNew(id3)

    #expect(dedup.count == 3)
    #expect(dedup.contains(id1))

    // Inserting a 4th should evict id1
    let isNew = dedup.insertIfNew(id4)
    #expect(isNew == true)
    #expect(dedup.count == 3)
    #expect(!dedup.contains(id1))
    #expect(dedup.contains(id4))
}

@Test
func deduplicatorAllowsReinsertAfterEviction() {
    var dedup = DeliveryDeduplicator(maxCapacity: 2)

    let id1 = Data(repeating: 0x01, count: 4)
    let id2 = Data(repeating: 0x02, count: 4)
    let id3 = Data(repeating: 0x03, count: 4)

    _ = dedup.insertIfNew(id1)
    _ = dedup.insertIfNew(id2)
    _ = dedup.insertIfNew(id3) // evicts id1

    // id1 was evicted, so it should be accepted again
    let reinserted = dedup.insertIfNew(id1)
    #expect(reinserted == true)
}

@Test
func deduplicatorHandlesMultipleDistinctIds() {
    var dedup = DeliveryDeduplicator(maxCapacity: 1000)

    for i: UInt8 in 0..<100 {
        let id = Data(repeating: i, count: 8)
        let isNew = dedup.insertIfNew(id)
        #expect(isNew == true)
    }

    #expect(dedup.count == 100)

    // All should be duplicates now
    for i: UInt8 in 0..<100 {
        let id = Data(repeating: i, count: 8)
        let isNew = dedup.insertIfNew(id)
        #expect(isNew == false)
    }
}

// MARK: - Inbound Delivery Tests

@Test
func inboundDeliveryStoresFields() {
    let delivery = InboundDelivery(
        envelopeId: Data(repeating: 0xAA, count: 32),
        payload: Data("hello".utf8),
        metadata: Data("meta".utf8),
        receivedFrom: "relay-1"
    )

    #expect(delivery.envelopeId == Data(repeating: 0xAA, count: 32))
    #expect(delivery.payload == Data("hello".utf8))
    #expect(delivery.metadata == Data("meta".utf8))
    #expect(delivery.receivedFrom == "relay-1")
    #expect(delivery.ackedAt == nil)
}

// MARK: - URL-Based Relay Management Tests

@Test
func relayTransportSetRelaysConfiguresFromURLs() async {
    let transport = RelayTransport(
        config: .default,
        wayfarerId: "test-wayfarer"
    )

    let urls = [
        URL(string: "wss://relay1.example.com/ws")!,
        URL(string: "wss://relay2.example.com/ws")!,
        URL(string: "wss://relay3.example.com/ws")!,
    ]

    await transport.setRelays(urls)
    let descriptors = await transport.listRelayDescriptors()

    #expect(descriptors.count == 3)
}

@Test
func relayTransportAddRemoveRelayByURL() async {
    let transport = RelayTransport(
        config: .default,
        wayfarerId: "test-wayfarer"
    )

    let url = URL(string: "wss://relay1.example.com/ws")!
    await transport.addRelay(url)

    var descriptors = await transport.listRelayDescriptors()
    #expect(descriptors.count == 1)
    #expect(descriptors[0].url == url)

    await transport.removeRelay(url)
    descriptors = await transport.listRelayDescriptors()
    #expect(descriptors.count == 0)
}

@Test
func relayTransportListRelayDescriptorsIncludesHealthScore() async {
    let transport = RelayTransport(
        config: .default,
        wayfarerId: "test-wayfarer"
    )

    let url = URL(string: "wss://relay1.example.com/ws")!
    await transport.addRelay(url)

    let descriptors = await transport.listRelayDescriptors()
    #expect(descriptors.count == 1)
    #expect(descriptors[0].lastKnownHealthScore == RelayHealth.initialScore)
}

// MARK: - Relay Scoring Tests

@Test
func scoreIncreasesOnSuccess() {
    var scoring = RelayScoring(relays: ["relay-a"])
    
    // Record several successful deliveries
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 50.0)
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 60.0)
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 70.0)
    
    let score = scoring.score(for: "relay-a")
    
    // Score should be high due to successful deliveries
    #expect(score > 0.5)
}

@Test
func scoreDecreasesOnFailure() {
    var scoring = RelayScoring(relays: ["relay-a"])
    
    // Record successful deliveries first
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 50.0)
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 60.0)
    
    let scoreBeforeFailure = scoring.score(for: "relay-a")
    
    // Record failures
    scoring.recordDeliveryFailure(relayId: "relay-a")
    scoring.recordDeliveryFailure(relayId: "relay-a")
    
    let scoreAfterFailure = scoring.score(for: "relay-a")
    
    // Score should decrease after failures
    #expect(scoreAfterFailure < scoreBeforeFailure)
}

@Test
func relaySortingByScore() {
    var scoring = RelayScoring(relays: ["relay-a", "relay-b", "relay-c"])
    
    // Best performer
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 30.0)
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 30.0)
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 30.0)
    
    // Medium performer
    scoring.recordDeliverySuccess(relayId: "relay-b", latencyMs: 100.0)
    scoring.recordDeliverySuccess(relayId: "relay-b", latencyMs: 100.0)
    
    // Poor performer with failures
    scoring.recordDeliveryFailure(relayId: "relay-c")
    scoring.recordDeliveryFailure(relayId: "relay-c")
    
    let sorted = scoring.relaysSortedByScore()
    
    // relay-a should be first (best), relay-c last (worst)
    #expect(sorted[0] == "relay-a")
    #expect(sorted[2] == "relay-c")
}

@Test
func scoreDecayOverTime() {
    var scoring = RelayScoring(relays: ["relay-a"], config: RelayScoring.ScoringConfig(
        inactivityDecayPerHour: 0.1
    ))
    
    // Record success with timestamp
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 50.0)
    
    let scoreBeforeDecay = scoring.score(for: "relay-a")
    #expect(scoreBeforeDecay > 0.5)
    
    // Simulate 2 hours of inactivity by setting lastActivityAt to 2 hours ago
    // The decay is applied based on time since lastActivityAt
    let twoHoursAgo = Date().addingTimeInterval(-7200)
    if var metrics = scoring.metrics["relay-a"] {
        metrics.lastActivityAt = twoHoursAgo
        scoring.metrics["relay-a"] = metrics
    }
    
    scoring.applyInactivityDecay(referenceTime: Date())
    
    let scoreAfterDecay = scoring.score(for: "relay-a")
    
    // Score should decrease after inactivity decay is applied
    #expect(scoreAfterDecay < scoreBeforeDecay)
}

@Test
func blackholePenaltyApplied() {
    var scoring = RelayScoring(relays: ["relay-a"], config: RelayScoring.ScoringConfig(
        blackholePenalty: 0.2
    ))
    
    // Start with good score
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 50.0)
    let goodScore = scoring.score(for: "relay-a")
    
    // Record blackhole behavior (accepts publish but no ack)
    scoring.recordBlackhole(relayId: "relay-a")
    scoring.recordBlackhole(relayId: "relay-a")
    
    let scoreAfterBlackhole = scoring.score(for: "relay-a")
    
    // Score should be penalized for blackhole behavior
    #expect(scoreAfterBlackhole < goodScore)
}

@Test
func disconnectPenaltyApplied() {
    var scoring = RelayScoring(relays: ["relay-a"], config: RelayScoring.ScoringConfig(
        disconnectPenalty: 0.1
    ))
    
    // Start with good score
    scoring.recordDeliverySuccess(relayId: "relay-a", latencyMs: 50.0)
    let goodScore = scoring.score(for: "relay-a")
    
    // Record disconnects
    scoring.recordDisconnect(relayId: "relay-a")
    scoring.recordDisconnect(relayId: "relay-a")
    
    let scoreAfterDisconnect = scoring.score(for: "relay-a")
    
    // Score should be penalized for disconnects
    #expect(scoreAfterDisconnect < goodScore)
}

// MARK: - Adaptive Publish Width Tests

@Test
func adaptiveWidthIncreasesWhenUnhealthy() {
    var adaptiveWidth = AdaptivePublishWidth(minWidth: 1, maxWidth: 5, initialWidth: 2)
    
    // Record several failures
    adaptiveWidth.recordFailure()
    adaptiveWidth.recordFailure()
    
    // Width should increase when unhealthy
    #expect(adaptiveWidth.getWidth() > 2)
}

@Test
func adaptiveWidthDecreasesWhenStable() {
    var adaptiveWidth = AdaptivePublishWidth(minWidth: 1, maxWidth: 5, initialWidth: 3)
    
    // Record several successes
    adaptiveWidth.recordSuccess()
    adaptiveWidth.recordSuccess()
    adaptiveWidth.recordSuccess()
    adaptiveWidth.recordSuccess()
    
    // Width should decrease when stable
    #expect(adaptiveWidth.getWidth() < 3)
}

@Test
func adaptiveWidthClampedToMin() {
    var adaptiveWidth = AdaptivePublishWidth(minWidth: 1, maxWidth: 5, initialWidth: 1)
    
    // Even with failures, should not go below min
    for _ in 0..<10 {
        adaptiveWidth.recordFailure()
    }
    
    #expect(adaptiveWidth.getWidth() >= 1)
}

@Test
func adaptiveWidthClampedToMax() {
    var adaptiveWidth = AdaptivePublishWidth(minWidth: 1, maxWidth: 5, initialWidth: 5)
    
    // Even with successes, should not go above max
    for _ in 0..<20 {
        adaptiveWidth.recordSuccess()
    }
    
    #expect(adaptiveWidth.getWidth() <= 5)
}

@Test
func adaptiveWidthRespectsConsecutiveFailures() {
    var adaptiveWidth = AdaptivePublishWidth(minWidth: 1, maxWidth: 5, initialWidth: 2)
    
    // Two consecutive failures should trigger width increase
    adaptiveWidth.recordFailure()
    adaptiveWidth.recordFailure()
    
    // Width must increase after 2 consecutive failures
    #expect(adaptiveWidth.getWidth() >= 3)
}

@Test
func adaptiveWidthRespectsConsecutiveSuccesses() {
    var adaptiveWidth = AdaptivePublishWidth(minWidth: 1, maxWidth: 5, initialWidth: 4)
    
    // Three consecutive successes should trigger width decrease
    adaptiveWidth.recordSuccess()
    adaptiveWidth.recordSuccess()
    adaptiveWidth.recordSuccess()
    
    // Width must decrease after 3 consecutive successes
    #expect(adaptiveWidth.getWidth() <= 3)
}

@Test
func adaptiveWidthStatistics() {
    var adaptiveWidth = AdaptivePublishWidth(minWidth: 1, maxWidth: 5, initialWidth: 2, windowSize: 5)
    
    adaptiveWidth.recordSuccess()
    adaptiveWidth.recordSuccess()
    adaptiveWidth.recordFailure()
    
    let stats = adaptiveWidth.statistics
    
    #expect(stats.currentWidth == 2)
    #expect(stats.minWidth == 1)
    #expect(stats.maxWidth == 5)
    #expect(stats.healthyRatio > 0.5)
    #expect(stats.consecutiveFailures == 1)
    // After recording success, success, failure: consecutive successes reset to 0, failures to 1
    #expect(stats.consecutiveSuccesses == 0)
}

@Test
func adaptiveWidthReset() {
    var adaptiveWidth = AdaptivePublishWidth(minWidth: 1, maxWidth: 5, initialWidth: 3)
    
    // Change width
    adaptiveWidth.recordFailure()
    adaptiveWidth.recordFailure()
    #expect(adaptiveWidth.getWidth() != 3)
    
    // Reset
    adaptiveWidth.reset()
    
    // Should be back to initial
    #expect(adaptiveWidth.getWidth() == 3)
    #expect(adaptiveWidth.statistics.recentOutcomes.isEmpty)
}

// MARK: - Forward Success Tracking Tests

@Test
func forwardSuccessScore() {
    var scoring = RelayScoring(relays: ["relay-a"])
    
    // Record forward successes
    scoring.recordForwardSuccess(relayId: "relay-a")
    scoring.recordForwardSuccess(relayId: "relay-a")
    scoring.recordForwardSuccess(relayId: "relay-a")
    
    let score = scoring.score(for: "relay-a")
    
    // Score should reflect forward success
    #expect(score > 0.5)
}

@Test
func forwardFailurePenalty() {
    var scoring = RelayScoring(relays: ["relay-a"])
    
    // Start with good score
    scoring.recordForwardSuccess(relayId: "relay-a")
    scoring.recordForwardSuccess(relayId: "relay-a")
    let goodScore = scoring.score(for: "relay-a")
    
    // Add failures
    scoring.recordForwardFailure(relayId: "relay-a")
    scoring.recordForwardFailure(relayId: "relay-a")
    
    let scoreAfterFailure = scoring.score(for: "relay-a")
    
    // Score should decrease with forward failures
    #expect(scoreAfterFailure < goodScore)
}
