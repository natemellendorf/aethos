import Foundation

public struct TimeScope: Equatable, Sendable, Codable {
    /// UTC Unix epoch milliseconds.
    public let observedAt: UInt64
    /// UTC Unix epoch milliseconds.
    public let staleAfter: UInt64
    /// UTC Unix epoch milliseconds. Optional hard validity cutoff.
    public let validUntil: UInt64?

    public init(observedAt: UInt64, staleAfter: UInt64, validUntil: UInt64? = nil) {
        self.observedAt = observedAt
        self.staleAfter = staleAfter
        self.validUntil = validUntil
    }
}

public enum TimeScopeEvaluationResult: String, Equatable, Sendable, Codable {
    case valid
    case timeScopeInvalid = "time_scope_invalid"
    case timeScopeExpired = "time_scope_expired"
    case timeScopeStale = "time_scope_stale"

    public var refusalReason: RefusalReason? {
        switch self {
        case .valid:
            return nil
        case .timeScopeInvalid:
            return .timeScopeInvalid
        case .timeScopeExpired:
            return .timeScopeExpired
        case .timeScopeStale:
            return .timeScopeStale
        }
    }
}

public struct TimeScopeEvaluationInvariants: Equatable, Sendable, Codable {
    public let observedAtLteStaleAfter: Bool
    public let staleAfterLteValidUntil: Bool?

    public init(observedAtLteStaleAfter: Bool, staleAfterLteValidUntil: Bool?) {
        self.observedAtLteStaleAfter = observedAtLteStaleAfter
        self.staleAfterLteValidUntil = staleAfterLteValidUntil
    }
}

public struct TimeScopeEvaluation: Equatable, Sendable, Codable {
    public let observedAtUnixMs: UInt64
    public let staleAfterUnixMs: UInt64
    public let nowUnixMs: UInt64
    public let validUntilUnixMs: UInt64?
    public let invariants: TimeScopeEvaluationInvariants
    public let result: TimeScopeEvaluationResult

    public var refusalReason: RefusalReason? {
        result.refusalReason
    }

    public init(
        observedAtUnixMs: UInt64,
        staleAfterUnixMs: UInt64,
        nowUnixMs: UInt64,
        validUntilUnixMs: UInt64?,
        invariants: TimeScopeEvaluationInvariants,
        result: TimeScopeEvaluationResult
    ) {
        self.observedAtUnixMs = observedAtUnixMs
        self.staleAfterUnixMs = staleAfterUnixMs
        self.nowUnixMs = nowUnixMs
        self.validUntilUnixMs = validUntilUnixMs
        self.invariants = invariants
        self.result = result
    }
}

public enum TimeScopeEvaluator {
    public static func evaluate(_ timeScope: TimeScope, nowUnixMs: UInt64) -> TimeScopeEvaluation {
        let observedAtLteStaleAfter = timeScope.observedAt <= timeScope.staleAfter
        let staleAfterLteValidUntil = timeScope.validUntil.map { timeScope.staleAfter <= $0 }

        let invariants = TimeScopeEvaluationInvariants(
            observedAtLteStaleAfter: observedAtLteStaleAfter,
            staleAfterLteValidUntil: staleAfterLteValidUntil
        )

        let result: TimeScopeEvaluationResult
        if !observedAtLteStaleAfter || staleAfterLteValidUntil == false {
            result = .timeScopeInvalid
        } else if let validUntil = timeScope.validUntil, nowUnixMs >= validUntil {
            result = .timeScopeExpired
        } else if nowUnixMs >= timeScope.staleAfter {
            result = .timeScopeStale
        } else {
            result = .valid
        }

        return TimeScopeEvaluation(
            observedAtUnixMs: timeScope.observedAt,
            staleAfterUnixMs: timeScope.staleAfter,
            nowUnixMs: nowUnixMs,
            validUntilUnixMs: timeScope.validUntil,
            invariants: invariants,
            result: result
        )
    }
}
