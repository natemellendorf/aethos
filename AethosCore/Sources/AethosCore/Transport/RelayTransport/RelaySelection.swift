import Foundation

/// Relay selection strategies for K-of-N publish targeting.
public enum RelaySelectionStrategy: Sendable {
    /// Select top K relays by health score.
    case byHealthScore
    
    /// Select K random healthy relays.
    case randomHealthy
    
    /// Select K relays with lowest latency.
    case byLatency
    
    /// Select K relays prioritizing diversity (different regions/operators).
    case byDiversity
}

/// Relay selector for choosing K relays from N available.
public struct RelaySelection: Sendable {
    private let strategy: RelaySelectionStrategy
    
    public init(strategy: RelaySelectionStrategy = .byHealthScore) {
        self.strategy = strategy
    }
    
    /// Select K relays from available healthy relays.
    /// - Parameters:
    ///   - k: Number of relays to select
    ///   - relays: Available relay configurations
    ///   - health: Health states for each relay
    /// - Returns: Array of selected relay IDs
    public func select(
        k: Int,
        from relays: [RelayConfig],
        health: [String: RelayHealth]
    ) -> [String] {
        let healthyRelays = relays.filter { relay in
            guard let state = health[relay.relayId] else { return false }
            return state.isHealthy
        }
        
        guard !healthyRelays.isEmpty else { return [] }
        
        let selectedCount = min(k, healthyRelays.count)
        
        switch strategy {
        case .byHealthScore:
            return selectByHealthScore(k: selectedCount, from: healthyRelays, health: health)
            
        case .randomHealthy:
            return selectRandom(k: selectedCount, from: healthyRelays)
            
        case .byLatency:
            return selectByHealthScore(k: selectedCount, from: healthyRelays, health: health)
            
        case .byDiversity:
            return selectByDiversity(k: selectedCount, from: healthyRelays)
        }
    }
    
    private func selectByHealthScore(
        k: Int,
        from relays: [RelayConfig],
        health: [String: RelayHealth]
    ) -> [String] {
        relays
            .sorted { lhs, rhs in
                let lhsScore = health[lhs.relayId]?.currentScore ?? 0
                let rhsScore = health[rhs.relayId]?.currentScore ?? 0
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return lhs.priority > rhs.priority
            }
            .prefix(k)
            .map { $0.relayId }
    }
    
    private func selectRandom(k: Int, from relays: [RelayConfig]) -> [String] {
        Array(relays.shuffled().prefix(k)).map { $0.relayId }
    }
    
    private func selectByDiversity(k: Int, from relays: [RelayConfig]) -> [String] {
        var selected: [String] = []
        var usedPrefixes = Set<String>()
        
        for relay in relays.sorted(by: { $0.priority > $1.priority }) {
            guard selected.count < k else { break }
            
            let prefix = extractDiversityPrefix(from: relay.relayId)
            if !usedPrefixes.contains(prefix) {
                selected.append(relay.relayId)
                usedPrefixes.insert(prefix)
            }
        }
        
        if selected.count < k {
            let remaining = relays
                .filter { !selected.contains($0.relayId) }
                .prefix(k - selected.count)
            selected.append(contentsOf: remaining.map { $0.relayId })
        }
        
        return selected
    }
    
    private func extractDiversityPrefix(from relayId: String) -> String {
        let components = relayId.split(separator: "-")
        guard components.count >= 2 else { return "default" }
        return String(components[0])
    }
}

/// Calculate the backoff duration with exponential increase and jitter.
public func calculateBackoff(
    failures: Int,
    base: Double,
    maxBackoff: Double,
    jitter: Double
) -> Double {
    let exponential = base * pow(2.0, Double(min(failures, 10)))
    let capped = Swift.min(exponential, maxBackoff)
    let jitterRange = capped * jitter
    let jitterValue = Double.random(in: -jitterRange...jitterRange)
    return Swift.max(0, capped + jitterValue)
}
