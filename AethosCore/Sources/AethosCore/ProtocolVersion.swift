import Foundation

public enum ProtocolVersion: UInt8, Codable, Sendable {
    case v1 = 1

    public static let current: Self = .v1
}
