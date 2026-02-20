import Foundation

// MARK: - Relay Configuration

/// Configuration for a single relay server.
public struct RelayConfig: Codable, Equatable, Sendable {
    public let relayId: String
    public let wsURL: URL
    public let priority: Int
    public let maxConcurrentPublications: Int
    
    public init(
        relayId: String,
        wsURL: URL,
        priority: Int = 0,
        maxConcurrentPublications: Int = 10
    ) {
        self.relayId = relayId
        self.wsURL = wsURL
        self.priority = priority
        self.maxConcurrentPublications = maxConcurrentPublications
    }
}

/// Configuration for relay transport behavior.
public struct RelayTransportConfig: Codable, Equatable, Sendable {
    /// Number of relays to publish to simultaneously (K of N).
    public let publishQuorum: Int
    
    /// Maximum number of relays to maintain connections to.
    public let maxActiveRelays: Int
    
    /// Base backoff duration in seconds.
    public let baseBackoffSeconds: Double
    
    /// Maximum backoff duration in seconds.
    public let maxBackoffSeconds: Double
    
    /// Jitter factor for exponential backoff (0.0 to 1.0).
    public let backoffJitterFactor: Double
    
    /// Heartbeat interval in seconds.
    public let heartbeatIntervalSeconds: Double
    
    /// Connection timeout in seconds.
    public let connectionTimeoutSeconds: Double
    
    /// Default configuration values.
    public static let `default` = RelayTransportConfig(
        publishQuorum: 2,
        maxActiveRelays: 5,
        baseBackoffSeconds: 1.0,
        maxBackoffSeconds: 60.0,
        backoffJitterFactor: 0.3,
        heartbeatIntervalSeconds: 30.0,
        connectionTimeoutSeconds: 10.0
    )
    
    public init(
        publishQuorum: Int = 2,
        maxActiveRelays: Int = 5,
        baseBackoffSeconds: Double = 1.0,
        maxBackoffSeconds: Double = 60.0,
        backoffJitterFactor: Double = 0.3,
        heartbeatIntervalSeconds: Double = 30.0,
        connectionTimeoutSeconds: Double = 10.0
    ) {
        self.publishQuorum = publishQuorum
        self.maxActiveRelays = maxActiveRelays
        self.baseBackoffSeconds = baseBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.backoffJitterFactor = backoffJitterFactor
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
    }
}

// MARK: - Relay Transport Errors

public enum RelayTransportError: Error, Equatable {
    case notStarted
    case alreadyStarted
    case noRelaysConfigured
    case insufficientRelays(available: Int, required: Int)
    case connectionFailed(String)
    case publishFailed(String)
    case sendFailed(String)
    case timeout
}

// MARK: - Relay Health State

/// Health state for a single relay.
public struct RelayHealth: Equatable, Sendable {
    public let relayId: String
    public var consecutiveFailures: Int
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var backoffUntil: Date?
    public var currentScore: Double
    
    public static let initialScore: Double = 100.0
    public static let minScore: Double = 0.0
    public static let maxScore: Double = 200.0
    
    public init(relayId: String) {
        self.relayId = relayId
        self.consecutiveFailures = 0
        self.lastSuccessAt = nil
        self.lastAttemptAt = nil
        self.backoffUntil = nil
        self.currentScore = Self.initialScore
    }
    
    public var isHealthy: Bool {
        guard let backoffUntil else { return true }
        return Date() >= backoffUntil
    }
}

// MARK: - Publication Tracking

/// Tracks the state of an outbound publication to relays.
public struct RelayPublication: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let envelopeId: Data
    public let payload: Data
    public var targetRelays: Set<String>
    public var ackedRelays: Set<String>
    public var failedRelays: Set<String>
    public let createdAt: Date
    
    public init(
        id: UUID = UUID(),
        envelopeId: Data,
        payload: Data,
        targetRelays: Set<String>
    ) {
        self.id = id
        self.envelopeId = envelopeId
        self.payload = payload
        self.targetRelays = targetRelays
        self.ackedRelays = []
        self.failedRelays = []
        self.createdAt = Date()
    }
    
    public var isComplete: Bool {
        ackedRelays.count >= targetRelays.count - failedRelays.count
    }
    
    public var isQuorumAchieved: Bool {
        ackedRelays.count >= 1
    }
}

// MARK: - Relay Transport Protocol

/// Actor-isolated relay transport for persistent WebSocket connections to relay servers.
/// Provides K-of-N publish semantics with health scoring and automatic reconnection.
public actor RelayTransport {
    private let config: RelayTransportConfig
    private var relays: [String: RelayConfig]
    private var connections: [String: any RelayConnectionProtocol]
    private var health: [String: RelayHealth]
    private var publications: [UUID: RelayPublication]
    private var isRunning: Bool
    
    public var onEnvelopeReceived: ((Data) async -> Void)?
    public var onAckReceived: ((Data, String) async -> Void)?
    
    public init(config: RelayTransportConfig = .default, relayConfigs: [RelayConfig] = []) {
        self.config = config
        self.relays = Dictionary(uniqueKeysWithValues: relayConfigs.map { ($0.relayId, $0) })
        self.connections = [:]
        self.health = relays.keys.reduce(into: [:]) { $0[$1] = RelayHealth(relayId: $1) }
        self.publications = [:]
        self.isRunning = false
    }
    
    // MARK: - Lifecycle
    
    public func start() async throws {
        guard !isRunning else {
            throw RelayTransportError.alreadyStarted
        }
        
        guard !relays.isEmpty else {
            throw RelayTransportError.noRelaysConfigured
        }
        
        isRunning = true
        
        let activeRelays = selectRelaysForConnections(count: config.maxActiveRelays)
        
        for relayId in activeRelays {
            await connect(relayId: relayId)
        }
    }
    
    public func stop() async {
        guard isRunning else { return }
        
        for (_, connection) in connections {
            await connection.disconnect()
        }
        
        connections.removeAll()
        isRunning = false
    }
    
    public func tick(now: Date) async {
        guard isRunning else { return }
        
        for (relayId, healthState) in health {
            if let backoffUntil = healthState.backoffUntil, now >= backoffUntil {
                health[relayId]?.backoffUntil = nil
                await connect(relayId: relayId)
            }
        }
    }
    
    // MARK: - Configuration
    
    public func addRelay(_ config: RelayConfig) {
        guard !isRunning else { return }
        relays[config.relayId] = config
        health[config.relayId] = RelayHealth(relayId: config.relayId)
    }
    
    public func removeRelay(relayId: String) {
        guard !isRunning else { return }
        relays.removeValue(forKey: relayId)
        health.removeValue(forKey: relayId)
    }
    
    public func listRelays() -> [RelayConfig] {
        Array(relays.values).sorted { $0.priority > $1.priority }
    }
    
    // MARK: - Publishing
    
    public func publish(envelopeId: Data, payload: Data) async throws -> UUID {
        guard isRunning else {
            throw RelayTransportError.notStarted
        }
        
        let selectedRelays = selectRelaysForPublish(count: config.publishQuorum)
        
        guard selectedRelays.count >= config.publishQuorum else {
            throw RelayTransportError.insufficientRelays(
                available: selectedRelays.count,
                required: config.publishQuorum
            )
        }
        
        let publication = RelayPublication(
            envelopeId: envelopeId,
            payload: payload,
            targetRelays: Set(selectedRelays)
        )
        
        publications[publication.id] = publication
        
        for relayId in selectedRelays {
            await sendToRelay(relayId: relayId, publication: publication)
        }
        
        return publication.id
    }
    
    public func getPublication(id: UUID) -> RelayPublication? {
        publications[id]
    }
    
    public func awaitPublicationQuorum(id: UUID, timeout: TimeInterval = 30.0) async -> Bool {
        guard let publication = publications[id] else { return false }
        
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            if let current = publications[id], current.isQuorumAchieved {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        return publications[id]?.isQuorumAchieved ?? false
    }
    
    // MARK: - Connection Management
    
    private func connect(relayId: String) async {
        guard let relayConfig = relays[relayId] else { return }
        
        health[relayId]?.lastAttemptAt = Date()
        
        let connection = await createConnection(config: relayConfig)
        await connection.connect()
        
        let isConnected = await connection.isConnected
        if isConnected {
            connections[relayId] = connection
            health[relayId]?.currentScore = min(RelayHealth.maxScore, health[relayId]?.currentScore ?? 0 + 10)
            await startReceiving(on: connection, relayId: relayId)
        } else {
            await recordFailure(relayId: relayId)
        }
    }
    
    private func createConnection(config: RelayConfig) async -> any RelayConnectionProtocol {
        await WebSocketRelayConnection(config: config)
    }
    
    private func startReceiving(on connection: any RelayConnectionProtocol, relayId: String) async {
        Task {
            while await connection.isConnected {
                if let frame = await connection.receive() {
                    await handleIncomingFrame(frame, from: relayId)
                }
            }
        }
    }
    
    private func handleIncomingFrame(_ frame: RelayFrame, from relayId: String) async {
        switch frame {
        case .envelope(let data):
            await onEnvelopeReceived?(data)
        case .ack(let envelopeId):
            await handleAck(envelopeId: envelopeId, from: relayId)
        case .nack(let envelopeId, _):
            await handleNack(envelopeId: envelopeId, from: relayId)
        case .heartbeat:
            break
        case .heartbeatAck:
            health[relayId]?.currentScore = min(RelayHealth.maxScore, health[relayId]?.currentScore ?? 0 + 5)
        }
    }
    
    private func handleAck(envelopeId: Data, from relayId: String) async {
        for (id, var publication) in publications {
            if publication.envelopeId == envelopeId && publication.targetRelays.contains(relayId) {
                publication.ackedRelays.insert(relayId)
                publications[id] = publication
                await onAckReceived?(envelopeId, relayId)
                break
            }
        }
        
        health[relayId]?.consecutiveFailures = 0
        health[relayId]?.lastSuccessAt = Date()
        health[relayId]?.currentScore = min(RelayHealth.maxScore, health[relayId]?.currentScore ?? 0 + 5)
    }
    
    private func handleNack(envelopeId: Data, from relayId: String) async {
        for (id, var publication) in publications {
            if publication.envelopeId == envelopeId && publication.targetRelays.contains(relayId) {
                publication.failedRelays.insert(relayId)
                publications[id] = publication
                break
            }
        }
        
        await recordFailure(relayId: relayId)
    }
    
    private func sendToRelay(relayId: String, publication: RelayPublication) async {
        guard let connection = connections[relayId], await connection.isConnected else {
            await recordFailure(relayId: relayId)
            return
        }
        
        let frame = RelayFrame.envelope(publication.payload)
        let success = await connection.send(frame)
        
        if !success {
            await recordFailure(relayId: relayId)
        }
    }
    
    private func recordFailure(relayId: String) async {
        guard var healthState = health[relayId] else { return }
        
        healthState.consecutiveFailures += 1
        healthState.currentScore = max(
            RelayHealth.minScore,
            healthState.currentScore - 20
        )
        
        let backoff = calculateBackoff(
            failures: healthState.consecutiveFailures,
            base: config.baseBackoffSeconds,
            maxBackoff: config.maxBackoffSeconds,
            jitter: config.backoffJitterFactor
        )
        
        healthState.backoffUntil = Date().addingTimeInterval(backoff)
        health[relayId] = healthState
        
        connections.removeValue(forKey: relayId)
    }
    
    // MARK: - Relay Selection
    
    private func selectRelaysForConnections(count: Int) -> [String] {
        selectTopRelays(count: min(count, relays.count))
    }
    
    private func selectRelaysForPublish(count: Int) -> [String] {
        selectTopRelays(count: min(count, relays.count))
    }
    
    private func selectTopRelays(count: Int) -> [String] {
        relays.values
            .filter { health[$0.relayId]?.isHealthy ?? true }
            .sorted { lhs, rhs in
                let lhsScore = health[lhs.relayId]?.currentScore ?? 0
                let rhsScore = health[rhs.relayId]?.currentScore ?? 0
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return lhs.priority > rhs.priority
            }
            .prefix(count)
            .map { $0.relayId }
    }
    
    private func calculateBackoff(failures: Int, base: Double, maxBackoff: Double, jitter: Double) -> Double {
        let exponential = base * pow(2.0, Double(min(failures, 10)))
        let capped = Swift.min(exponential, maxBackoff)
        let jitterRange = capped * jitter
        let jitterValue = Double.random(in: -jitterRange...jitterRange)
        return Swift.max(0, capped + jitterValue)
    }
}

// MARK: - Connection Protocol

/// Protocol for relay connections (allows testing with mocks).
public protocol RelayConnectionProtocol: Actor {
    var isConnected: Bool { get }
    func connect() async
    func disconnect() async
    func send(_ frame: RelayFrame) async -> Bool
    func receive() async -> RelayFrame?
}
