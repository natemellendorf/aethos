import Foundation

// MARK: - Relay Descriptor

/// Public-facing descriptor for a relay endpoint.
/// Used by callers to configure and inspect relay state.
public struct RelayDescriptor: Equatable, Sendable {
    public let url: URL
    public let relayId: String
    public let tags: [String]
    public let weight: Int
    public let lastKnownHealthScore: Double

    public init(
        url: URL,
        relayId: String = "",
        tags: [String] = [],
        weight: Int = 1,
        lastKnownHealthScore: Double = RelayHealth.initialScore
    ) {
        self.url = url
        self.relayId = relayId.isEmpty ? Self.deriveRelayId(from: url) : relayId
        self.tags = tags
        self.weight = weight
        self.lastKnownHealthScore = lastKnownHealthScore
    }

    /// Derive a stable relay ID from a URL (host + path).
    public static func deriveRelayId(from url: URL) -> String {
        let host = url.host ?? "unknown"
        let path = url.path.isEmpty ? "" : url.path
        return "\(host)\(path)"
    }
}

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

    /// Create a RelayConfig from a RelayDescriptor.
    public init(descriptor: RelayDescriptor, priority: Int = 0) {
        self.relayId = descriptor.relayId
        self.wsURL = descriptor.url
        self.priority = priority
        self.maxConcurrentPublications = 10
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

// MARK: - Inbound Delivery Tracking

/// Tracks a received delivery for deduplication.
public struct InboundDelivery: Equatable, Sendable {
    public let envelopeId: Data
    public let payload: Data
    public let metadata: Data
    public let receivedFrom: String
    public let receivedAt: Date
    public let ackedAt: Date?

    public init(
        envelopeId: Data,
        payload: Data,
        metadata: Data = Data(),
        receivedFrom: String,
        receivedAt: Date = Date(),
        ackedAt: Date? = nil
    ) {
        self.envelopeId = envelopeId
        self.payload = payload
        self.metadata = metadata
        self.receivedFrom = receivedFrom
        self.receivedAt = receivedAt
        self.ackedAt = ackedAt
    }
}

/// Deduplicates inbound deliveries by envelope ID.
/// Thread-safe when used within an actor.
public struct DeliveryDeduplicator: Sendable {
    private var seen: Set<Data>
    private var orderedIds: [Data]
    private let maxCapacity: Int

    public init(maxCapacity: Int = 10_000) {
        self.seen = []
        self.orderedIds = []
        self.maxCapacity = maxCapacity
    }

    /// Returns true if this envelope ID has NOT been seen before (i.e., is new).
    /// Returns false if it is a duplicate.
    public mutating func insertIfNew(_ envelopeId: Data) -> Bool {
        guard !seen.contains(envelopeId) else { return false }

        seen.insert(envelopeId)
        orderedIds.append(envelopeId)

        if orderedIds.count > maxCapacity {
            let evicted = orderedIds.removeFirst()
            seen.remove(evicted)
        }

        return true
    }

    public func contains(_ envelopeId: Data) -> Bool {
        seen.contains(envelopeId)
    }

    public var count: Int { seen.count }
}

// MARK: - Relay Transport

/// Actor-isolated relay transport for persistent WebSocket connections to relay servers.
/// Provides K-of-N publish semantics with health scoring and automatic reconnection.
/// Supports inbound delivery with deduplication and ack-back.
public actor RelayTransport {
    private let config: RelayTransportConfig
    private let wayfarerId: String
    private var relays: [String: RelayConfig]
    private var connections: [String: any RelayConnectionProtocol]
    private var health: [String: RelayHealth]
    private var publications: [UUID: RelayPublication]
    private var deliveryDeduplicator: DeliveryDeduplicator
    private var inboundDeliveries: [Data: InboundDelivery]
    private var isRunning: Bool

    /// Called when a new (non-duplicate) delivery arrives.
    public var onDeliveryReceived: ((InboundDelivery) async -> Void)?

    /// Called when a publish ack arrives from a relay.
    public var onPublishAcked: ((Data, String) async -> Void)?

    /// Legacy callback for raw envelope data.
    public var onEnvelopeReceived: ((Data) async -> Void)?

    /// Legacy callback for ack data.
    public var onAckReceived: ((Data, String) async -> Void)?

    public init(
        config: RelayTransportConfig = .default,
        wayfarerId: String = "",
        relayConfigs: [RelayConfig] = []
    ) {
        self.config = config
        self.wayfarerId = wayfarerId
        self.relays = Dictionary(uniqueKeysWithValues: relayConfigs.map { ($0.relayId, $0) })
        self.connections = [:]
        self.health = relays.keys.reduce(into: [:]) { $0[$1] = RelayHealth(relayId: $1) }
        self.publications = [:]
        self.deliveryDeduplicator = DeliveryDeduplicator()
        self.inboundDeliveries = [:]
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

    // MARK: - URL-Based Relay Management

    /// Replace all relays with the given URLs.
    /// Each URL is converted to a RelayDescriptor with default settings.
    /// Transport must be stopped before calling this.
    public func setRelays(_ urls: [URL]) {
        guard !isRunning else { return }
        relays.removeAll()
        health.removeAll()
        for (index, url) in urls.enumerated() {
            let descriptor = RelayDescriptor(url: url)
            let relayConfig = RelayConfig(descriptor: descriptor, priority: urls.count - index)
            relays[relayConfig.relayId] = relayConfig
            health[relayConfig.relayId] = RelayHealth(relayId: relayConfig.relayId)
        }
    }

    /// Add a relay by URL.
    public func addRelay(_ url: URL) {
        guard !isRunning else { return }
        let descriptor = RelayDescriptor(url: url)
        let relayConfig = RelayConfig(descriptor: descriptor)
        relays[relayConfig.relayId] = relayConfig
        health[relayConfig.relayId] = RelayHealth(relayId: relayConfig.relayId)
    }

    /// Remove a relay by URL.
    public func removeRelay(_ url: URL) {
        guard !isRunning else { return }
        let relayId = RelayDescriptor.deriveRelayId(from: url)
        relays.removeValue(forKey: relayId)
        health.removeValue(forKey: relayId)
    }

    /// List all configured relays as descriptors, sorted by priority descending.
    public func listRelayDescriptors() -> [RelayDescriptor] {
        relays.values
            .sorted { $0.priority > $1.priority }
            .map { config in
                RelayDescriptor(
                    url: config.wsURL,
                    relayId: config.relayId,
                    weight: config.priority,
                    lastKnownHealthScore: health[config.relayId]?.currentScore
                        ?? RelayHealth.initialScore
                )
            }
    }

    // MARK: - Legacy Config API (RelayConfig-based)

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
            await sendPublishToRelay(relayId: relayId, publication: publication)
        }

        return publication.id
    }

    public func getPublication(id: UUID) -> RelayPublication? {
        publications[id]
    }

    public func awaitPublicationQuorum(id: UUID, timeout: TimeInterval = 30.0) async -> Bool {
        guard publications[id] != nil else { return false }

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let current = publications[id], current.isQuorumAchieved {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return publications[id]?.isQuorumAchieved ?? false
    }

    // MARK: - Inbound Delivery Access

    /// Retrieve a received delivery by envelope ID (nil if not yet received or deduplicated away).
    public func getDelivery(envelopeId: Data) -> InboundDelivery? {
        inboundDeliveries[envelopeId]
    }

    /// Check if a delivery has already been received (dedupe check).
    public func hasReceivedDelivery(envelopeId: Data) -> Bool {
        deliveryDeduplicator.contains(envelopeId)
    }

    // MARK: - Connection Management

    private func connect(relayId: String) async {
        guard let relayConfig = relays[relayId] else { return }

        health[relayId]?.lastAttemptAt = Date()

        let connection = WebSocketRelayConnection(config: relayConfig)
        await connection.connect()

        let isConnected = await connection.isConnected
        if isConnected {
            connections[relayId] = connection

            let currentScore = health[relayId]?.currentScore ?? 0
            health[relayId]?.currentScore = min(RelayHealth.maxScore, currentScore + 10)

            if !wayfarerId.isEmpty {
                let helloFrame = RelayFrame.clientHello(wayfarerId: wayfarerId)
                _ = await connection.send(helloFrame)
            }

            await startReceiving(on: connection, relayId: relayId)
        } else {
            await recordFailure(relayId: relayId)
        }
    }

    private func startReceiving(
        on connection: any RelayConnectionProtocol, relayId: String
    ) async {
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
        case .deliver(let envelopeId, let payload, let metadata):
            await handleDelivery(
                envelopeId: envelopeId, payload: payload,
                metadata: metadata, from: relayId
            )

        case .ack(let envelopeId):
            await handlePublishAck(envelopeId: envelopeId, from: relayId)

        case .nack(let envelopeId, _):
            await handleNack(envelopeId: envelopeId, from: relayId)

        case .heartbeat:
            if let connection = connections[relayId] {
                _ = await connection.send(.heartbeatAck)
            }

        case .heartbeatAck:
            let currentScore = health[relayId]?.currentScore ?? 0
            health[relayId]?.currentScore = min(RelayHealth.maxScore, currentScore + 5)

        case .envelope(let data):
            await onEnvelopeReceived?(data)

        case .clientHello, .publish, .relayPeerHello, .relayInventory, .relayForward:
            // These frames are not expected from a relay to a client.
            // Silently ignore; a production system might log a warning.
            break
        }
    }

    // MARK: - Inbound Delivery Handling

    private func handleDelivery(
        envelopeId: Data, payload: Data, metadata: Data, from relayId: String
    ) async {
        let isNew = deliveryDeduplicator.insertIfNew(envelopeId)

        // Always ack the relay, even for duplicates, so it stops retrying.
        await sendAckToRelay(envelopeId: envelopeId, relayId: relayId)

        guard isNew else { return }

        let delivery = InboundDelivery(
            envelopeId: envelopeId,
            payload: payload,
            metadata: metadata,
            receivedFrom: relayId
        )
        inboundDeliveries[envelopeId] = delivery

        health[relayId]?.consecutiveFailures = 0
        health[relayId]?.lastSuccessAt = Date()
        let currentScore = health[relayId]?.currentScore ?? 0
        health[relayId]?.currentScore = min(RelayHealth.maxScore, currentScore + 5)

        await onDeliveryReceived?(delivery)
    }

    private func sendAckToRelay(envelopeId: Data, relayId: String) async {
        guard let connection = connections[relayId],
              await connection.isConnected else { return }
        let ackFrame = RelayFrame.ack(envelopeId: envelopeId)
        _ = await connection.send(ackFrame)
    }

    // MARK: - Publish Ack Handling

    private func handlePublishAck(envelopeId: Data, from relayId: String) async {
        for (id, var publication) in publications {
            if publication.envelopeId == envelopeId && publication.targetRelays.contains(relayId) {
                publication.ackedRelays.insert(relayId)
                publications[id] = publication
                await onPublishAcked?(envelopeId, relayId)
                await onAckReceived?(envelopeId, relayId)
                break
            }
        }

        health[relayId]?.consecutiveFailures = 0
        health[relayId]?.lastSuccessAt = Date()
        let currentScore = health[relayId]?.currentScore ?? 0
        health[relayId]?.currentScore = min(RelayHealth.maxScore, currentScore + 5)
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

    // MARK: - Outbound Send

    private func sendPublishToRelay(relayId: String, publication: RelayPublication) async {
        guard let connection = connections[relayId],
              await connection.isConnected else {
            await recordFailure(relayId: relayId)
            return
        }

        let frame = RelayFrame.publish(
            envelopeId: publication.envelopeId,
            payload: publication.payload
        )
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

    private func calculateBackoff(
        failures: Int, base: Double, maxBackoff: Double, jitter: Double
    ) -> Double {
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
