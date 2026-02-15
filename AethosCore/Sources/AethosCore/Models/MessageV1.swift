import Foundation

public struct MessageV1: Codable, Equatable, Sendable {
    public let version: ProtocolVersion
    public let createdAtUnixMs: Int64
    public let body: Data

    public init(
        version: ProtocolVersion = .v1,
        createdAtUnixMs: Int64,
        body: Data
    ) {
        self.version = version
        self.createdAtUnixMs = createdAtUnixMs
        self.body = body
    }
}
