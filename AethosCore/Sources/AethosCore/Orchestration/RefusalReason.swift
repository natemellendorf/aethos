import Foundation

public struct RefusalReason: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public static let securityPostureInsufficient = RefusalReason(uncheckedRawValue: "security_posture_insufficient")
    public static let downgradeResistanceTriggered = RefusalReason(uncheckedRawValue: "downgrade_resistance_triggered")
    public static let resourceLimitExceeded = RefusalReason(uncheckedRawValue: "resource_limit_exceeded")
    public static let budgetExhausted = RefusalReason(uncheckedRawValue: "budget_exhausted")
    public static let timeScopeStale = RefusalReason(uncheckedRawValue: "time_scope_stale")
    public static let timeScopeExpired = RefusalReason(uncheckedRawValue: "time_scope_expired")
    public static let timeScopeInvalid = RefusalReason(uncheckedRawValue: "time_scope_invalid")
    public static let capabilityMismatch = RefusalReason(uncheckedRawValue: "capability_mismatch")
    public static let peerIncompatible = RefusalReason(uncheckedRawValue: "peer_incompatible")
    public static let sessionUnavailable = RefusalReason(uncheckedRawValue: "session_unavailable")
    public static let resumeNotSupported = RefusalReason(uncheckedRawValue: "resume_not_supported")
    public static let resumeTokenInvalid = RefusalReason(uncheckedRawValue: "resume_token_invalid")
    public static let resumeStateMissing = RefusalReason(uncheckedRawValue: "resume_state_missing")

    public static let canonicalCodes: Set<String> = [
        RefusalReason.securityPostureInsufficient.rawValue,
        RefusalReason.downgradeResistanceTriggered.rawValue,
        RefusalReason.resourceLimitExceeded.rawValue,
        RefusalReason.budgetExhausted.rawValue,
        RefusalReason.timeScopeStale.rawValue,
        RefusalReason.timeScopeExpired.rawValue,
        RefusalReason.timeScopeInvalid.rawValue,
        RefusalReason.capabilityMismatch.rawValue,
        RefusalReason.peerIncompatible.rawValue,
        RefusalReason.sessionUnavailable.rawValue,
        RefusalReason.resumeNotSupported.rawValue,
        RefusalReason.resumeTokenInvalid.rawValue,
        RefusalReason.resumeStateMissing.rawValue,
    ]

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func isValid(_ code: String) -> Bool {
        canonicalCodes.contains(code) || isValidExtensionCode(code)
    }

    public static func isValidExtensionCode(_ code: String) -> Bool {
        let utf8 = Array(code.utf8)
        guard utf8.count >= 3 else { return false }
        guard utf8[0] == 0x78, utf8[1] == 0x5F else { return false } // x_

        for byte in utf8.dropFirst(2) {
            switch byte {
            case 0x61...0x7A, 0x30...0x39, 0x5F: // a-z, 0-9, _
                continue
            default:
                return false
            }
        }

        return true
    }

    public var isCanonical: Bool {
        Self.canonicalCodes.contains(rawValue)
    }

    public var isExtension: Bool {
        Self.isValidExtensionCode(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        guard let parsed = RefusalReason(rawValue: code) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid refusal reason code: \(code)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(uncheckedRawValue: String) {
        self.rawValue = uncheckedRawValue
    }
}
