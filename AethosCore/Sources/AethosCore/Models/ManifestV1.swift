import Foundation

public struct ManifestV1: Codable, Equatable, Sendable {
    public static let chunkSize: Int = 32_768

    public let version: ProtocolVersion
    public let totalSize: Int
    public let chunkIds: [Data]

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
