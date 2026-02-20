import Foundation

/// Health scoring and backoff management for relays.
public struct RelayHealthManager: Sendable {
    private var states: [String: RelayHealthState]
    
    public struct RelayHealthState: Equatable, Sendable {
        public var relayId: String
        public var consecutiveFailures: Int
        public var lastSuccessAt: Date?
        public var lastAttemptAt: Date?
        public var backoffUntil: Date?
        public var currentScore: Double
        public var latencyMs: Double?
        
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
            self.latencyMs = nil
        }
        
        public var isHealthy: Bool {
            guard let backoffUntil else { return true }
            return Date() >= backoffUntil
        }
        
        public mutating func recordSuccess(latencyMs: Double?) {
            consecutiveFailures = 0
            lastSuccessAt = Date()
            currentScore = Swift.min(Self.maxScore, currentScore + 10)
            self.latencyMs = latencyMs
        }
        
        public mutating func recordFailure(baseBackoff: Double, maxBackoff: Double, jitterFactor: Double) {
            consecutiveFailures += 1
            currentScore = Swift.max(Self.minScore, currentScore - 20)
            
            let exponential = baseBackoff * pow(2.0, Double(min(consecutiveFailures, 10)))
            let capped = Swift.min(exponential, maxBackoff)
            let jitterRange = capped * jitterFactor
            let jitterValue = Double.random(in: -jitterRange...jitterRange)
            let backoff = Swift.max(0, capped + jitterValue)
            
            backoffUntil = Date().addingTimeInterval(backoff)
        }
        
        public mutating func recordAttempt() {
            lastAttemptAt = Date()
        }
    }
    
    public init() {
        self.states = [:]
    }
    
    public init(relays: [RelayConfig]) {
        self.states = Dictionary(uniqueKeysWithValues: relays.map { ($0.relayId, RelayHealthState(relayId: $0.relayId)) })
    }
    
    public func getState(for relayId: String) -> RelayHealthState? {
        states[relayId]
    }
    
    public mutating func addRelay(_ config: RelayConfig) {
        states[config.relayId] = RelayHealthState(relayId: config.relayId)
    }
    
    public mutating func removeRelay(relayId: String) {
        states.removeValue(forKey: relayId)
    }
    
    public mutating func recordSuccess(relayId: String, latencyMs: Double?) {
        guard var state = states[relayId] else { return }
        state.recordSuccess(latencyMs: latencyMs)
        states[relayId] = state
    }
    
    public mutating func recordFailure(
        relayId: String,
        baseBackoff: Double,
        maxBackoff: Double,
        jitterFactor: Double
    ) {
        guard var state = states[relayId] else { return }
        state.recordFailure(
            baseBackoff: baseBackoff,
            maxBackoff: maxBackoff,
            jitterFactor: jitterFactor
        )
        states[relayId] = state
    }
    
    public mutating func recordAttempt(relayId: String) {
        guard var state = states[relayId] else { return }
        state.recordAttempt()
        states[relayId] = state
    }
    
    public func healthyRelays() -> [String] {
        states.values
            .filter { $0.isHealthy }
            .sorted { $0.currentScore > $1.currentScore }
            .map { $0.relayId }
    }
    
    public func selectTopK(_ k: Int) -> [String] {
        Array(healthyRelays().prefix(k))
    }
    
    public mutating func clearBackoff(relayId: String) {
        states[relayId]?.backoffUntil = nil
    }
}

/// Deterministic backoff calculator for testing.
public struct DeterministicBackoff: Sendable {
    private var currentFailures: [String: Int] = [:]
    private var deterministicRandom: Double
    private let useDeterministic: Bool
    
    public init(seed: Double = 0.5, deterministic: Bool = true) {
        self.deterministicRandom = seed
        self.useDeterministic = deterministic
    }
    
    public mutating func nextBackoff(
        for relayId: String,
        base: Double,
        max: Double,
        jitter: Double
    ) -> Double {
        let failures = (currentFailures[relayId] ?? 0) + 1
        currentFailures[relayId] = failures
        
        let exponential = base * pow(2.0, Double(min(failures, 10)))
        let capped = Swift.min(exponential, max)
        let jitterRange = capped * jitter
        
        let jitterValue: Double
        if useDeterministic {
            jitterValue = (deterministicRandom - 0.5) * 2 * jitterRange
        } else {
            jitterValue = Double.random(in: -jitterRange...jitterRange)
        }
        
        return Swift.max(0, capped + jitterValue)
    }
    
    public mutating func reset(for relayId: String) {
        currentFailures[relayId] = 0
    }
}
