import Foundation

public struct ManifestV1: Codable, Equatable, Sendable {
    public static let chunkSize: Int = 32_768

    public let version: ProtocolVersion
    public let totalSize: Int
    public let chunkIds: [Data]

    // Convenience aliases used by higher-level components.
    public var totalBytes: Int { totalSize }
    public var chunkCount: Int { chunkIds.count }
    public var chunkSize: Int { Self.chunkSize }

    public init(
        version: ProtocolVersion = .v1,
        totalSize: Int,
        chunkIds: [Data]
    ) {
        self.version = version
        self.totalSize = totalSize
        self.chunkIds = chunkIds
    }
}
