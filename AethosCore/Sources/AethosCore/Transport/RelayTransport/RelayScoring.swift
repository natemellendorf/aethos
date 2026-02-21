import Foundation

// MARK: - Relay Scoring Model

/// Comprehensive relay scoring model with multi-factor evaluation.
/// Tracks delivery success, latency, uptime, and forward success.
/// Never auto-removes relays - only deprioritizes unhealthy ones.
public struct RelayScoring: Sendable {
    /// Per-relay metrics tracked over time
    public var metrics: [String: RelayMetrics]
    
    /// Configuration for scoring weights and decay
    public let config: ScoringConfig
    
    /// Weights for score components (must sum to 1.0)
    public struct ScoringConfig: Sendable {
        /// Weight for delivery success rate (0.0 to 1.0)
        public let deliveryWeight: Double
        /// Weight for latency performance (0.0 to 1.0)
        public let latencyWeight: Double
        /// Weight for connection uptime (0.0 to 1.0)
        public let uptimeWeight: Double
        /// Weight for forward/inventory success (0.0 to 1.0)
        public let forwardWeight: Double
        
        /// Default weights: delivery=0.4, latency=0.2, uptime=0.2, forward=0.2
        public static let `default` = ScoringConfig(
            deliveryWeight: 0.4,
            latencyWeight: 0.2,
            uptimeWeight: 0.2,
            forwardWeight: 0.2
        )
        
        /// Decay factor per hour of inactivity (0.0 to 1.0)
        public let inactivityDecayPerHour: Double
        /// Aggressive penalty for blackhole behavior
        public let blackholePenalty: Double
        /// Penalty per disconnect
        public let disconnectPenalty: Double
        /// Penalty per handshake failure
        public let handshakePenalty: Double
        /// Minimum score allowed
        public let minScore: Double
        /// Maximum score allowed
        public let maxScore: Double
        
        public init(
            deliveryWeight: Double = 0.4,
            latencyWeight: Double = 0.2,
            uptimeWeight: Double = 0.2,
            forwardWeight: Double = 0.2,
            inactivityDecayPerHour: Double = 0.05,
            blackholePenalty: Double = 0.3,
            disconnectPenalty: Double = 0.1,
            handshakePenalty: Double = 0.15,
            minScore: Double = 0.0,
            maxScore: Double = 1.0
        ) {
            self.deliveryWeight = deliveryWeight
            self.latencyWeight = latencyWeight
            self.uptimeWeight = uptimeWeight
            self.forwardWeight = forwardWeight
            self.inactivityDecayPerHour = inactivityDecayPerHour
            self.blackholePenalty = blackholePenalty
            self.disconnectPenalty = disconnectPenalty
            self.handshakePenalty = handshakePenalty
            self.minScore = minScore
            self.maxScore = maxScore
        }
    }
    
    public init(config: ScoringConfig = .default) {
        self.metrics = [:]
        self.config = config
    }
    
    public init(relays: [String], config: ScoringConfig = .default) {
        self.metrics = Dictionary(uniqueKeysWithValues: relays.map { ($0, RelayMetrics(relayId: $0)) })
        self.config = config
    }
    
    /// Get metrics for a relay (creates empty if not exists)
    public mutating func getOrCreateMetrics(for relayId: String) -> RelayMetrics {
        if let existing = metrics[relayId] {
            return existing
        }
        let newMetrics = RelayMetrics(relayId: relayId)
        metrics[relayId] = newMetrics
        return newMetrics
    }
    
    /// Record a successful delivery
    public mutating func recordDeliverySuccess(relayId: String, latencyMs: Double?) {
        var m = getOrCreateMetrics(for: relayId)
        m.successfulDeliveries += 1
        m.lastActivityAt = Date()
        
        if let latency = latencyMs {
            m.totalAckLatencyMs += latency
            m.averageAckLatency = m.totalAckLatencyMs / Double(m.successfulDeliveries)
        }
        
        m.consecutiveBlackholes = 0
        metrics[relayId] = m
    }
    
    /// Record a failed delivery
    public mutating func recordDeliveryFailure(relayId: String) {
        var m = getOrCreateMetrics(for: relayId)
        m.failedDeliveries += 1
        m.lastActivityAt = Date()
        m.consecutiveBlackholes += 1
        metrics[relayId] = m
    }
    
    /// Record a publish acceptance but no ACK (blackhole behavior)
    public mutating func recordBlackhole(relayId: String) {
        var m = getOrCreateMetrics(for: relayId)
        m.blackholeCount += 1
        m.consecutiveBlackholes += 1
        m.lastActivityAt = Date()
        metrics[relayId] = m
    }
    
    /// Record a connection disconnect
    public mutating func recordDisconnect(relayId: String) {
        var m = getOrCreateMetrics(for: relayId)
        m.disconnectCount += 1
        m.lastActivityAt = Date()
        metrics[relayId] = m
    }
    
    /// Record a handshake failure
    public mutating func recordHandshakeFailure(relayId: String) {
        var m = getOrCreateMetrics(for: relayId)
        m.handshakeFailureCount += 1
        m.lastActivityAt = Date()
        metrics[relayId] = m
    }
    
    /// Record connection established (for uptime tracking)
    public mutating func recordConnectionUp(relayId: String) {
        var m = getOrCreateMetrics(for: relayId)
        if let lastDown = m.lastConnectionDownAt {
            let downtime = Date().timeIntervalSince(lastDown)
            m.totalDowntimeSeconds += downtime
        }
        m.lastConnectionUpAt = Date()
        m.lastConnectionDownAt = nil
        metrics[relayId] = m
    }
    
    /// Record connection lost (for uptime tracking)
    public mutating func recordConnectionDown(relayId: String) {
        var m = getOrCreateMetrics(for: relayId)
        m.lastConnectionDownAt = Date()
        metrics[relayId] = m
    }
    
    /// Record forward/inventory success
    public mutating func recordForwardSuccess(relayId: String) {
        var m = getOrCreateMetrics(for: relayId)
        m.forwardSuccessCount += 1
        m.lastActivityAt = Date()
        metrics[relayId] = m
    }
    
    /// Record forward/inventory failure
    public mutating func recordForwardFailure(relayId: String) {
        var m = getOrCreateMetrics(for: relayId)
        m.forwardFailureCount += 1
        m.lastActivityAt = Date()
        metrics[relayId] = m
    }
    
    /// Apply inactivity decay to all relays
    public mutating func applyInactivityDecay(referenceTime: Date = Date()) {
        for (relayId, var m) in metrics {
            guard let lastActivity = m.lastActivityAt else { continue }
            
            let hoursInactive = referenceTime.timeIntervalSince(lastActivity) / 3600.0
            guard hoursInactive > 0 else { continue }
            
            let decay = config.inactivityDecayPerHour * hoursInactive
            m.inactivityDecayApplied += decay
            metrics[relayId] = m
        }
    }
    
    /// Calculate normalized score [0,1] for a relay
    public func calculateScore(for relayId: String) -> Double {
        guard let m = metrics[relayId] else {
            return 0.5 // Default neutral score for unknown relays
        }
        
        let deliveryScore = calculateDeliveryScore(metrics: m)
        let latencyScore = calculateLatencyScore(metrics: m)
        let uptimeScore = calculateUptimeScore(metrics: m)
        let forwardScore = calculateForwardScore(metrics: m)
        
        var totalScore = (
            deliveryScore * config.deliveryWeight +
            latencyScore * config.latencyWeight +
            uptimeScore * config.uptimeWeight +
            forwardScore * config.forwardWeight
        )
        
        // Apply inactivity decay
        totalScore -= m.inactivityDecayApplied
        
        // Apply blackhole penalty (aggressive for consecutive blackholes)
        if m.consecutiveBlackholes > 0 {
            let blackholePenalty = config.blackholePenalty * Double(m.consecutiveBlackholes)
            totalScore -= blackholePenalty
        }
        
        // Apply disconnect penalty
        if m.disconnectCount > 0 {
            totalScore -= config.disconnectPenalty * Double(m.disconnectCount)
        }
        
        // Apply handshake penalty
        if m.handshakeFailureCount > 0 {
            totalScore -= config.handshakePenalty * Double(m.handshakeFailureCount)
        }
        
        // Clamp to valid range
        return clampScore(totalScore)
    }
    
    /// Calculate delivery success rate score
    private func calculateDeliveryScore(metrics: RelayMetrics) -> Double {
        let total = metrics.successfulDeliveries + metrics.failedDeliveries
        guard total > 0 else { return 0.5 }
        return Double(metrics.successfulDeliveries) / Double(total)
    }
    
    /// Calculate latency score (lower is better, normalized)
    private func calculateLatencyScore(metrics: RelayMetrics) -> Double {
        guard let avgLatency = metrics.averageAckLatency, avgLatency > 0 else { return 0.5 }
        
        // Latency thresholds: <50ms = 1.0, >500ms = 0.0
        let score = 1.0 - ((avgLatency - 50) / 450)
        return clampScore(score)
    }
    
    /// Calculate uptime score based on total uptime percentage
    private func calculateUptimeScore(metrics: RelayMetrics) -> Double {
        guard let lastUp = metrics.lastConnectionUpAt else { return 0.5 }
        
        let totalTime = Date().timeIntervalSince(lastUp)
        guard totalTime > 0 else { return 1.0 }
        
        let uptime = totalTime - metrics.totalDowntimeSeconds
        return clampScore(uptime / totalTime)
    }
    
    /// Calculate forward/inventory success rate
    private func calculateForwardScore(metrics: RelayMetrics) -> Double {
        let total = metrics.forwardSuccessCount + metrics.forwardFailureCount
        guard total > 0 else { return 0.5 }
        return Double(metrics.forwardSuccessCount) / Double(total)
    }
    
    /// Clamp score to [min, max] range
    private func clampScore(_ score: Double) -> Double {
        Swift.max(config.minScore, Swift.min(config.maxScore, score))
    }
    
    /// Get all relays sorted by score (descending)
    public func relaysSortedByScore() -> [String] {
        metrics.keys.sorted { calculateScore(for: $0) > calculateScore(for: $1) }
    }
    
    /// Get top K relays by score
    public func topK(_ k: Int) -> [String] {
        Array(relaysSortedByScore().prefix(k))
    }
    
    /// Get score for a relay
    public func score(for relayId: String) -> Double {
        calculateScore(for: relayId)
    }
}

// MARK: - Relay Metrics

/// Detailed metrics for a single relay
public struct RelayMetrics: Sendable {
    public let relayId: String
    
    // Delivery metrics
    public var successfulDeliveries: Int
    public var failedDeliveries: Int
    public var blackholeCount: Int
    public var consecutiveBlackholes: Int
    
    // Latency metrics
    public var totalAckLatencyMs: Double
    public var averageAckLatency: Double?
    
    // Connection metrics
    public var disconnectCount: Int
    public var handshakeFailureCount: Int
    public var lastConnectionUpAt: Date?
    public var lastConnectionDownAt: Date?
    public var totalDowntimeSeconds: Double
    
    // Forward/inventory metrics
    public var forwardSuccessCount: Int
    public var forwardFailureCount: Int
    
    // Activity tracking
    public var lastActivityAt: Date?
    public var inactivityDecayApplied: Double
    
    public init(relayId: String) {
        self.relayId = relayId
        self.successfulDeliveries = 0
        self.failedDeliveries = 0
        self.blackholeCount = 0
        self.consecutiveBlackholes = 0
        self.totalAckLatencyMs = 0
        self.averageAckLatency = nil
        self.disconnectCount = 0
        self.handshakeFailureCount = 0
        self.lastConnectionUpAt = nil
        self.lastConnectionDownAt = nil
        self.totalDowntimeSeconds = 0
        self.forwardSuccessCount = 0
        self.forwardFailureCount = 0
        self.lastActivityAt = nil
        self.inactivityDecayApplied = 0
    }
}

// MARK: - Adaptive Publish Width

/// Adaptive publish width manager that adjusts K-of-N based on relay health.
/// MIN_PUBLISH_WIDTH <= current width <= MAX_PUBLISH_WIDTH
public struct AdaptivePublishWidth: Sendable {
    /// Minimum publish width
    public let minWidth: Int
    /// Maximum publish width
    public let maxWidth: Int
    
    /// Current publish width
    public private(set) var currentWidth: Int
    
    /// Window for tracking recent outcomes
    public let windowSize: Int
    
    /// Recent publication outcomes (true = success/quorum, false = failure/insufficient acks)
    private var recentOutcomes: [Bool]
    
    /// Consecutive failures count
    private var consecutiveFailures: Int
    
    /// Consecutive successes count
    private var consecutiveSuccesses: Int
    
    public init(
        minWidth: Int = 1,
        maxWidth: Int = 5,
        initialWidth: Int? = nil,
        windowSize: Int = 10
    ) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.currentWidth = initialWidth ?? (minWidth + maxWidth) / 2
        self.windowSize = windowSize
        self.recentOutcomes = []
        self.consecutiveFailures = 0
        self.consecutiveSuccesses = 0
    }
    
    /// Record a successful publication outcome
    public mutating func recordSuccess() {
        recordOutcome(success: true)
    }
    
    /// Record a failed publication outcome (insufficient acks or failure)
    public mutating func recordFailure() {
        recordOutcome(success: false)
    }
    
    private mutating func recordOutcome(success: Bool) {
        recentOutcomes.append(success)
        if recentOutcomes.count > windowSize {
            recentOutcomes.removeFirst()
        }
        
        if success {
            consecutiveSuccesses += 1
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
            consecutiveSuccesses = 0
        }
        
        adjustWidth()
    }
    
    /// Adjust width based on recent outcomes
    private mutating func adjustWidth() {
        let healthyRatio = healthyOutcomeRatio()
        
        // Increase width on unhealthy outcomes
        if healthyRatio < 0.5 || consecutiveFailures >= 2 {
            // Aggressively increase width when unhealthy
            currentWidth = min(maxWidth, currentWidth + 1)
        }
        
        // Decrease width when stable (high success rate)
        if healthyRatio >= 0.9 && consecutiveSuccesses >= 3 {
            // Gradually decrease width when stable
            currentWidth = max(minWidth, currentWidth - 1)
        }
    }
    
    /// Calculate ratio of healthy outcomes in recent window
    private func healthyOutcomeRatio() -> Double {
        guard !recentOutcomes.isEmpty else { return 0.5 }
        let healthy = recentOutcomes.filter { $0 }.count
        return Double(healthy) / Double(recentOutcomes.count)
    }
    
    /// Get the current recommended publish width
    public func getWidth() -> Int {
        currentWidth
    }
    
    /// Reset to initial width
    public mutating func reset(to initialWidth: Int? = nil) {
        currentWidth = initialWidth ?? (minWidth + maxWidth) / 2
        recentOutcomes = []
        consecutiveFailures = 0
        consecutiveSuccesses = 0
    }
    
    /// Get recent outcome statistics
    public var statistics: AdaptiveWidthStatistics {
        AdaptiveWidthStatistics(
            currentWidth: currentWidth,
            minWidth: minWidth,
            maxWidth: maxWidth,
            recentOutcomes: recentOutcomes,
            healthyRatio: healthyOutcomeRatio(),
            consecutiveFailures: consecutiveFailures,
            consecutiveSuccesses: consecutiveSuccesses
        )
    }
}

/// Statistics from adaptive width manager
public struct AdaptiveWidthStatistics: Sendable {
    public let currentWidth: Int
    public let minWidth: Int
    public let maxWidth: Int
    public let recentOutcomes: [Bool]
    public let healthyRatio: Double
    public let consecutiveFailures: Int
    public let consecutiveSuccesses: Int
}
