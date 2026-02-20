import Foundation
import Testing
@testable import AethosCore

// MARK: - Relay Frame Tests

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
    let frame = RelayFrame.ack(envelopeId)
    
    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)
    
    #expect(decoded == .ack(envelopeId))
}

@Test
func relayFrameNackEncodeDecodeRoundTrip() throws {
    let envelopeId = Data(repeating: 0xCD, count: 32)
    let reason = "destination offline"
    let frame = RelayFrame.nack(envelopeId, reason)
    
    let encoded = try frame.encode()
    let decoded = try RelayFrame.decode(encoded)
    
    #expect(decoded == .nack(envelopeId, reason))
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
    
    let allUnique = results.reduce(true) { $0 && ($1.count == 2) }
    #expect(allUnique)
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
    var publication = RelayPublication(
        envelopeId: Data(repeating: 0xAB, count: 32),
        payload: Data("test payload".utf8),
        targetRelays: Set(["relay-a", "relay-b", "relay-c"])
    )
    
    publication.ackedRelays.insert("relay-a")
    
    #expect(publication.ackedRelays.count == 1)
    #expect(!publication.isComplete)
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
