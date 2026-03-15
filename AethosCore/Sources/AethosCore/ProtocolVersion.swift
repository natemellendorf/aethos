import Foundation

public enum ProtocolVersion: UInt8, Codable, Sendable {
    case v1 = 1
    case v2 = 2

    public static let current: Self = .v2
}
