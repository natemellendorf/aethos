import Foundation

public struct MessageV1: Codable, Equatable, Sendable {
    public let version: ProtocolVersion
    public let createdAtUnixMs: Int64
    public let authorWayfarerId: Data
    public let body: Data
    public let extensionMetadata: Data?

    public init(
        version: ProtocolVersion = .v2,
        createdAtUnixMs: Int64,
        authorWayfarerId: Data,
        body: Data,
        extensionMetadata: Data? = nil
    ) {
        precondition(version == .v2, "MessageV1 requires protocol version v2")
        precondition(authorWayfarerId.count == 32, "MessageV1.authorWayfarerId must be 32 bytes")
        self.version = version
        self.createdAtUnixMs = createdAtUnixMs
        self.authorWayfarerId = authorWayfarerId
        self.body = body
        self.extensionMetadata = extensionMetadata
    }
}
